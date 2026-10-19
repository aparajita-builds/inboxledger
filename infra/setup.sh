#!/bin/bash
# InboxLedger (Couple Budget Manager) - VM setup script (run as root via "az vm run-command invoke").
# Installs Nginx, Python, the Microsoft ODBC driver, and the Flask app as a systemd service.
# The only setting is the Key Vault name; every other value is read from Key Vault at runtime.
# Re-run with bash if started by sh (Run Command may use /bin/sh).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
KEY_VAULT_NAME="kv-couplebudget"
APP_DIR=/opt/couplebudget
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=600 -y -q"

echo "== 1/6 Packages (Nginx, Python, stress-ng)"
$APT update
$APT install nginx python3-venv python3-pip curl stress-ng

echo "== 2/6 Microsoft ODBC Driver 18 for SQL Server"
if ! dpkg -s msodbcsql18 >/dev/null 2>&1; then
  curl -sSL -o /tmp/packages-microsoft-prod.deb \
    "https://packages.microsoft.com/config/ubuntu/$(. /etc/os-release && echo "$VERSION_ID")/packages-microsoft-prod.deb"
  dpkg -i /tmp/packages-microsoft-prod.deb
  $APT update
  ACCEPT_EULA=Y $APT install msodbcsql18
fi

echo "== 3/6 App user, folder and Python packages"
id couplebudget >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin couplebudget
mkdir -p "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q flask==3.0.3 gunicorn==22.0.0 pyodbc==5.1.0 requests==2.32.3 \
  azure-identity==1.17.1 azure-keyvault-secrets==4.8.0 azure-storage-blob==12.22.0 \
  azure-communication-email==1.0.0

echo "== 4/6 Writing the Flask app"
cat > "$APP_DIR/app.py" <<'PYEOF'
"""InboxLedger (Couple Budget Manager) - Flask web app.

Runs on each Ubuntu VM behind Nginx and the Azure Load Balancer.
All configuration and secrets come from Azure Key Vault, read with the VM's
system-assigned managed identity. The VM only knows the vault name.
"""
import base64
import datetime as dt
import hashlib
import html
import json
import os
import re
import socket
import threading
import time
from decimal import Decimal
from functools import wraps

import requests
from flask import Flask, Response, jsonify, redirect, render_template_string, request

app = Flask(__name__)
HOST = socket.gethostname()
KEY_VAULT_NAME = os.environ.get("KEY_VAULT_NAME", "")
CONTAINER = "raw-emails"
OWNERS = ("wife", "husband")

# ---------------------------------------------------------------- Key Vault
_cache = {}
_lock = threading.Lock()
_credential = None


def _cred():
    global _credential
    if _credential is None:
        from azure.identity import ManagedIdentityCredential
        _credential = ManagedIdentityCredential()
    return _credential


def secret(name, default=None):
    """Read a secret from Key Vault with the VM's managed identity.

    Values are cached for 10 minutes; missing secrets are retried after 2 minutes,
    so a secret added later (for example docintel-key) is picked up without a restart.
    """
    now = time.time()
    with _lock:
        hit = _cache.get(name)
        if hit and now < hit[1]:
            return hit[0] if hit[0] is not None else default
    value = None
    try:
        from azure.keyvault.secrets import SecretClient
        client = SecretClient(f"https://{KEY_VAULT_NAME}.vault.azure.net", _cred())
        value = client.get_secret(name).value
    except Exception as exc:  # secret missing or no access yet
        app.logger.warning("Key Vault secret %s unavailable: %s", name, exc)
    with _lock:
        _cache[name] = (value, now + (600 if value is not None else 120))
    return value if value is not None else default


# ---------------------------------------------------------------- SQL
def db():
    import pyodbc
    server = secret("sql-server", "")
    if server and "." not in server:
        server += ".database.windows.net"
    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{server},1433;Database={secret('sql-database', 'sqldb-couplebudget')};"
        f"Uid={secret('sql-user', 'sqladmin')};Pwd={secret('sql-password', '')};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;"
    )
    last = None
    for _ in range(3):  # the free database auto-pauses and can take a minute to wake up
        try:
            return pyodbc.connect(conn_str, autocommit=True)
        except pyodbc.Error as exc:
            last = exc
            time.sleep(10)
    raise last


# ---------------------------------------------------------------- parsing
MERCHANTS = [("amazon", "Amazon"), ("walmart", "Walmart"), ("target", "Target"),
             ("costco", "Costco"), ("best buy", "Best Buy"), ("bestbuy", "Best Buy")]
