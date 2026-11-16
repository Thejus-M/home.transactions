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


def cashew_counts(conn: sqlite3.Connection) -> tuple[Counter, set[str]]:
    """(Counter of (day, paise, account name), the account names) of a Cashew database."""
    wallets = {r[0]: r[1] for r in conn.execute("SELECT wallet_pk, name FROM wallets")}
    counts: Counter = Counter()
    for created, amount, wallet in conn.execute("SELECT date_created, amount, wallet_fk FROM transactions"):
        if created is None or amount is None:
            continue
        day = datetime.fromtimestamp(int(created)).strftime("%Y-%m-%d")
        counts[_key(day, amount, wallets.get(wallet, ""))] += 1
    return counts, set(wallets.values())


def mark(drafts: list[dict], conn: sqlite3.Connection) -> dict:
    """Mark the drafts Cashew already has: inCashew = True, include = False. Oldest first, one Cashew row
    per draft. Returns {"ok": True, "found": n, "unknownAccounts": [...]}: a draft whose account name Cashew
    does not know cannot be checked (and is listed)."""
    counts, names = cashew_counts(conn)
    found, unknown = 0, set()
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
        if counts[key] > 0:
            counts[key] -= 1
            d["inCashew"] = True
            d["include"] = False
            found += 1
    return {"ok": True, "found": found, "unknownAccounts": sorted(unknown)}
