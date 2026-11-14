"""Cashew links: turn untracked transactions into addTransaction deep links.

Cashew (cashewapp.web.app) saves a transaction straight from a link:
  https://cashewapp.web.app/addTransaction?JSON=<url-encoded {"transactions":[...]}>
Cashew decodes every value twice, so a literal "%" is written "%25" inside the
JSON text before the one URL-encoding (see `escape_percent`). The bulk link has
no transfer: a lone transfer leg is a "Balance Correction" entry. A paired
transfer (both legs) gets its own `addTransferRoute` link instead: one real
transfer per link, opened prefilled in Cashew, saved by a tap (no bulk form).

`drafts()` is the editable list the widget shows; `build_links()` turns the
(possibly edited) drafts into links. Pure functions over plain data, plus a
read-only look at the database. The widget's own choices (categories taught per
merchant, account-name overrides) live in a small state file, not in the DB."""
from __future__ import annotations

import functools
import json
import os
import re
import sqlite3
import urllib.parse
from pathlib import Path

from . import keys, transfers

APP_BASE = "https://cashewapp.web.app/"            # the Android / iOS app
WEB_BASE = "https://budget-track.web.app/"          # the Cashew web app
BASE_URL = APP_BASE + "addTransaction?JSON="
FALLBACK_CATEGORY = "Uncategorized"
HERE = Path(__file__).resolve().parent
TITLE_MAX = 250
NOTES_MAX = 500
BILL_ITEMS = 12
DEFAULT_MAX_CHARS = 6000
UNCATEGORIZED = ("Uncategorized", "Unknown")
BALANCE = "Balance Correction"
FRIEND = "Friend Settlement"
FRIEND_SUB = "Split Paid"                            # both directions


def default_state_path() -> Path:
    env = os.environ.get("TXDB_CASHEW_STATE")
    return Path(env) if env else Path.home() / ".local" / "state" / "omarchy" / "transactions-cashew.json"


# Our account id (BANK|type|last4) -> the account name in the user's Cashew.
ACCOUNT_MAP = {
    "HDFC|checking|7367": "HDFC",
    "SBI|checking|9373": "SBI",
    "AXIS|checking|2934": "Axis",
    "HDFC|credit|0220": "HDFC ₹",
    "HDFC|credit|7462": "HDFC CC",
    "ICICI|credit|2004": "ICICI ₹",
    "ICICI|credit|4002": "ICICI 🌳",
    "SBI|credit|5896": "SBI ₹",
}
BANK_NAMES = {"HDFC": "HDFC", "SBI": "SBI", "AXIS": "Axis", "ICICI": "ICICI"}


# ------------------------------------------------------------------ data files

_JSON_CACHE: dict[str, tuple[int, object]] = {}


def _load_json(name: str):
    """Parse a data file once per process; reparse when the file changes on disk."""
    path = HERE / name
    stamp = path.stat().st_mtime_ns
    hit = _JSON_CACHE.get(name)
    if hit and hit[0] == stamp:
        return hit[1]
    data = json.loads(path.read_text(encoding="utf-8"))
    _JSON_CACHE[name] = (stamp, data)
    return data


def load_categories() -> list[dict]:
    return _load_json("cashew_categories.json")


def load_rules() -> list[dict]:
    return _load_json("cashew_rules.json")


def empty_state() -> dict:
    return {"version": 1, "categories": {}, "accounts": {}}


def load_state(path: Path | str | None = None) -> dict:
    """The saved state; a missing or damaged file is an empty state."""
    try:
        data = json.loads(Path(path or default_state_path()).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return empty_state()
    if not isinstance(data, dict):
        return empty_state()
    cats, accts = data.get("categories"), data.get("accounts")
    return {**data, "version": 1,
            "categories": cats if isinstance(cats, dict) else {},
            "accounts": accts if isinstance(accts, dict) else {}}


def _txn_pick(state: dict, txn_id: str) -> tuple[str, str] | None:
    """The category the user set on one transaction only (state["txn"][id])."""
    v = (state.get("txn") or {}).get(txn_id)
    if isinstance(v, dict) and v.get("category"):
        return v["category"], v.get("subcategory") or ""
    return None


def save_state(state: dict, path: Path | str | None = None) -> None:
    """Atomic write (temp file then rename), the way the widget writes it."""
    target = Path(path or default_state_path())
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, target)


