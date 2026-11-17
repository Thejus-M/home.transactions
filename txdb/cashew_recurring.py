"""The recurring transactions set in Cashew (subscriptions and repeating rows), read only.

Cashew marks them with the column `type`: 1 = subscription, 2 = repeating. The interval is
period_length x reoccurrence (0 custom, 1 day, 2 week, 3 month, 4 year); every row carries those two columns,
so they alone do not mark a recurring row. The next occurrence of an active series is a row with paid = 0
and a date ahead; a series without such a row has ended.

status() matches each active series to the bank rows of the widget: same account, same amount, a date up to
DAY_TOLERANCE days from the due date (the bank date can be 2 to 4 days off).
"""
from __future__ import annotations

import sqlite3
from datetime import date, datetime, timedelta

from .cashew_dedupe import DAY_TOLERANCE

UNITS = {0: "custom", 1: "day", 2: "week", 3: "month", 4: "year"}
TYPES = {1: "subscription", 2: "repeating"}


def _day(ts) -> str:
    return datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d")


def series(conn: sqlite3.Connection, today: str | None = None) -> list[dict]:
    """[{title, amount, account, category, subcategory, every, unit, kind, paidCount, lastPaid, next, active}],
    the active ones first, then by next / last date."""
    today = today or date.today().isoformat()
    cats = {r[0]: r[1] for r in conn.execute("SELECT category_pk, name FROM categories")}
    wallets = {r[0]: r[1] for r in conn.execute("SELECT wallet_pk, name FROM wallets")}
    groups: dict = {}
    for name, amount, cat, sub, wallet, created, every, unit, paid, kind in conn.execute(
            "SELECT name, amount, category_fk, sub_category_fk, wallet_fk, date_created, period_length, reoccurrence, "
            "paid, type FROM transactions WHERE type IN (1, 2) ORDER BY date_created"):
        key = ((name or "").strip(), wallets.get(wallet, ""), kind)
        groups.setdefault(key, []).append((float(amount or 0), cat, sub, _day(created), every, unit, paid))
    out = []
    for (title, account, kind), rows in groups.items():
        paid = [r for r in rows if r[6] == 1]
        upcoming = [r for r in rows if r[6] == 0 and r[3] >= today]
        ref = upcoming[0] if upcoming else rows[-1]
        cat_name = "Balance Correction" if ref[1] == "0" else cats.get(ref[1], "")
        sub_name = cats.get(ref[2], "") if ref[2] else ""
        out.append({
            "title": " ".join(title.split()) or (cat_name + (" › " + sub_name if sub_name else "")),
            "amount": f"{ref[0]:.2f}", "account": account,
            "category": "Balance Correction" if ref[1] == "0" else cats.get(ref[1], ""),
            "subcategory": cats.get(ref[2], "") if ref[2] else "",
            "every": int(ref[4] or 1), "unit": UNITS.get(ref[5], "month"), "kind": TYPES.get(kind, ""),
            "paidCount": len(paid), "lastPaid": paid[-1][3] if paid else "",
            "next": upcoming[0][3] if upcoming else "", "active": bool(upcoming),
        })
    out.sort(key=lambda s: (not s["active"], s["next"] or "9999", s["lastPaid"]))
    return out


def status(items: list[dict], bank_rows: list[dict], today: str | None = None,
           tolerance: int = DAY_TOLERANCE) -> list[dict]:
    """Each active series with its state this cycle: paid (a bank row found, `paidOn`), due (`inDays`) or
    late (due + tolerance is past and no bank row). bank_rows: [{date, amount (rupees), account}].
    One bank row per series (the nearest)."""
    today_d = datetime.strptime(today or date.today().isoformat(), "%Y-%m-%d").date()
    used: set[int] = set()
    out = []
    for s in items:
        x = dict(s)
        if not s["active"]:
            x["state"] = "ended"
            out.append(x)
            continue
        due = datetime.strptime(s["next"], "%Y-%m-%d").date()
        # the cycle that matters now: the next date, or the paid one just before it (a bank row can come up to
        # `tolerance` days before Cashew's date, and Cashew moves `next` on once its row is paid)
        best = None
        for i, b in enumerate(bank_rows):
            if i in used or b.get("account") != s["account"] or round(float(b["amount"]) * 100) != round(float(s["amount"]) * 100):
                continue
            bd = datetime.strptime(b["date"], "%Y-%m-%d").date()
            gap = abs((bd - due).days)
            if gap <= tolerance and (best is None or gap < best[0]):
                best = (gap, i, b["date"])
        if best:
            used.add(best[1])
            x.update(state="paid", paidOn=best[2])
        elif (today_d - due).days > tolerance:
            x.update(state="late", lateDays=(today_d - due).days)
        else:
            x.update(state="due", inDays=(due - today_d).days)
        out.append(x)
    return out