CATEGORIES = [
    ("Groceries", ["milk", "bread", "eggs", "banana", "rice", "coffee", "grocery", "cereal",
                   "chicken", "yogurt", "snack", "pasta", "produce", "juice"]),
    ("Electronics", ["usb", "cable", "charger", "headphone", "earbud", "laptop", "mouse",
                     "keyboard", "hdmi", "battery", "batteries", "phone", "speaker"]),
    ("Home", ["towel", "lamp", "pillow", "detergent", "cleaner", "kitchen", "pan", "storage",
              "bedding", "paper towel", "trash bag", "candle", "sheet"]),
    ("Clothing", ["shirt", "jeans", "dress", "socks", "shoe", "jacket", "sweater", "hoodie"]),
    ("Health & Beauty", ["shampoo", "vitamin", "toothpaste", "lotion", "soap", "sunscreen",
                         "conditioner", "face wash"]),
]
SKIP_WORDS = ("total", "tax", "shipping", "subtotal", "discount", "savings", "payment", "balance")


def html_to_text(raw):
    s = raw or ""
    if "<" not in s:
        return s
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</tr>|</div>|</li>|</h\d>", "\n", s)
    s = re.sub(r"(?i)</td>", "  ", s)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    lines = [re.sub(r"[ \t\xa0]+", " ", ln).strip() for ln in s.splitlines()]
    return "\n".join(ln for ln in lines if ln)


def find_merchant(sender, subject, text):
    hay = f"{sender} {subject} {text[:600]}".lower()
    for key, name in MERCHANTS:
        if key in hay:
            return name
    return "Other"


def find_order_number(text):
    m = re.search(r"order\s*(?:#|number|no\.?|id)\s*[:#]?\s*([A-Z0-9-]*\d[A-Z0-9-]*)", text, re.I)
    if m and len(m.group(1)) >= 6:
        return m.group(1)
    return None


def find_total(text):
    for label in (r"order total", r"grand total", r"total charged", r"(?<!sub)total"):
        hits = re.findall(label + r"[^0-9$\n]{0,25}\$\s*([0-9][0-9,]*\.[0-9]{2})", text, re.I)
        if hits:
            return float(hits[-1].replace(",", ""))
    return None


def find_items(text):
    items = []
    for line in text.splitlines():
        m = re.match(r"^(.*?[A-Za-z].*?)\s+(?:qty:?\s*(\d+)\s+)?\$\s*([0-9][0-9,]*\.[0-9]{2})$",
                     line.strip(), re.I)
        if m and not any(w in m.group(1).lower() for w in SKIP_WORDS):
            items.append({"name": m.group(1).strip(" -:"),
                          "qty": int(m.group(2) or 1),
                          "price": float(m.group(3).replace(",", ""))})
    return items


def find_category(items, text):
    hay = (" ".join(i["name"] for i in items) + " " + text).lower()
    best, score = "Shopping", 0
    for cat, words in CATEGORIES:
        n = sum(hay.count(w) for w in words)
        if n > score:
            best, score = cat, n
    return best


def parse_email(sender, subject, body_text):
    items = find_items(body_text)
    return {
        "merchant": find_merchant(sender, subject, body_text),
        "order_number": find_order_number(subject + "\n" + body_text),
        "total": find_total(body_text),
        "items": items,
        "category": find_category(items, subject + " " + body_text),
    }


# ---------------------------------------------------------------- Document Intelligence
def analyze_receipt(data, content_type):
    """Send a PDF or image to Document Intelligence (prebuilt-receipt model)."""
    endpoint, key = secret("docintel-endpoint"), secret("docintel-key")
    if not endpoint or not key:
        return None
    url = (endpoint.rstrip("/") + "/documentintelligence/documentModels/"
           "prebuilt-receipt:analyze?api-version=2024-11-30")
    r = requests.post(url, data=data, timeout=30, headers={
        "Ocp-Apim-Subscription-Key": key,
        "Content-Type": content_type or "application/pdf"})
    r.raise_for_status()
    op_url = r.headers["Operation-Location"]
    result = {}
    for _ in range(30):
        time.sleep(1.5)
        result = requests.get(op_url, timeout=30,
                              headers={"Ocp-Apim-Subscription-Key": key}).json()
        if result.get("status") in ("succeeded", "failed"):
            break
    if result.get("status") != "succeeded":
        return None
    docs = result.get("analyzeResult", {}).get("documents", [])
    if not docs:
        return None
    f = docs[0].get("fields", {})

    def text_of(field):
        field = field or {}
        return field.get("valueString") or field.get("content")

    def money(field):
        return ((field or {}).get("valueCurrency") or {}).get("amount") or (field or {}).get("valueNumber")

    items = []
    for it in (f.get("Items") or {}).get("valueArray", []):
        o = it.get("valueObject", {})
        name = text_of(o.get("Description"))
        if name:
            items.append({"name": name, "qty": (o.get("Quantity") or {}).get("valueNumber") or 1,
                          "price": money(o.get("TotalPrice")) or money(o.get("Price"))})
    return {"merchant": text_of(f.get("MerchantName")), "total": money(f.get("Total")),
            "date": (f.get("TransactionDate") or {}).get("valueDate"), "items": items}