def set_category(conn, txn_id: str, category: str, sub: str = "", only_this: bool = False,
                 path: Path | str | None = None) -> dict:
    """Teach the category: for every transaction of this payee (default) or for this one only.
    An empty category removes the answer. Returns the saved state."""
    row = conn.execute("SELECT group_key FROM transactions WHERE id = ?", (txn_id,)).fetchone()
    if not row:
        raise ValueError(f"Unknown transaction {txn_id}")
    if category and (category not in _types() or (sub and not _valid_sub(category, sub))):
        raise ValueError(f"Unknown category {category!r} / {sub!r}")
    state = load_state(path)
    bucket, key = ("txn", txn_id) if only_this else ("categories", row["group_key"])
    table = state.get(bucket)
    table = dict(table) if isinstance(table, dict) else {}
    if category:
        table[key] = {"category": category, "subcategory": sub or ""}
    else:
        table.pop(key, None)
    state[bucket] = table
    if not only_this:                         # a payee-wide answer replaces this row's own one
        own = dict(state.get("txn") or {})
        if own.pop(txn_id, None) is not None:
            state["txn"] = own
    save_state(state, path)
    if category and not only_this:
        # A payee-wide answer loses to a category set on this row's own bill, so check that
        # this row really took it; if not, pin it on the row as well.
        got = {d["id"]: d for d in drafts(conn, state, all_rows=True, with_notes=False)}.get(txn_id)
        if got and got["kind"] != "transfer" and (got["category"], got["subcategory"]) != (category, sub or ""):
            pins = dict(state.get("txn") or {})
            pins[txn_id] = {"category": category, "subcategory": sub or ""}
            state["txn"] = pins
            save_state(state, path)
    return state


def account_names(state: dict | None = None) -> list[str]:
    names: list[str] = []
    for n in list(ACCOUNT_MAP.values()) + [v for v in ((state or {}).get("accounts") or {}).values()]:
        if isinstance(n, str) and n and n not in names:
            names.append(n)
    return names


# --------------------------------------------------------------------- helpers

def escape_percent(text: str) -> str:
    """Cashew decodes values twice: a literal % must be written %25."""
    return text.replace("%", "%25")


def _squash(s: str | None) -> str:
    return " ".join((s or "").split())


def format_amount(paise: int) -> str:
    sign = "-" if paise < 0 else ""
    return f"{sign}{abs(paise) // 100}.{abs(paise) % 100:02d}"


def _types() -> dict[str, str]:
    return {c["name"]: c["type"] for c in load_categories()}


def _fits(ctype: str, negative: bool) -> bool:
    """A credit may get income / balance; a debit expense / balance."""
    return ctype == "balance" or (ctype == "expense" if negative else ctype == "income")


def _friend_fits(cat: str, sub: str, negative: bool) -> bool:
    """Friend Settlement is an expense-type category in the user's list, but
    the default for an HDFC savings row with nothing else to go on covers both
    directions (money out and money in, subcategory Split Paid), so the sign rule
    is explicitly relaxed for exactly that pair and no other."""
    return cat == FRIEND and sub == FRIEND_SUB


@functools.lru_cache(maxsize=None)
def _rx(pattern: str):
    return re.compile(pattern, re.I)


def _rule_hit(rule: dict, text: str) -> bool:
    m = rule.get("match")
    if isinstance(m, list):
        low = text.lower()
        return any(str(k).lower() in low for k in m)
    return bool(m) and _rx(m).search(text) is not None


_NAME_DENY = {"upi", "app", "items", "unknown", "others", "other", "item"}


