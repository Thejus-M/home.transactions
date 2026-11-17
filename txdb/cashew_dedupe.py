"""Which drafts Cashew already has, so "Add all" never sends a row twice.

Read from the copy of the Cashew web database the browser keeps (cashew_twins.find_browser_copy). A draft is
"in Cashew" when Cashew holds a row on the same local day, with the same amount (rounded to paise: Cashew keeps
floats like 814.9999999999999) in the account of the same name. The title is not compared: it changes when the
user renames a payee. Counted one to one: three real "-1.00 HDFC" rows on one day need three Cashew rows.
"""
from __future__ import annotations

import sqlite3
from collections import Counter
from datetime import datetime


def _key(day: str, amount, account: str) -> tuple[str, int, str]:
    return day, round(float(amount) * 100), account


def cashew_rows(conn: sqlite3.Connection) -> tuple[dict, set[str]]:
    """({(day, paise, account name): [(transaction pk, note), ...]} oldest first, the account names)."""
    wallets = {r[0]: r[1] for r in conn.execute("SELECT wallet_pk, name FROM wallets")}
    rows: dict = {}
    for pk, created, amount, wallet, note in conn.execute(
            "SELECT transaction_pk, date_created, amount, wallet_fk, note FROM transactions ORDER BY date_created, transaction_pk"):
        if created is None or amount is None:
            continue
        day = datetime.fromtimestamp(int(created)).strftime("%Y-%m-%d")
        rows.setdefault(_key(day, amount, wallets.get(wallet, "")), []).append((pk, note or ""))
    return rows, set(wallets.values())


def cashew_counts(conn: sqlite3.Connection) -> tuple[Counter, set[str]]:
    """(Counter of (day, paise, account name), the account names) of a Cashew database."""
    rows, names = cashew_rows(conn)
    return Counter({k: len(v) for k, v in rows.items()}), names


DAY_TOLERANCE = 4          # a bank date can be 2 to 4 days before or after the date in Cashew
RECURRING_TOLERANCE = 7    # a payment of a recurring series in Cashew can be up to a week off


def recurring_keys(conn: sqlite3.Connection) -> set[tuple[int, str]]:
    """{(paise, account name)} of the recurring rows in Cashew (type 1 subscription, 2 repeating)."""
    wallets = {r[0]: r[1] for r in conn.execute("SELECT wallet_pk, name FROM wallets")}
    if "type" not in {r[1] for r in conn.execute("PRAGMA table_info(transactions)")}:
        return set()
    return {(round(float(a) * 100), wallets.get(w, "")) for a, w in conn.execute(
        "SELECT amount, wallet_fk FROM transactions WHERE type IN (1, 2) AND amount IS NOT NULL")}


def _days(a: str, b: str) -> int:
    return abs((datetime.strptime(a, "%Y-%m-%d") - datetime.strptime(b, "%Y-%m-%d")).days)


def mark(drafts: list[dict], conn: sqlite3.Connection, tolerance: int = DAY_TOLERANCE) -> dict:
    """Mark the drafts Cashew already has: inCashew = True, include = False, cashewPk, cashewNote and
    inCashewDays (0 = same day). One Cashew row per draft.
    Pass 1: same day, same amount, same account. Pass 2, for the rest: same amount and account, a Cashew date
    up to `tolerance` days away (RECURRING_TOLERANCE when the amount and account are those of a recurring
    series in Cashew), the nearest first (the earlier one on a tie). Returns {"ok": True, "found": n,
    "unknownAccounts": [...]}: a draft whose account name Cashew does not know cannot be checked."""
    rows, names = cashew_rows(conn)
    found, unknown, rest = 0, set(), []

    def hit(d, pk, note, days):
        nonlocal found
        d["inCashew"] = True
        d["cashewPk"] = pk                         # which Cashew row (for the note)
        d["cashewNote"] = note
        d["inCashewDays"] = days
        d["include"] = False
        found += 1

    for d in sorted(drafts, key=lambda x: (str(x.get("date") or ""), str(x.get("id") or ""))):
        acct = str(d.get("account") or "")
        try:
            key = _key(str(d.get("date") or ""), d.get("amount") or 0, acct)
        except (TypeError, ValueError):
            continue
        if acct not in names:
            if d.get("include", True):
                unknown.add(acct or "(no account)")
            continue
        if rows.get(key):
            pk, note = rows[key].pop(0)
            hit(d, pk, note, 0)
        else:
            rest.append((d, key))
    if tolerance > 0 and rest:
        # what pass 1 left in Cashew, by (amount, account): [(day, pk, note)]
        left: dict = {}
        for (day, paise, acct), entries in rows.items():
            for pk, note in entries:
                left.setdefault((paise, acct), []).append([day, pk, note])
        rec = recurring_keys(conn)
        for d, (day, paise, acct) in rest:
            tol = max(tolerance, RECURRING_TOLERANCE) if (paise, acct) in rec else tolerance
            cands = [c for c in left.get((paise, acct), []) if _days(c[0], day) <= tol]
            if not cands:
                continue
            best = min(cands, key=lambda c: (_days(c[0], day), c[0]))
            left[(paise, acct)].remove(best)
            hit(d, best[1], best[2], _days(best[0], day))
    return {"ok": True, "found": found, "unknownAccounts": sorted(unknown)}
