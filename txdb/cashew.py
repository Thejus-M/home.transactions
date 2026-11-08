"""Cashew links: turn untracked transactions into addTransaction deep links.

Cashew (cashewapp.web.app) saves a transaction straight from a link:
  https://cashewapp.web.app/addTransaction?JSON=<url-encoded {"transactions":[...]}>
Cashew decodes every value twice, so a literal "%" is written "%25" inside the
JSON text before the one URL-encoding (see `escape_percent`). A transfer has no
parameter of its own: it is two "Balance Correction" entries, one per account.

`drafts()` is the editable list the widget shows; `build_links()` turns the
(possibly edited) drafts into links. Pure functions over plain data, plus a
read-only look at the database. The widget's own choices (categories taught per
merchant, account-name overrides) live in a small state file, not in the DB."""
from __future__ import annotations

import json
import os
import re
import sqlite3
import urllib.parse
from pathlib import Path

from . import keys, transfers

BASE_URL = "https://cashewapp.web.app/addTransaction?JSON="
HERE = Path(__file__).resolve().parent
TITLE_MAX = 250
NOTES_MAX = 500
DEFAULT_MAX_CHARS = 6000
UNCATEGORIZED = ("Uncategorized", "Unknown")
BALANCE = "Balance Correction"


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
    "SBI|credit|5896": "SBI ₹",
}
BANK_NAMES = {"HDFC": "HDFC", "SBI": "SBI", "AXIS": "Axis", "ICICI": "ICICI"}


# ------------------------------------------------------------------ data files

def load_categories() -> list[dict]:
    return json.loads((HERE / "cashew_categories.json").read_text(encoding="utf-8"))


def load_rules() -> list[dict]:
    return json.loads((HERE / "cashew_rules.json").read_text(encoding="utf-8"))


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


def _rule_hit(rule: dict, text: str) -> bool:
    m = rule.get("match")
    if isinstance(m, list):
        low = text.lower()
        return any(str(k).lower() in low for k in m)
    return bool(m) and re.search(m, text, re.I) is not None


def choose_category(title: str, merchant: str, group_key: str, negative: bool, state: dict,
                    rules: list[dict] | None = None, types: dict[str, str] | None = None) -> tuple[str, str, str]:
    """(category, subcategory, warning)."""
    types = types or _types()
    rules = load_rules() if rules is None else rules
    taught = (state.get("categories") or {}).get(group_key)
    pick, source = None, ""
    if isinstance(taught, dict) and taught.get("category"):
        pick, source = (taught["category"], taught.get("subcategory") or ""), "taught category"
    else:
        text = f"{title} {merchant}"
        for rule in rules:
            if rule.get("sign") and (rule["sign"] == "debit") != negative:
                continue
            if _rule_hit(rule, text):
                pick, source = (rule["category"], rule.get("subcategory") or ""), "rule"
                break
    if pick is None:
        return (*UNCATEGORIZED, "")
    if pick[0] not in types:
        return (*UNCATEGORIZED, f"{source} names unknown category {pick[0]!r}")
    if not _fits(types[pick[0]], negative):
        return (*UNCATEGORIZED, f"{source} {pick[0]!r} does not fit a {'debit' if negative else 'credit'}")
    return pick[0], pick[1], ""


def display_title(bank: str, merchant: str, group_key: str, counterparty: str | None, overrides: dict) -> str:
    """Port of Model.js transactionDisplayName, cut at 250."""
    name = overrides.get(group_key) or counterparty
    if not name:
        parsed = keys.parsed_counterparty(bank, merchant)
        name = parsed["name"] if parsed and parsed["name"] else merchant
    return _squash(name)[:TITLE_MAX]


def _notes(bank: str, last4: str, merchant: str, widget_note: str | None) -> str:
    parts = [f"{bank} ••{last4}", merchant]
    ref = transfers.upi_ref(merchant)
    if ref and ref not in merchant:
        parts.append(ref)
    if widget_note and widget_note not in merchant:
        parts.append(widget_note)
    return " | ".join(p for p in parts if p)[:NOTES_MAX]


def open_readonly(path) -> sqlite3.Connection:
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


# ---------------------------------------------------------------------- drafts

