"""One-time rebuild of the Cashew database with the widget as the single source of truth.

Input: a Cashew database (the live copy from the Chromium profile). Output: a new database file for the
person to import in Cashew. The input is never changed.

For each account the widget knows (cashew.ACCOUNT_MAP + the saved account names):
1. Match every widget row to a Cashew row (cashew_dedupe.mark: same day, then a few days off; recurring
   series up to 7 days). A matched Cashew row stays as it is (its title, note, category: Cashew has more
   detail); only a missing or unknown category is filled from the widget, and a missing widget note line is
   added (cashew_file.build, note_drafts).
2. Remove the pure balance corrections: rows in "Balance Correction" that match no widget row. (Card bill
   payments and some transfers are real rows filed under Balance Correction; they match and stay.)
3. Remove the Cashew rows that match no widget row, from the widget's first date of that account on (the
   widget is the source there). Older rows stay. Recurring rows (type 1, 2) and unpaid rows are never touched.
4. Add the widget rows Cashew lacks (cashew_file.build), with the categories given for rows that had none.
5. One Balance Correction per account where the sum still differs from the bank (cashew_file.build,
   balances): savings = the last bank balance, cards = minus the outstanding.
Accounts the widget does not know (wallets, ICICI savings, FD, ...) are not touched.
"""
from __future__ import annotations

import shutil
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path

from . import cashew, cashew_dedupe, cashew_file

BALANCE_PK = "0"


def _day(ts) -> str:
    return datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d")


def targets(conn: sqlite3.Connection, names: dict) -> list[dict]:
    """[{account, date, paise}] the widget's balance per known account: savings from `balances`, cards from
    `card_cycles` (minus the total outstanding)."""
    out = []
    for aid, bal, as_of in conn.execute("SELECT account_id, balance_paise, as_of FROM balances"):
        if names.get(aid) and bal is not None:
            out.append({"account": names[aid], "date": str(as_of)[:10], "paise": int(bal)})
    for aid, owe, fetched in conn.execute("SELECT account_id, total_outstanding_paise, fetched_at FROM card_cycles"):
        if names.get(aid) and owe is not None:
            out.append({"account": names[aid], "date": str(fetched)[:10], "paise": -int(owe)})
    return out


