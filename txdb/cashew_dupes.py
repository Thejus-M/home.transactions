"""The duplicates in Cashew: days where Cashew holds more rows of one amount in one account than the bank has.

Compares the Cashew web database (the copy the browser keeps) with the widget's own transactions, by (local
day, amount in paise, account name). A key the bank never had is left out: those rows were typed in Cashew by
hand. Report only; nothing is changed (the person deletes the extra rows in Cashew).
"""
from __future__ import annotations

import sqlite3
from collections import Counter, defaultdict
from datetime import datetime

from . import cashew


def report(cdb: sqlite3.Connection, conn: sqlite3.Connection, state: dict | None = None) -> list[dict]:
    """[{day, amount, account, inCashew, inBank, extra, names}] sorted by day."""
    wallets = {r[0]: r[1] for r in cdb.execute("SELECT wallet_pk, name FROM wallets")}
    in_cashew: Counter = Counter()
    names: dict = defaultdict(list)
    for created, amount, wallet, name in cdb.execute("SELECT date_created, amount, wallet_fk, name FROM transactions"):
        if created is None or amount is None:
            continue
        key = (datetime.fromtimestamp(int(created)).strftime("%Y-%m-%d"), round(float(amount) * 100), wallets.get(wallet, ""))
        in_cashew[key] += 1
        names[key].append(name or "")
    acct_over = (state or {}).get("accounts") or {}
    in_bank: Counter = Counter()
    for r in conn.execute("SELECT date, amount_paise, account_id FROM transactions"):
        aid = r[2]
        acct = acct_over.get(aid) or cashew.ACCOUNT_MAP.get(aid, "")
        in_bank[(r[0], int(r[1]), acct)] += 1
    out = []
    for key, bank_n in in_bank.items():
        n = in_cashew.get(key, 0)
        if n > bank_n:
            day, paise, acct = key
            out.append({"day": day, "amount": cashew.format_amount(paise), "account": acct, "inCashew": n,
                        "inBank": bank_n, "extra": n - bank_n, "names": sorted(set(names[key]))})
    return sorted(out, key=lambda x: (x["day"], x["account"], x["amount"]))