# ---------------------------------------------------------------- Blob Storage
def save_to_blob(path, data, content_type):
    account = secret("storage-account")
    if not account:
        return None
    from azure.storage.blob import BlobServiceClient, ContentSettings
    svc = BlobServiceClient(f"https://{account}.blob.core.windows.net", credential=_cred())
    svc.get_blob_client(CONTAINER, path).upload_blob(
        data, overwrite=True, content_settings=ContentSettings(content_type=content_type))
    return path


# ---------------------------------------------------------------- email (Communication Services)
def send_email(subject, text):
    conn, sender, to = secret("acs-connection-string"), secret("acs-sender"), secret("alert-emails")
    if not (conn and sender and to):
        app.logger.info("ACS not configured; skipped email: %s", subject)
        return False
    from azure.communication.email import EmailClient
    client = EmailClient.from_connection_string(conn)
    message = {
        "senderAddress": sender,
        "recipients": {"to": [{"address": a.strip()} for a in to.split(",") if a.strip()]},
        "content": {"subject": subject, "plainText": text},
    }
    client.begin_send(message).result()
    return True


def check_budgets(cur):
    """Email both partners once per month when a budget is exceeded."""
    month_start = dt.date.today().replace(day=1)
    month = month_start.strftime("%Y-%m")
    cur.execute("SELECT owner, monthly_limit FROM budgets WHERE category = 'All'")
    sent = []
    for owner, limit in cur.fetchall():
        if owner == "household":
            cur.execute("SELECT COALESCE(SUM(total), 0) FROM purchases WHERE order_date >= ?", month_start)
        else:
            cur.execute("SELECT COALESCE(SUM(total), 0) FROM purchases "
                        "WHERE owner = ? AND order_date >= ?", owner, month_start)
        spent = float(cur.fetchone()[0])
        if spent <= float(limit):
            continue
        cur.execute("SELECT COUNT(*) FROM budget_alerts WHERE owner = ? AND month = ?", owner, month)
        if cur.fetchone()[0]:
            continue
        who = "The household" if owner == "household" else f"The {owner}"
        ok = send_email(
            f"InboxLedger alert: {owner} budget exceeded",
            f"{who} has spent ${spent:,.2f} this month, over the ${float(limit):,.2f} budget.\n\n"
            f"Open the dashboard to see the purchases.\n\n(sent by {HOST})")
        if ok:
            cur.execute("INSERT INTO budget_alerts (owner, month, spent) VALUES (?, ?, ?)",
                        owner, month, spent)
            sent.append(owner)
    return sent


# ---------------------------------------------------------------- core pipeline
def safe_name(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name or "file")[:80]


