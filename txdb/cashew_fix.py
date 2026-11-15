"""Rows a Cashew LINK cannot get right, added straight into a copy of Cashew's database instead.

The deployed Cashew (6.7.2, database version 48) ignores the sign of the amount in a link and takes income or
expense from the category's TYPE (tested on screen and in its database, 2026-11-15). That is wrong for
  - a refund: money IN, filed under its purchase's own expense category (Shopping), and
  - money you paid to a friend, filed under "Friend Settlements", which is an INCOME category in Cashew,
because the link would store the refund as spend and the payment as income. Cashew itself allows both (a row has its
own `income` flag; "Refund of Shoe" is +2,472, income, under Shopping), only a link cannot make them.

So these rows are written into a copy of the database with the right flag, and you import that file in Cashew
(Settings > import a backup). The base is the copy the browser keeps of the Cashew web app (cashew_twins.find_browser_copy),
or a backup file you export. A row whose day and amount are already in the database is never added twice.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import time
import uuid
from datetime import datetime
from pathlib import Path


def _alias_names(name: str) -> list[str]:
    """Names Cashew may know a widget category under: the same, case-folded, and with/without a trailing s
    ("Friend Settlement" is "Friend Settlements" in Cashew)."""
    n = (name or "").strip()
    return [n, n.lower(), n.rstrip("s"), n + "s", (n.rstrip("s") + "s").lower()]


class Index:
    """The categories and wallets of a Cashew database."""

    def __init__(self, conn: sqlite3.Connection):
        conn.row_factory = sqlite3.Row
        self.mains: dict[str, dict] = {}
        self.subs: dict[tuple[str, str], str] = {}
        rows = conn.execute("SELECT category_pk, name, income, main_category_pk FROM categories").fetchall()
        for r in rows:
            if not r["main_category_pk"]:
                self.mains.setdefault(r["name"], {"pk": r["category_pk"], "income": bool(r["income"])})
        by_pk = {m["pk"]: n for n, m in self.mains.items()}
        for r in rows:
            if r["main_category_pk"] in by_pk:
                self.subs[(r["main_category_pk"], r["name"])] = r["category_pk"]
        self.wallets = {r["name"]: r["wallet_pk"] for r in conn.execute("SELECT name, wallet_pk FROM wallets")}
        self._lower = {n.lower(): n for n in self.mains}

    def category(self, name: str, sub: str = "") -> tuple[str, str, bool] | None:
        """(category pk, sub-category pk or "", is income) for a widget category name, or None when unknown."""
        for cand in _alias_names(name):
            real = cand if cand in self.mains else self._lower.get(cand.lower())
            if real:
                m = self.mains[real]
                return m["pk"], self.subs.get((m["pk"], sub), "") if sub else "", m["income"]
        return None


def flag(drafts: list[dict], idx: Index) -> int:
    """Mark the drafts a link would get wrong (`viaFile`): a refund filed under its purchase's category, or a
    credit/debit whose sign disagrees with the type of its Cashew category. Returns how many were marked."""
    n = 0
    by_id = {d.get("id"): d for d in drafts}
    for d in list(drafts):
        # The purchase a file-added refund belongs to goes by file too, so the pair is added together and the
        # refund really cancels it (a purchase sent later by link is fine too, but one deleted by hand is not there).
        if d.get("viaFile") and d.get("kind") == "refund" and d.get("refundOf"):
            orig = by_id.get(d["refundOf"])
            if orig is not None and orig.get("include") is not False and not orig.get("viaFile"):
                orig["viaFile"], orig["fileReason"] = True, "the purchase of a refund added by file"
                n += 1
    for d in drafts:
        if d.get("kind") == "transfer" or d.get("include") is False:
            continue
        amount = float(d.get("amount") or 0)
        got = idx.category(d.get("category", ""), d.get("subcategory", ""))
        clash = bool(got) and got[2] != (amount > 0) and d.get("category") not in ("Uncategorized", "Balance Correction") \
            and not d.get("categoryPk")
        if d.get("viaFile"):
            n += 1                                       # already marked by txdb/cashew.py (a refund in its own category)
        elif clash:
            d["viaFile"] = True
            d["fileReason"] = "its sign disagrees with the Cashew category type"
            n += 1
    return n


def _day(iso: str) -> int:
    """Cashew keeps a day as the epoch second of local midnight."""
    return int(datetime.strptime(iso, "%Y-%m-%d").timestamp())


def plan(drafts: list[dict], idx: Index, conn: sqlite3.Connection) -> list[dict]:
    """[{draft, cat, sub, wallet, income, amount, day, duplicate, problem}] for every viaFile draft."""
    out = []
    # By calendar day, not by the exact second: a row added by hand in Cashew has a time of day, a link row has none.
    # The NAME is not compared: a payment typed in by hand carries the person's own title, not the bank's.
    seen = {(datetime.fromtimestamp(r[0]).strftime("%Y-%m-%d"), round(abs(r[1]), 2))
            for r in conn.execute("SELECT date_created, amount FROM transactions")}
    for d in drafts:
        if not d.get("viaFile") or d.get("include") is False:
            continue
        amount = round(float(d["amount"]), 2)
        got = idx.category(d.get("category", ""), d.get("subcategory", ""))
        wallet = idx.wallets.get(d.get("account", ""))
        day = _day(d["date"])
        problem = "" if got else f"Cashew has no category '{d.get('category')}'"
        problem = problem or ("" if wallet else f"Cashew has no account '{d.get('account')}'")
        out.append({"draft": d, "cat": got[0] if got else "", "sub": got[1] if got else "", "wallet": wallet or "",
                    "income": amount > 0, "amount": amount, "day": day, "problem": problem,
                    "duplicate": (d["date"], abs(amount)) in seen})
    return out


def apply(base: Path | str, out: Path | str, items: list[dict]) -> int:
    """Copy `base` to `out` and insert every item that has no problem and is not already there.
    Rows are cloned from an existing link-added row of the same database so every column has a valid value."""
    out = Path(out)
    shutil.copyfile(base, out)
    conn = sqlite3.connect(out)
    conn.row_factory = sqlite3.Row
    template = conn.execute("SELECT * FROM transactions WHERE method_added = 4 ORDER BY date_created DESC LIMIT 1").fetchone() \
        or conn.execute("SELECT * FROM transactions ORDER BY date_created DESC LIMIT 1").fetchone()
    if template is None:
        raise ValueError("the database has no transaction to copy the column layout from")
    cols = template.keys()
    added = 0
    now = int(time.time())
    for it in items:
        if it["problem"] or it["duplicate"]:
            continue
        row = {c: template[c] for c in cols}
        d = it["draft"]
        row.update(transaction_pk=str(uuid.uuid4()), paired_transaction_fk=None, name=d.get("title") or "", amount=it["amount"],
                   note=d.get("notes") or "", category_fk=it["cat"], sub_category_fk=it["sub"] or None, wallet_fk=it["wallet"],
                   date_created=it["day"], date_time_modified=now, income=1 if it["income"] else 0, paid=1)
        conn.execute(f"INSERT INTO transactions ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})", [row[c] for c in cols])
        added += 1
    conn.commit()
    if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        conn.close()
        out.unlink()
        raise ValueError("the new database failed its integrity check; nothing was written")
    conn.close()
    os.chmod(out, 0o600)
    return added