def category_from_name(name: str | None) -> tuple[str, str] | None:
    """A name the user gave a payee can carry its category: "Petrol-TIMBER FUELS"
    means Transport / Petrol, and a name that IS a subcategory ("RD") or a category
    ("Groceries") means that one. The word before the first "-", ":" or "|" (or the
    whole name) is matched case-insensitively against the category names and the
    subcategory names. A subcategory name used by two categories ("Rent", "Others",
    "Travel", "Settle") is ambiguous and is skipped, and so are a few generic words
    ("UPI" is a Cashback subcategory but starts many raw bank texts)."""
    text = " ".join((name or "").split())
    if not text:
        return None
    head = re.split(r"\s*[-:|]\s*", text, maxsplit=1)[0].strip().lower()
    if not head or head in _NAME_DENY:
        return None
    cats = load_categories()
    for c in cats:
        if c["name"].lower() == head:
            return c["name"], ""
    owners = [(c["name"], sub) for c in cats for sub in (c.get("subcategories") or []) if sub.lower() == head]
    return owners[0] if len(owners) == 1 else None


def choose_category(title: str, merchant: str, group_key: str, negative: bool, state: dict,
                    rules: list[dict] | None = None, types: dict[str, str] | None = None,
                    bill_user: tuple[str, str] | None = None, bill_llm: tuple[str, str] | None = None,
                    friend_default: bool = False, assigned_name: str | None = None,
                    txn_pick: tuple[str, str] | None = None) -> tuple[str, str, str]:
    """(category, subcategory, warning). First hit wins: (a) the category the
    user set on the linked bill, (b) the merchant mapping the user taught,
    (c) the category written in the name the user gave the payee
    ("Petrol-TIMBER FUELS", `assigned_name`), (d) the linked bill's model
    category, (e) keyword rules, (f) Friend Settlement for an HDFC savings row
    with nothing else (`friend_default`), (g) Uncategorized."""
    types = types or _types()
    rules = load_rules() if rules is None else rules
    taught = (state.get("categories") or {}).get(group_key)
    pick, source = None, ""
    if txn_pick and txn_pick[0]:
        pick, source = txn_pick, "category set on this transaction"
    elif bill_user and bill_user[0]:
        pick, source = bill_user, "bill category"
    elif isinstance(taught, dict) and taught.get("category"):
        pick, source = (taught["category"], taught.get("subcategory") or ""), "taught category"
    elif (named := category_from_name(assigned_name)) and named[0] in types and _fits(types[named[0]], negative):
        pick, source = named, "name you gave it"
    else:
        # the model's pick counts only when it names a real category that fits
        if bill_llm and bill_llm[0] in types and _fits(types[bill_llm[0]], negative):
            return bill_llm[0], bill_llm[1] if _valid_sub(bill_llm[0], bill_llm[1]) else "", ""
        text = f"{title} {merchant}"
        for rule in rules:
            if rule.get("sign") and (rule["sign"] == "debit") != negative:
                continue
            if _rule_hit(rule, text):
                pick, source = (rule["category"], rule.get("subcategory") or ""), "rule"
                break
    if pick is None:
        if friend_default:
            return FRIEND, FRIEND_SUB, ""
        return (*UNCATEGORIZED, "")
    if pick[0] not in types:
        return (*UNCATEGORIZED, f"{source} names unknown category {pick[0]!r}")
    if not _fits(types[pick[0]], negative):
        return (*UNCATEGORIZED, f"{source} {pick[0]!r} does not fit a {'debit' if negative else 'credit'}")
    return pick[0], pick[1], ""


def _valid_sub(cat: str, sub: str) -> bool:
    for c in load_categories():
        if c["name"] == cat:
            return not sub or sub in (c.get("subcategories") or [])
    return False