def process_email(owner, sender, subject, body, received=None, attachments=None, raw_blob=None):
    text = html_to_text(body)
    parsed = parse_email(sender, subject, text)
    source = "email-text"
    receipt_blob = None

    for att in attachments or []:
        a = {k.lower(): v for k, v in att.items()} if isinstance(att, dict) else {}
        ctype = (a.get("contenttype") or "").lower()
        name = a.get("name") or "attachment"
        if not (ctype.startswith("application/pdf") or ctype.startswith("image/")
                or name.lower().endswith((".pdf", ".png", ".jpg", ".jpeg"))):
            continue
        data = a.get("contentbytes")
        data = base64.b64decode(data) if isinstance(data, str) else data
        if not data:
            continue
        if not ctype:
            ctype = "application/pdf" if name.lower().endswith(".pdf") else "image/jpeg"
        try:
            receipt_blob = save_to_blob(
                f"receipts/{owner}/{dt.datetime.utcnow():%Y%m%d-%H%M%S}-{safe_name(name)}", data, ctype)
        except Exception as exc:
            app.logger.warning("Blob upload failed: %s", exc)
        try:
            ai = analyze_receipt(data, ctype)
        except Exception as exc:
            app.logger.warning("Document Intelligence failed: %s", exc)
            ai = None
        if ai:
            source = "doc-intelligence"
            parsed["total"] = ai["total"] or parsed["total"]
            if ai["items"]:
                parsed["items"] = ai["items"]
                parsed["category"] = find_category(ai["items"], subject)
            if parsed["merchant"] == "Other" and ai["merchant"]:
                parsed["merchant"] = ai["merchant"][:100]
            if ai["date"]:
                received = ai["date"]
        break  # first receipt only

    order_date = dt.date.today()
    if received:
        try:
            order_date = dt.date.fromisoformat(str(received)[:10])
        except ValueError:
            pass
    order_number = parsed["order_number"] or "NO-ID-" + hashlib.sha1(
        (subject + body).encode("utf-8", "ignore")).hexdigest()[:10].upper()

    if parsed["total"] is None:
        return {"status": "skipped", "reason": "no order total found", "subject": subject}

    conn = db()
    cur = conn.cursor()
    try:
        cur.execute(
            "INSERT INTO purchases (owner, merchant, order_number, order_date, total, category, "
            "items, source, blob_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            owner, parsed["merchant"], order_number, order_date, parsed["total"], parsed["category"],
            json.dumps(parsed["items"])[:4000], source, receipt_blob or raw_blob)
    except Exception as exc:
        if "uq_order" in str(exc) or "duplicate" in str(exc).lower():
            conn.close()
            return {"status": "duplicate", "order_number": order_number}
        conn.close()
        raise
    alerts = []
    try:
        alerts = check_budgets(cur)
    except Exception as exc:
        app.logger.warning("Budget check failed: %s", exc)
    conn.close()
    return {"status": "saved", "owner": owner, "merchant": parsed["merchant"],
            "order_number": order_number, "total": parsed["total"], "category": parsed["category"],
            "source": source, "receipt_blob": receipt_blob, "budget_alerts_sent": alerts,
            "served_by": HOST}