def drafts(conn, state: dict | None = None) -> list[dict]:
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
            legs[tid] = {"pairId": p["id"], "peer": label}
    for h in hits:
        if h["id"] not in split and h["id"] not in legs:
            other = h["other"]
            legs[h["id"]] = {"pairId": "", "peer": BANK_NAMES.get(other, other) if other else ""}
    overrides = {r[0]: r[1] for r in conn.execute("SELECT group_key, name FROM merchant_names")}
    acct_over = state.get("accounts") or {}

    out = []
    for r in rows:
        if r["tracked"] or r["status"] != "settled":
            continue
        negative = r["amount_paise"] < 0
        title = display_title(r["bank"], r["merchant"], r["group_key"], r["counterparty"], overrides)
        warn = ""
        leg = legs.get(r["id"])
        if leg:
            kind, (cat, sub) = "transfer", (BALANCE, "")
            title = (f"Transfer to {leg['peer']}" if leg["peer"] else "Transfer out") if negative else \
                    (f"Transfer from {leg['peer']}" if leg["peer"] else "Transfer in")
        else:
            kind = "spend" if negative else "income"
            cat, sub, warn = choose_category(title, r["merchant"], r["group_key"], negative, state, rules, types)
        aid = r["account_id"]
        account = acct_over[aid] if aid in acct_over else ACCOUNT_MAP.get(aid, "")
        out.append({
            "id": r["id"], "include": True, "date": r["date"], "title": title,
            "amount": format_amount(r["amount_paise"]), "category": cat, "subcategory": sub,
            "account": account or "", "notes": _notes(r["bank"], r["last4"], r["merchant"], r["note"]),
            "kind": kind, "bank": r["bank"], "last4": r["last4"], "accountId": aid,
            "groupKey": r["group_key"], "pairId": leg["pairId"] if leg else "", "warn": warn,
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
    if cat == UNCATEGORIZED[0]:
        warnings.append(f"no category: {label}")
    elif cat in types and not _fits(types[cat], amount.startswith("-")):
        warnings.append(f"category {cat!r} does not fit the amount sign: {label}")
    e = {"amount": amount, "title": escape_percent(title), "date": str(d.get("date") or ""),
         "notes": escape_percent(notes), "category": escape_percent(cat)}
    if sub:
        e["subcategory"] = escape_percent(sub)
    if acct:
        e["account"] = escape_percent(acct)
    return e


def _url(entries: list[dict]) -> tuple[str, str]:
    text = json.dumps({"transactions": entries}, ensure_ascii=False, separators=(",", ":"))
    return BASE_URL + urllib.parse.quote(text, safe=""), text


def build_links(draft_list: list[dict], max_chars: int = DEFAULT_MAX_CHARS) -> dict:
    """{"links": [{url, count, chars, ids, json}], "warnings": [..]}."""
    types, warnings = _types(), []
    inc = [d for d in draft_list if d.get("include", True)]
    inc.sort(key=lambda d: (str(d.get("date") or ""), str(d.get("id") or "")))
    entries = {id(d): _entry(d, warnings, types) for d in inc}
    present_pairs: dict[str, int] = {}
    for d in inc:
        if d.get("pairId"):
            present_pairs[d["pairId"]] = present_pairs.get(d["pairId"], 0) + 1
    for d in inc:
        if d.get("kind") == "transfer" and (not d.get("pairId") or present_pairs.get(d["pairId"], 0) < 2):
            warnings.append(f"transfer leg without partner: {d.get('title')} ({d.get('date')})")
    units: list[list[dict]] = []
    by_pair: dict[str, list[dict]] = {}
    for d in inc:
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
        if cur and len(_url([entries[id(d)] for d in trial])[0]) > max_chars:
            batches.append(cur)
            cur = list(unit)
        else:
            cur = trial
    if cur:
        batches.append(cur)
    links = []
    for b in batches:
        b.sort(key=lambda d: (str(d.get("date") or ""), str(d.get("id") or "")))
        url, text = _url([entries[id(d)] for d in b])
        if len(url) > max_chars:
            warnings.append(f"one link is {len(url)} characters, over the {max_chars} limit: {b[0].get('title')}")
        links.append({"url": url, "count": len(b), "chars": len(url), "ids": [d.get("id") for d in b], "json": text})
    return {"links": links, "warnings": warnings}
