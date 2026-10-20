"""One-off import of the JSON files the widget and fetchers used before the
database. Safe to run again: rows and settings are upserted, and the JSON
files are only read, never changed."""
from __future__ import annotations

import json
import os
from pathlib import Path

from . import ingest, keys
from .db import now, write

WORK = Path(os.environ.get("TXDB_WORK", "/home/pc/Work"))
STATE = Path(os.environ.get("TXDB_STATE", Path.home() / ".local/state/omarchy"))
SOURCES = {
    "HDFC": WORK / "hdfc-statement-fetcher/output",
    "AXIS": WORK / "axis-statement-fetcher/output",
    "SBI": WORK / "sbi-statement-fetcher/output",
}


def _load(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def _account_for_last4(conn, last4: str, prefer_type: str | None = None) -> str | None:
    rows = conn.execute("SELECT id, account_type FROM accounts WHERE last4 = ?", (last4,)).fetchall()
    if prefer_type:
        rows = [r for r in rows if r["account_type"] == prefer_type] or rows
    if len(rows) > 1:
        raise SystemExit(f"last4 {last4} matches more than one account: {[r['id'] for r in rows]}")
    return rows[0]["id"] if rows else None


def run(conn) -> dict:
    report = {}
    for bank, folder in SOURCES.items():
        rows = _load(folder / f"{bank.lower()}_transactions.json", [])
        by_account: dict[tuple, list] = {}
        for r in rows:
            by_account.setdefault((r["bank"], r["accountType"], r["last4"]), []).append(r)
        for (b, account_type, last4), items in by_account.items():
            aid = ingest.ensure_account(conn, b, account_type, last4)
            settled = [i for i in items if i.get("status") != "unsettled"]
            unsettled = [i for i in items if i.get("status") == "unsettled"]
            # Older rows first, so seq grows with statement time within a day.
            n = len(settled)
            prepared = [{**i, "seq": n - k, "raw": {"description": i["merchant"]}} for k, i in enumerate(settled)]
            ingest.upsert_rows(conn, aid, prepared)
            if unsettled:
                ingest.replace_unsettled(conn, aid, [{**i, "raw": {"description": i["merchant"], "status": "unsettled"}}
                                                     for i in unsettled])
        report[f"{bank} transactions (json)"] = len(rows)
        report[f"{bank} transactions (db)"] = ingest.count(conn, bank)

        for b in _load(folder / f"{bank.lower()}_account_balances.json", []):
            aid = ingest.ensure_account(conn, b["bank"], b["accountType"], b["last4"])
            ingest.set_balance(conn, aid, b.get("balance"), b.get("currency", "INR"), b.get("asOf"))

    for o in _load(SOURCES["HDFC"] / "hdfc_creditcard_overview.json", []):
        if o.get("last4"):
            aid = ingest.ensure_account(conn, "HDFC", "credit", o["last4"])
            ingest.set_card_cycle(conn, aid, o)

    tracked = _load(STATE / "transactions-tracked.json", {})
    with write(conn):
        for tid, on in tracked.items():
            if on:
                conn.execute("INSERT OR IGNORE INTO tracked (transaction_id, tracked_at) VALUES (?, ?)", (tid, now()))
    report["tracked (json)"] = sum(1 for v in tracked.values() if v)
    report["tracked (db)"] = conn.execute("SELECT COUNT(*) FROM tracked").fetchone()[0]

    # Renames: new-style keys ("SBI|…", "AXIS|…") stay; an old raw-prefix key
    # gets the bank of the rows whose old-style key it matched.
    names = _load(STATE / "transactions-custom-names.json", {})
    unmatched = []
    with write(conn):
        for key, name in names.items():
            if key.split("|", 1)[0] in ("SBI", "AXIS", "HDFC") and "|" in key:
                targets = [key]
            else:
                targets = sorted({f"{r['bank']}|{key}" for r in conn.execute(
                    "SELECT a.bank, t.merchant FROM transactions t JOIN accounts a ON a.id = t.account_id")
                    if keys.legacy_group_key(r["merchant"]) == key})
            if not targets:
                unmatched.append(key)
            for target in targets:
                conn.execute("INSERT OR REPLACE INTO merchant_names (group_key, name, updated_at) VALUES (?,?,?)",
                             (target, name, now()))
    report["renames (json)"] = len(names)
    report["renames (db)"] = conn.execute("SELECT COUNT(*) FROM merchant_names").fetchone()[0]
    report["renames matching no transaction"] = unmatched

    with write(conn):
        for last4, name in _load(STATE / "transactions-account-names.json", {}).items():
            aid = _account_for_last4(conn, last4)
            if aid:
                conn.execute("UPDATE accounts SET display_name = ? WHERE id = ?", (name, aid))
        for last4, bill in _load(STATE / "transactions-bills.json", {}).items():
            aid = _account_for_last4(conn, last4, prefer_type="credit")
            if aid:
                conn.execute("INSERT OR REPLACE INTO bills (account_id, marked_paid, notified_date) VALUES (?,?,?)",
                             (aid, 1 if bill.get("markedPaid") else 0, bill.get("notifiedDate")))
    report["accounts"] = [r[0] for r in conn.execute("SELECT id FROM accounts ORDER BY id")]
    return report