def _bill_categories(conn) -> dict[str, dict]:
    """transaction id -> {"source": llm|user, "category", "subcategory"} for linked bills."""
    try:
        return {r["transaction_id"]: dict(r) for r in conn.execute(
            "SELECT l.transaction_id, c.category, c.subcategory, c.source FROM receipt_links l "
            "JOIN receipt_categories c ON c.receipt_id = l.receipt_id "
            "WHERE l.state = 'linked' AND l.transaction_id IS NOT NULL")}
    except sqlite3.Error:                        # a database from before v20
        return {}


def _linked_ids(conn) -> set[str]:
    try:
        return {r[0] for r in conn.execute(
            "SELECT transaction_id FROM receipt_links WHERE state = 'linked' AND transaction_id IS NOT NULL")}
    except sqlite3.Error:
        return set()


def display_title(bank: str, merchant: str, group_key: str, counterparty: str | None, overrides: dict) -> str:
    """Port of Model.js transactionDisplayName, cut at 250."""
    name = overrides.get(group_key) or counterparty
    if not name:
        parsed = keys.parsed_counterparty(bank, merchant)
        name = parsed["name"] if parsed and parsed["name"] else merchant
    return _squash(name)[:TITLE_MAX]


_JUNK_REMARKS = (
    "na", "none", "nil", "note", "upi", "no remarks", "no remark", "noremarks", "payment", "payment from phonepe",
    "paid via cred", "sent from paytm", "paying", "pay", "paid", "sent", "to pay", "request", "account", "gpay",
    "google pay", "bhim", "phonepe", "paytm", "cred", "upi autopay", "upi mandate", "indian clearing corporation",
    "payment for", "upi payment", "money transfer", "transfer", "p2v", "p2m", "p2a",
)
_BANK_WORDS = re.compile(r"\b(bank|ltd|limited)\b", re.I)
_BANK_CODES = {"hdfc", "sbi", "sbin", "axis", "utib", "icic", "icici", "kkbk", "yesb", "fdrl", "barb", "canara",
               "hdfc bank", "ybs"}
REMARK_MIN = 3


def _alnum(s: str) -> str:
    return re.sub(r"[^0-9a-z]", "", (s or "").lower())


def _clean_remark(remark: str, name: str) -> str:
    """The remark if a person typed it, else "". Truncated remarks stay as they are."""
    r = _squash(remark)
    n = _alnum(r)
    if len(r) < REMARK_MIN or "@" in r or not re.search(r"[A-Za-z]", r):
        return ""                                    # too short, a VPA, or only digits and signs
    if _BANK_WORDS.search(r) or _alnum(r) in {_alnum(c) for c in _BANK_CODES}:
        return ""                                    # a bank name sits in the remark field
    if any(j == n or j.startswith(n) for j in map(_alnum, _JUNK_REMARKS)):
        return ""                                    # boilerplate, also when the bank cut it short
    nm = _alnum(name)
    if nm and (n == nm or nm.startswith(n)):
        return ""                                    # the merchant name again
    return r


def upi_remark(merchant: str, bank: str) -> str:
    """The free text a payer typed in a UPI payment ("MF and RD"), or "".

    SBI: UPI- TRANSFER TO <acct> UPI/DR/<ref>/<name>/<bank>/<vpa>/<remark>, cut at 80
    characters (remarks come out cut short). HDFC: UPI-<name>-<vpa>-<ifsc>-<ref>-<remark>.
    Axis writes UPI/P2A/<ref>/<name>/<bank>/<remark>/ or UPI/P2A/<ref>/<name>/<remark>/<bank name>;
    in a merchant payment (P2M) the field is a mandate label ("UPI Auto") and drops out as junk."""
    merchant = merchant or ""
    if bank == "AXIS":
        m = re.match(r"^UPI/P2[AMV]/\d+/([^/]*)/([^/]*)(?:/([^/]*))?", merchant)
        if not m:
            return ""
        name, f2, f3 = _squash(m.group(1)), _squash(m.group(2)), _squash(m.group(3))
        return _clean_remark(f2 if _BANK_WORDS.search(f3) else f3, name)
    parsed = keys.parsed_counterparty(bank, merchant)
    if not parsed or bank not in ("SBI", "HDFC"):
        return ""
    return _clean_remark(parsed["remark"], parsed["name"])