def rebuild(base: Path, out: Path, conn: sqlite3.Connection, state: dict, answers: dict | None = None) -> dict:
    """Write the rebuilt database to `out`. answers: {widget id: {category, subcategory}} for rows that had
    no category. Returns a report dict."""
    answers = answers or {}
    over = state.get("accounts") or {}
    names = {aid: over.get(aid) or name for aid, name in cashew.ACCOUNT_MAP.items()}
    known = set(names.values())
    drafts = [dict(d, include=True) for d in cashew.drafts(conn, state, all_rows=True)]
    drafts = [d for d in drafts if d.get("account") in known]
    with tempfile.TemporaryDirectory(prefix="cashew-rebuild-") as tmp:
        work = Path(tmp) / "work.sqlite"
        shutil.copyfile(base, work)
        c = sqlite3.connect(work)
        before = {r[0]: r[1] for r in c.execute(
            "SELECT w.name, count(*) FROM transactions t JOIN wallets w ON w.wallet_pk = t.wallet_fk GROUP BY w.name")}
        cashew_dedupe.mark(drafts, c)
        matched = {d["cashewPk"]: d for d in drafts if d.get("inCashew")}
        start: dict = {}
        for d in drafts:
            start[d["account"]] = min(start.get(d["account"], "9999"), str(d["date"]))
        wallets = {r[0]: r[1] for r in c.execute("SELECT wallet_pk, name FROM wallets")}
        removed_corr, removed_extra = [], []
        for pk, ts, wal, typ, paid, cat, amt, name, note in list(c.execute(
                "SELECT transaction_pk, date_created, wallet_fk, type, paid, category_fk, amount, name, note FROM transactions")):
            acct = wallets.get(wal)
            if acct not in known or typ in (1, 2) or pk in matched or ts is None:
                continue
            row = {"account": acct, "date": _day(ts), "amount": round(float(amt or 0), 2), "title": name or "",
                   "note": (note or "")[:80]}
            if cat == BALANCE_PK:
                removed_corr.append(row)
            elif paid == 1 and row["date"] >= start.get(acct, "9999"):
                removed_extra.append(row)
            else:
                continue
            c.execute("DELETE FROM transactions WHERE transaction_pk = ?", (pk,))
            # a delete log, as Cashew writes one: the sync then removes the row on the other devices too
            c.execute("INSERT INTO delete_logs (delete_log_pk, entry_pk, type, date_time_modified) VALUES (?, ?, 4, ?)",
                      (str(__import__("uuid").uuid4()), pk, int(datetime.now().timestamp())))
        c.commit()
        # 1. matched rows: fill a missing / unknown category from the widget
        cats = {r[0]: r[1] for r in c.execute("SELECT category_pk, name FROM categories")}
        by_name = {}
        for pk, name, main in c.execute("SELECT category_pk, name, main_category_pk FROM categories"):
            by_name[(name, main or "")] = pk
        refiled = []
        for pk, d in matched.items():
            row = c.execute("SELECT category_fk FROM transactions WHERE transaction_pk = ?", (pk,)).fetchone()
            if row is None:
                continue
            have = cats.get(row[0])
            if have and have not in cashew.UNCATEGORIZED:
                continue
            want = d.get("category")
            main = by_name.get((want, ""))
            if not want or want in cashew.UNCATEGORIZED or main is None:
                continue
            sub = by_name.get((d.get("subcategory") or "", main)) if d.get("subcategory") else None
            c.execute("UPDATE transactions SET category_fk = ?, sub_category_fk = ?, date_time_modified = ? "
                      "WHERE transaction_pk = ?", (main, sub, int(datetime.now().timestamp()), pk))
            refiled.append({"account": d["account"], "date": d["date"], "amount": d["amount"], "title": d.get("title"),
                            "from": have or "(none)", "to": want + (" › " + d["subcategory"] if d.get("subcategory") else "")})
        c.commit()
        c.close()
        # 2. the widget rows Cashew lacks, with the given categories; notes; balances
        missing = []
        for d in drafts:
            if d.get("inCashew"):
                continue
            a = answers.get(d["id"])
            if a and (d.get("category") in (None, "", cashew.UNCATEGORIZED[0])):
                d = dict(d, category=a["category"], subcategory=a.get("subcategory") or "", askAi=False, warn=None)
            missing.append(dict(d, inCashew=False))
        r = cashew_file.build(work, out, missing, note_drafts=drafts, balances=targets(conn, names))
    # the correction is an opening balance: date it just before the widget's first row of that account, so the
    # months the widget covers show only real rows (the end balance is the same)
    w = sqlite3.connect(out)
    wal = {r_[1]: r_[0] for r_ in w.execute("SELECT wallet_pk, name FROM wallets")}
    for x in r.get("corrections", []):
        first = start.get(x["account"])
        if first and wal.get(x["account"]):
            ts = int(datetime.strptime(first, "%Y-%m-%d").timestamp()) - 1
            w.execute("UPDATE transactions SET date_created = ?, name = 'Opening balance (widget)', note = ? "
                      "WHERE wallet_fk = ? AND category_fk = ? AND name = 'Balance correction'",
                      (ts, f"So the balance matches the bank: ₹{x['bank']:,.2f} on {x['date']}", wal[x["account"]], BALANCE_PK))
            x["dated"] = _day(ts)
    w.commit()
    w.close()
    o = sqlite3.connect(f"{Path(out).as_uri()}?mode=ro", uri=True)
    after = {r_[0]: r_[1] for r_ in o.execute(
        "SELECT w.name, count(*) FROM transactions t JOIN wallets w ON w.wallet_pk = t.wallet_fk GROUP BY w.name")}
    sums = {r_[0]: round(float(r_[1]), 2) for r_ in o.execute(
        "SELECT w.name, sum(t.amount) FROM transactions t JOIN wallets w ON w.wallet_pk = t.wallet_fk WHERE t.paid = 1 GROUP BY w.name")}
    ok = o.execute("PRAGMA integrity_check").fetchone()[0]
    o.close()
    return {"out": str(out), "integrity": ok, "matched": len(matched), "added": r["added"], "transfers": r["transfers"],
            "skipped": r["skipped"], "notesUpdated": r.get("notesUpdated", 0), "corrections": r.get("corrections", []),
            "removedCorrections": removed_corr, "removedExtra": removed_extra, "refiled": refiled,
            "addedCategories": r.get("addedCategories", []), "rowsBefore": before, "rowsAfter": after, "sums": sums,
            "targets": targets(conn, names), "coverage": start}