# ---------------------------------------------------------------- auth
def require_login(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        password = secret("dashboard-password")
        if password:
            auth = request.authorization
            if not auth or auth.username != "couple" or auth.password != password:
                return Response("Login required", 401,
                                {"WWW-Authenticate": 'Basic realm="InboxLedger"'})
        return view(*args, **kwargs)
    return wrapper


def api_key_ok():
    expected = secret("ingest-api-key")
    given = request.headers.get("X-Api-Key") or request.form.get("api_key", "")
    return bool(expected) and given == expected


# ---------------------------------------------------------------- routes
@app.get("/health")
def health():
    return f"ok {HOST}\n", 200, {"Content-Type": "text/plain"}


@app.post("/ingest")
def ingest():
    """Called by Logic Apps with the whole Outlook.com trigger body as JSON."""
    if not api_key_ok():
        return jsonify(error="bad or missing X-Api-Key"), 401
    owner = (request.args.get("owner") or "").lower()
    if owner not in OWNERS:
        return jsonify(error="owner must be wife or husband"), 400
    raw = request.get_json(force=True, silent=True) or {}
    p = {k.lower(): v for k, v in raw.items()}
    sender = p.get("from") or ""
    if isinstance(sender, dict):
        sender = json.dumps(sender)
    result = process_email(
        owner=owner, sender=str(sender), subject=p.get("subject") or "", body=p.get("body") or "",
        received=p.get("datetimereceived") or p.get("receiveddatetime"),
        attachments=p.get("attachments") or [], raw_blob=request.args.get("blob"))
    return jsonify(result), 200


MANUAL_PAGE = """<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
<title>Add an order email · InboxLedger</title><style>body{font-family:system-ui,sans-serif;max-width:720px;margin:24px auto;padding:0 16px}
textarea,input,select{width:100%;padding:8px;margin:6px 0 14px;box-sizing:border-box;font:inherit}button{padding:10px 18px}
pre{background:#f4f4f4;padding:12px;white-space:pre-wrap}</style></head><body>
<h2>Add an order email by hand</h2><p>Backup path for demos if Logic Apps is slow. <a href="/">Back to dashboard</a></p>
<form method=post enctype=multipart/form-data>
<label>Whose purchase</label><select name=owner><option>wife</option><option>husband</option></select>
<label>Subject</label><input name=subject placeholder="Your Amazon.com order #112-...">
<label>Email text</label><textarea name=body rows=10></textarea>
<label>Receipt PDF or image (optional)</label><input type=file name=receipt>
<label>Ingest API key</label><input name=api_key type=password>
<button>Save purchase</button></form>{% if result %}<h3>Result</h3><pre>{{ result }}</pre>{% endif %}</body></html>"""


@app.route("/manual", methods=["GET", "POST"])
@require_login
def manual():
    result = None
    if request.method == "POST":
        if not api_key_ok():
            result = "Wrong API key"
        else:
            atts = []
            f = request.files.get("receipt")
            if f and f.filename:
                atts.append({"name": f.filename, "contentType": f.mimetype, "contentBytes": f.read()})
            owner = request.form.get("owner", "wife")
            result = json.dumps(process_email(owner, "manual", request.form.get("subject", ""),
                                              request.form.get("body", ""), None, atts), indent=2)
    return render_template_string(MANUAL_PAGE, result=result)


DASHBOARD = """<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
<title>InboxLedger</title><style>
:root{--ink:#1d2433;--muted:#667085;--line:#e4e7ec;--accent:#2f6fde;--warn:#d92d20;--ok:#12b76a}
body{font-family:system-ui,-apple-system,sans-serif;color:var(--ink);margin:0;background:#f7f8fa}
header{background:#fff;border-bottom:1px solid var(--line);padding:16px}
main{max-width:1000px;margin:0 auto;padding:16px}h1{margin:0;font-size:20px}
.tabs a{display:inline-block;padding:8px 14px;margin:12px 6px 0 0;border-radius:20px;text-decoration:none;color:var(--ink);border:1px solid var(--line);background:#fff}
.tabs a.on{background:var(--accent);color:#fff;border-color:var(--accent)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:16px 0}
.card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:14px}
.card .k{color:var(--muted);font-size:13px}.card .v{font-size:24px;font-weight:600;margin-top:4px}
.bar{height:10px;background:var(--line);border-radius:5px;overflow:hidden;margin-top:8px}
.bar div{height:100%;background:var(--ok)}.bar div.over{background:var(--warn)}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:9px 10px;vertical-align:top;border-bottom:1px solid var(--line);font-size:14px}th{color:var(--muted);font-weight:600}
td.r,th.r{text-align:right}.wrap{overflow-x:auto}h2{font-size:16px;margin:22px 0 8px}
.tag{font-size:12px;padding:2px 8px;border-radius:10px;background:#eef2ff}
footer{color:var(--muted);font-size:12px;padding:20px 16px;text-align:center}</style></head><body>
<header><main style="padding:0"><h1>InboxLedger <span style="font-weight:400;color:var(--muted);font-size:14px">shared household spending, read from your inbox</span></h1>
<div class=tabs>{% for v in views %}<a href="/?view={{v}}" class="{{'on' if v==view}}">{{v|capitalize}}</a>{% endfor %}
<a href="/manual">+ Add email</a></div></main></header><main>
{% if error %}<div class=card style="border-color:var(--warn)">Database not reachable yet: {{error}}</div>{% endif %}
<div class=cards>
<div class=card><div class=k>Spent this month</div><div class=v>${{ '%.2f'|format(spent) }}</div></div>
<div class=card><div class=k>Monthly budget</div><div class=v>{% if budget %}${{ '%.2f'|format(budget) }}{% else %}-{% endif %}</div>
{% if budget %}<div class=bar><div class="{{'over' if spent>budget}}" style="width:{{ [100, (spent/budget*100)|int]|min }}%"></div></div>{% endif %}</div>
<div class=card><div class=k>Orders this month</div><div class=v>{{ count }}</div></div>
<div class=card><div class=k>Top store</div><div class=v style="font-size:20px">{{ top_store or '-' }}</div></div></div>
<h2>By store</h2><div class=wrap><table><tr><th>Store</th><th class=r>Orders</th><th class=r>Total</th></tr>
{% for s in stores %}<tr><td>{{s[0]}}</td><td class=r>{{s[1]}}</td><td class=r>${{ '%.2f'|format(s[2]) }}</td></tr>{% else %}<tr><td colspan=3>No purchases yet</td></tr>{% endfor %}</table></div>
<h2>Purchases</h2><div class=wrap><table><tr><th>Date</th><th>Who</th><th>Store</th><th>Order #</th><th>Category</th><th>Items</th><th>Read by</th><th class=r>Total</th></tr>
{% for p in rows %}<tr><td style="white-space:nowrap">{{p.date}}</td><td>{{p.owner|capitalize}}</td><td>{{p.merchant}}</td><td>{{p.order}}</td><td><span class=tag>{{p.category}}</span></td>
<td>{{p.item_names}}</td><td>{{p.read_by}}</td><td class=r>${{ '%.2f'|format(p.total) }}</td></tr>
{% else %}<tr><td colspan=8>No purchases yet. Send an order email to one of the inboxes.</td></tr>{% endfor %}</table></div></main>
<footer>Served by <b>{{ host }}</b> behind the Azure Load Balancer</footer></body></html>"""


READ_BY = {"doc-intelligence": "AI receipt", "email-text": "Email text"}


@app.get("/")
@require_login
def dashboard():
    view = (request.args.get("view") or "household").lower()
    if view not in ("household",) + OWNERS:
        return redirect("/")
    month_start = dt.date.today().replace(day=1)
    ctx = dict(views=("household",) + OWNERS, view=view, host=HOST, spent=0.0, budget=None,
               count=0, top_store=None, stores=[], rows=[], error=None)
    try:
        conn = db()
        cur = conn.cursor()
        where, args = ("", []) if view == "household" else (" AND owner = ?", [view])
        cur.execute("SELECT COALESCE(SUM(total),0), COUNT(*) FROM purchases WHERE order_date >= ?" + where,
                    month_start, *args)
        spent, count = cur.fetchone()
        ctx["spent"], ctx["count"] = float(spent), count
        cur.execute("SELECT monthly_limit FROM budgets WHERE owner = ? AND category = 'All'", view)
        row = cur.fetchone()
        ctx["budget"] = float(row[0]) if row else None
        cur.execute("SELECT merchant, COUNT(*), SUM(total) FROM purchases WHERE order_date >= ?" + where +
                    " GROUP BY merchant ORDER BY SUM(total) DESC", month_start, *args)
        ctx["stores"] = [(r[0], r[1], float(r[2])) for r in cur.fetchall()]
        ctx["top_store"] = ctx["stores"][0][0] if ctx["stores"] else None
        cur.execute("SELECT TOP 100 order_date, owner, merchant, order_number, category, items, source, total "
                    "FROM purchases WHERE 1=1" + where + " ORDER BY order_date DESC, id DESC", *args)
        for r in cur.fetchall():
            try:
                names = ", ".join(i["name"] for i in json.loads(r[5] or "[]"))[:80]
            except (ValueError, TypeError, KeyError):
                names = ""
            ctx["rows"].append(dict(date=r[0], owner=r[1], merchant=r[2], order=r[3], category=r[4],
                                    item_names=names, read_by=READ_BY.get(r[6], r[6]),
                                    total=float(r[7] or Decimal(0))))
        conn.close()
    except Exception as exc:
        ctx["error"] = str(exc)[:300]
    return render_template_string(DASHBOARD, **ctx)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
PYEOF
echo "KEY_VAULT_NAME=$KEY_VAULT_NAME" > /etc/couplebudget.env
chown -R couplebudget:couplebudget "$APP_DIR"

echo "== 5/6 systemd service (Gunicorn on 127.0.0.1:8000)"
cat > /etc/systemd/system/couplebudget.service <<'EOF'
[Unit]
Description=InboxLedger web app (Flask + Gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=couplebudget
WorkingDirectory=/opt/couplebudget
EnvironmentFile=/etc/couplebudget.env
ExecStart=/opt/couplebudget/venv/bin/gunicorn --workers 2 --timeout 120 --bind 127.0.0.1:8000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now couplebudget
systemctl restart couplebudget

echo "== 6/6 Nginx reverse proxy (port 80 -> Gunicorn)"
cat > /etc/nginx/sites-available/couplebudget <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 25m;          # order emails can carry PDF receipts

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;       # Document Intelligence can take a few seconds
    }
}
EOF
ln -sf /etc/nginx/sites-available/couplebudget /etc/nginx/sites-enabled/couplebudget
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload nginx

sleep 3
echo "== Check"
echo "Health: $(curl -s http://localhost/health)"
echo "Outbound IP (should be the NAT Gateway IP): $(curl -s https://ifconfig.me)"
systemctl is-active couplebudget nginx
echo "SETUP COMPLETE on $(hostname)"