def _money(paise: int | None) -> str:
    p = paise or 0
    return "₹" + (str(p // 100) if p % 100 == 0 and p >= 0 else format_amount(p))


def _qty(qty_e4: int | None, unit: str | None) -> str:
    if qty_e4 is None:
        return "1"
    q = f"{qty_e4 / 10000:.3f}".rstrip("0").rstrip(".")
    return f"{q} {unit}" if unit else q


def bill_note(conn, txn_id: str, title: str) -> str:
    """The concise itemised bill of the receipt linked to a transaction, or "".
    Besides the items it lists the charges (a waived one as FREE), the discount,
    the tax and the amount paid."""
    try:
        r = conn.execute("SELECT r.id, r.merchant, r.date, r.total_paise, r.tax_paise, r.discount_paise, "
                         "r.printed_total_paise FROM receipt_links l "
                         "JOIN receipts r ON r.id = l.receipt_id WHERE l.transaction_id = ? AND l.state = 'linked'",
                         (txn_id,)).fetchone()
        if not r:
            return ""
        items = conn.execute("SELECT description, qty_e4, unit, amount_paise FROM receipt_items "
                             "WHERE receipt_id = ? ORDER BY line_no", (r["id"],)).fetchall()
        fees = conn.execute("SELECT label, amount_paise, waived FROM receipt_fees "
                            "WHERE receipt_id = ? ORDER BY line_no", (r["id"],)).fetchall()
    except sqlite3.Error:
        return ""
    if not items:
        return ""                                    # a bare total says nothing the amount does not
    merchant = _squash(r["merchant"])
    head = ""
    if merchant and _alnum(merchant) != _alnum(title):
        head = f"{merchant} · {r['date']}" if r["date"] else merchant
    lines = [f"• {_qty(i['qty_e4'], i['unit'])} × {_squash(i['description'])} — {_money(i['amount_paise'])}"
             for i in items]
    tail = []
    for f in fees:
        tail.append(f"• {_squash(f['label'])} — " + ("FREE" if f["waived"] else _money(f["amount_paise"])))
    if r["discount_paise"]:
        tail.append(f"Discount -{_money(abs(r['discount_paise']))}")
    paid = r["printed_total_paise"] if r["printed_total_paise"] is not None else r["total_paise"]
    if paid is not None:
        tail.append(f"Total {_money(paid)}")
    if r["tax_paise"]:
        tail.append(f"GST {_money(r['tax_paise'])}")
    shown = lines[:BILL_ITEMS]

    def build(n: int) -> list[str]:
        body = lines[:n]
        if len(lines) > n:
            body.append(f"• +{len(lines) - n} more items")
        return ([head] if head else []) + body + tail

    n = len(shown)
    while n > 0 and len("\n".join(build(n))) > NOTES_MAX:
        n -= 1
    out = build(n)
    while out and len("\n".join(out)) > NOTES_MAX:
        out.pop()
    return "\n".join(out)


def build_notes(bank: str, merchant: str, widget_note: str | None, bill: str) -> str:
    """Empty unless something means something: the UPI remark, the user's own note, the bill."""
    parts = []
    remark = upi_remark(merchant, bank)
    if remark:
        parts.append(remark)
    own = _squash(widget_note)
    if own and own != _squash(keys.note(bank, merchant)) and _alnum(own) != _alnum(remark):
        parts.append(own)                            # a note the user wrote, not the one read from the row
    if bill:
        parts.append(bill)
    lines = "\n".join(parts).split("\n")
    while len(lines) > 1 and len("\n".join(lines)) > NOTES_MAX:
        lines.pop()                                  # cut on a line boundary
    return "\n".join(lines)[:NOTES_MAX]


def open_readonly(path) -> sqlite3.Connection:
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


# ---------------------------------------------------------------------- drafts

def drafts(conn, state: dict | None = None, all_rows: bool = False, with_notes: bool = True) -> list[dict]:
    # all_rows: also tracked and unsettled rows (the widget's rows show a category for those too).
    # with_notes=False skips the Cashew note text (one bill query per row): the snapshot only needs the category.
    state = state or empty_state()
    types, rules = _types(), load_rules()
    rows = [dict(r) for r in conn.execute(
        "SELECT t.id, t.date, t.merchant, t.amount_paise, t.account_id, t.status, t.group_key, t.counterparty, "
        "t.note, a.account_type, a.bank, a.last4, (k.transaction_id IS NOT NULL) AS tracked "
        "FROM transactions t JOIN accounts a ON a.id = t.account_id "
        "LEFT JOIN tracked k ON k.transaction_id = t.id "
        "ORDER BY t.date, t.seq, t.id")]
    by_id = {r["id"]: r for r in rows}
    split = {r[0] for r in conn.execute("SELECT txn_id FROM transfer_splits")}
    pairs, hits, _names = transfers.resolve(rows)
    legs: dict[str, dict] = {}
    for p in pairs:
        if p["outId"] in split or p["inId"] in split:
            continue
        for tid, other in ((p["outId"], p["inId"]), (p["inId"], p["outId"])):
            peer, own = by_id[other], by_id[tid]
            # a transfer inside one bank (bank account <-> its card) names the account, else the bank
            label = (ACCOUNT_MAP.get(peer["account_id"]) if peer["bank"] == own["bank"] else None) \
                or BANK_NAMES.get(peer["bank"], peer["bank"])
            legs[tid] = {"pairId": p["id"], "peer": label, "partnerTracked": bool(peer["tracked"])}
    for h in hits:
        if h["id"] not in split and h["id"] not in legs:
            other = h["other"]
            legs[h["id"]] = {"pairId": "", "peer": BANK_NAMES.get(other, other) if other else ""}
    overrides = {r[0]: r[1] for r in conn.execute("SELECT group_key, name FROM merchant_names")}
    acct_over = state.get("accounts") or {}
    bill_cats, linked = _bill_categories(conn), _linked_ids(conn)

    out = []
    for r in rows:
        if not all_rows and r["tracked"]:
            continue
        negative = r["amount_paise"] < 0
        title = display_title(r["bank"], r["merchant"], r["group_key"], r["counterparty"], overrides)
        warn = ""
        from_bill = False                       # the category comes from a bill the user categorised
        leg = legs.get(r["id"])
        if leg:
            kind, (cat, sub) = "transfer", (BALANCE, "")
            # A name the user gave this payee group (merchant_names) always wins; the
            # generated "Transfer to <bank>" is only the fallback.
            title = overrides.get(r["group_key"]) or (
                (f"Transfer to {leg['peer']}" if leg["peer"] else "Transfer out") if negative else
                (f"Transfer from {leg['peer']}" if leg["peer"] else "Transfer in"))
        else:
            kind = "spend" if negative else "income"
            bc = bill_cats.get(r["id"])
            from_bill = bool(bc and bc["source"] == "user")
            cat, sub, warn = choose_category(
                title, r["merchant"], r["group_key"], negative, state, rules, types,
                bill_user=(bc["category"], bc["subcategory"]) if bc and bc["source"] == "user" else None,
                bill_llm=(bc["category"], bc["subcategory"]) if bc and bc["source"] == "llm" else None,
                # HDFC savings (not a card, not another bank), no bill, nothing else to go on
                friend_default=(r["bank"] == "HDFC" and r["account_type"] == "checking" and r["id"] not in linked),
                assigned_name=overrides.get(r["group_key"]),
                txn_pick=_txn_pick(state, r["id"]))
        aid = r["account_id"]
        account = acct_over[aid] if aid in acct_over else ACCOUNT_MAP.get(aid, "")
        out.append({
            "id": r["id"], "include": not (leg and leg.get("partnerTracked") and not r["tracked"]), "pending": r["status"] != "settled", "fromBill": from_bill, "partnerTracked": bool(leg and leg.get("partnerTracked")), "date": r["date"], "title": title,
            "amount": format_amount(r["amount_paise"]), "category": cat, "subcategory": sub,
            "account": account or "",
            "notes": build_notes(r["bank"], r["merchant"], r["note"], bill_note(conn, r["id"], title)) if with_notes else "",
            "kind": kind, "bank": r["bank"], "last4": r["last4"], "accountId": aid,
            "groupKey": r["group_key"], "merchant": r["merchant"] or "", "pairId": leg["pairId"] if leg else "", "warn": warn,
        })
    return out


# ----------------------------------------------------------------------- links

def _entry(d: dict, warnings: list[str], types: dict[str, str]) -> dict:
    label = f"{d.get('title') or d.get('id')} ({d.get('date', '')})"
    title, notes = str(d.get("title") or ""), str(d.get("notes") or "")
    if len(title) > TITLE_MAX:
        warnings.append(f"title cut to {TITLE_MAX} characters: {label}")
        title = title[:TITLE_MAX]
    if len(notes) > NOTES_MAX:
        warnings.append(f"notes cut to {NOTES_MAX} characters: {label}")
        notes = notes[:NOTES_MAX]
    cat, sub, acct = str(d.get("category") or ""), str(d.get("subcategory") or ""), str(d.get("account") or "")
    amount = str(d.get("amount") or "")
    if cat == UNCATEGORIZED[0] and sub != "Miscellaneous":      # Miscellaneous is a deliberate choice
        warnings.append(f"no category: {label}")
    elif cat in types and not _fits(types[cat], amount.startswith("-")) \
            and not _friend_fits(cat, sub, amount.startswith("-")):
        warnings.append(f"category {cat!r} does not fit the amount sign: {label}")
    e = {"amount": amount, "title": escape_percent(title), "date": str(d.get("date") or ""),
         "notes": escape_percent(notes), "category": escape_percent(cat)}
    if sub:
        e["subcategory"] = escape_percent(sub)
    if acct:
        e["account"] = escape_percent(acct)
    e["fallbackCategory"] = FALLBACK_CATEGORY      # never the forced "Select Category" prompt
    return e


def normalize_base(base) -> str:
    """"web" -> the Cashew web app, anything else -> the app."""
    return WEB_BASE if base == "web" else APP_BASE


def _url(entries: list[dict], base: str = APP_BASE) -> tuple[str, str]:
    text = json.dumps({"transactions": entries}, ensure_ascii=False, separators=(",", ":"))
    return base + "addTransaction?JSON=" + urllib.parse.quote(text, safe=""), text


def _abs_amount(amount) -> str:
    return str(amount or "").lstrip("+-")


def _pair_legs(inc: list[dict]) -> dict[str, tuple[dict, dict]]:
    """pairId -> (out leg, in leg) for each pair with exactly one debit and one credit included."""
    groups: dict[str, list[dict]] = {}
    for d in inc:
        if d.get("pairId"):
            groups.setdefault(d["pairId"], []).append(d)
    out = {}
    for pid, legs in groups.items():
        outs = [d for d in legs if str(d.get("amount") or "").startswith("-")]
        ins = [d for d in legs if not str(d.get("amount") or "").startswith("-")]
        if len(legs) == 2 and len(outs) == 1 and len(ins) == 1:
            out[pid] = (outs[0], ins[0])
    return out


def _transfer(out_leg: dict, in_leg: dict, base: str) -> dict:
    title, date = str(out_leg.get("title") or ""), str(out_leg.get("date") or "")
    a_from, a_to = str(out_leg.get("account") or ""), str(in_leg.get("account") or "")
    parts = [("amountFrom", _abs_amount(out_leg.get("amount"))), ("amountTo", _abs_amount(in_leg.get("amount"))),
             ("accountFrom", a_from), ("accountTo", a_to), ("title", title), ("date", date)]
    query = "&".join(f"{k}={urllib.parse.quote(escape_percent(v), safe='')}" for k, v in parts if v)
    return {"url": base + "addTransferRoute?" + query, "pairId": out_leg["pairId"], "title": title, "date": date,
            "amount": _abs_amount(out_leg.get("amount")), "accountFrom": a_from, "accountTo": a_to,
            "ids": [out_leg.get("id"), in_leg.get("id")]}


def build_links(draft_list: list[dict], max_chars: int = DEFAULT_MAX_CHARS, base: str = "app") -> dict:
    """{"links": [{url, count, chars, ids, json}], "transfers": [{url, pairId, title, date, amount,
    accountFrom, accountTo, ids}], "warnings": [..]}. `base` is "app" or "web"."""
    types, warnings = _types(), []
    root = normalize_base(base)
    inc = [d for d in draft_list if d.get("include", True)]
    inc.sort(key=lambda d: (str(d.get("date") or ""), str(d.get("id") or "")))
    paired = _pair_legs(inc)
    leg_ids = {id(x) for pair in paired.values() for x in pair}
    bulk = [d for d in inc if id(d) not in leg_ids]
    entries = {id(d): _entry(d, warnings, types) for d in bulk}
    for d in inc:
        if d.get("kind") == "transfer" and id(d) not in leg_ids:
            warnings.append(f"transfer leg without partner: {d.get('title')} ({d.get('date')})")
    transfer_list = [_transfer(o, i, root) for o, i in sorted(
        paired.values(), key=lambda p: (str(p[0].get("date") or ""), str(p[0].get("id") or "")))]
    units: list[list[dict]] = []
    by_pair: dict[str, list[dict]] = {}
    for d in bulk:
        pid = d.get("pairId")
        if pid:
            if pid not in by_pair:
                by_pair[pid] = []
                units.append(by_pair[pid])
            by_pair[pid].append(d)
        else:
            units.append([d])
    batches: list[list[dict]] = []
    cur: list[dict] = []
    for unit in units:
        trial = cur + unit
        if cur and len(_url([entries[id(d)] for d in trial], root)[0]) > max_chars:
            batches.append(cur)
            cur = list(unit)
        else:
            cur = trial
    if cur:
        batches.append(cur)
    links = []
    for b in batches:
        b.sort(key=lambda d: (str(d.get("date") or ""), str(d.get("id") or "")))
        url, text = _url([entries[id(d)] for d in b], root)
        if len(url) > max_chars:
            warnings.append(f"one link is {len(url)} characters, over the {max_chars} limit: {b[0].get('title')}")
        links.append({"url": url, "count": len(b), "chars": len(url), "ids": [d.get("id") for d in b], "json": text})
    return {"links": links, "transfers": transfer_list, "warnings": warnings}


def category_mismatches(conn, state: dict | None = None) -> list[dict]:
    """Rows where an answer the user saved (payee-wide or on the row) is not the category Cashew
    would use. Empty means every saved answer is in force. Used by `txdb check`."""
    state = state or load_state()
    cats, pins = state.get("categories") or {}, state.get("txn") or {}
    group = {r["id"]: r["group_key"] for r in conn.execute("SELECT id, group_key FROM transactions")}
    out = []
    for d in drafts(conn, state, all_rows=True):
        if d["kind"] == "transfer":
            continue
        want = pins.get(d["id"]) or cats.get(group.get(d["id"]))
        if not isinstance(want, dict) or not want.get("category"):
            continue
        wanted = (want["category"], want.get("subcategory") or "")
        if (d["category"], d["subcategory"]) != wanted:
            out.append({"id": d["id"], "date": d["date"], "merchant": d["merchant"], "wanted": wanted,
                        "shows": (d["category"], d["subcategory"]), "tracked": None})
    return out
