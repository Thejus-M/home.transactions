"""Fix the categories of rows already in Cashew: a review list first, then one import file.

Only the groups where the analysis of 2026-11-17 found wrong or too coarse categories are touched; every
other row keeps what the person chose:
  - Salary: money out (spends filed as income) and Salary > Bonus credits (small friend repayments)
  - EMI rows in Shopping / Uncategorized -> Loans & EMI; GST next to them -> Loans & EMI > Fees & GST
  - phones, laptops ... in Shopping -> Shopping > Electronics
  - Uncategorized: the person's own name -> Balance Correction (a move between own accounts), else the rules
  - Groceries > Provisions -> a grocery type when the title says it (milk, chicken, veggies ...)
  - Transport > Transit -> Cab & Auto / Bus/Metro/Train / Petrol / Parking
  - badminton / turf anywhere -> Fitness > Sports
Rows the rules cannot place are listed as "needs your answer" and not moved.

The plan is a CSV (apply = yes/no per row, the source of truth) and a Markdown copy to read. `apply` writes a
copy of the current Cashew database with the missing categories added and the rows moved (category_fk and
sub_category_fk only: amounts, dates, notes, the income flag stay), checks it, and leaves a marker so the
automatic sync waits until the file is imported (the import replaces the whole database).
"""
from __future__ import annotations

import csv
import json
import os
import re
import shutil
import sqlite3
import time
import uuid
from datetime import datetime
from pathlib import Path

from . import cashew

OWN_NAME = re.compile(r"\bthejus\s+m\.?\s+manoj\b", re.I)
SPORTS = re.compile(r"\b(badminton|batminton|turf|shuttle|playo)\b", re.I)
EMI_INTEREST = re.compile(r"\b(interest (for|on|of) (emi|1st month|the month)|emi interest|\d+(\.\d+)? interest of)", re.I)
EMI = re.compile(r"\b(emi|principal|principle for)\b", re.I)
GST = re.compile(r"^\s*(igst|cgst|sgst|gst)\b", re.I)
GADGET = re.compile(r"\b(phone|laptop|charger|earphones?|headphones?|ssd|pendrive)\b", re.I)
SUPERMARKET = re.compile(r"\b(grocery|groceries|provisions?|margin ?free|kunnil|lulu|ramachandran|smart ?point|qmart|"
                         r"flow ?mart|fiow mart|shopprix|reliance|malabar produce|supermart|supermarket|hypermarket|"
                         r"mini market|amazon pay in grocery|instamart|bigbasket|dmart)", re.I)
SETTLE = re.compile(r"\b(settle|settling|split|share|treat|owe|return(ed)?)\b", re.I)

# Cashew picture and colour for categories the widget adds (Cashew ships these PNGs).
NEW_MAIN_LOOK = {"Loans & EMI": ("loan.png", "0xff6a4c93"), "Bank & Card Fees": ("bank.png", "0xff7a3e48")}


def marker_path() -> Path:
    env = os.environ.get("TXDB_CASHEW_RECAT_MARKER")
    return Path(env) if env else Path.home() / ".local" / "state" / "omarchy" / "transactions-cashew-recat.json"


class Cats:
    """Categories of a Cashew database by pk and by name (mains) / (main pk, name) (subs)."""

    def __init__(self, conn: sqlite3.Connection):
        rows = conn.execute('SELECT category_pk, name, income, main_category_pk FROM categories').fetchall()
        self.name = {r[0]: r[1] for r in rows}
        self.main_of = {r[0]: r[3] for r in rows}
        self.income = {r[0]: bool(r[2]) for r in rows}
        self.mains = {}
        for pk, name, _inc, main in rows:
            if not main:
                self.mains.setdefault(name, pk)
        self.subs = {(r[3], r[1]): r[0] for r in rows if r[3]}

    def main_pk(self, name: str) -> str | None:
        for cand in (name, name.rstrip("s"), name + "s"):          # "Friend Settlement" is "Friend Settlements" in Cashew
            if cand in self.mains:
                return self.mains[cand]
        return None

    def main_name(self, name: str) -> str:
        pk = self.main_pk(name)
        return self.name[pk] if pk else name


def _rule(text: str, negative: bool, types: dict, rules: list) -> tuple[str, str] | None:
    cat, sub, warn = cashew.choose_category(text, "", "", negative, {"categories": {}}, rules, types)
    if warn or cat == cashew.UNCATEGORIZED[0]:
        return None
    return cat, sub


def classify(row: dict, types: dict, rules: list) -> tuple[str, str, str, str] | None:
    """(to category, to subcategory, reason, confidence 'rule'|'guess'|'ask') or None (leave it).
    'ask' = listed as needs your answer, with no target."""
    main, sub = row["main"], row["sub"]
    title = (row["name"] or "").strip()
    text = (title + " " + (row["note"] or "")).strip()
    amount = row["amount"]
    negative = amount < 0
    # money out only, and not friend money (the person keeps that in Friend Settlements)
    if SPORTS.search(text) and main not in ("Fitness", "Friend Settlements", "Friend Settlement") and negative:
        return "Fitness", "Sports", "badminton / turf in the title or note", "rule"
    if main in ("Shopping", "Uncategorized"):
        if EMI_INTEREST.search(title):
            return "Loans & EMI", "Interest", "EMI interest", "rule"
        if EMI.search(title):
            return "Loans & EMI", "Principal", "EMI payment", "rule"
        if main == "Shopping" and GST.search(title):
            return "Loans & EMI", "Fees & GST", "GST filed with the EMI rows", "rule"
        if main == "Shopping" and GADGET.search(title) and sub != "Electronics":
            return "Shopping", "Electronics", "a device", "rule"
        if main == "Shopping" and not title and sub == "Luxury":
            return None, None, "big Shopping > Luxury row without a title", "ask"
    if main == "Salary":
        if negative:
            hit = _rule(text, True, types, rules) if title else None
            if hit and hit[0] not in ("Salary",):
                return hit[0], hit[1], "money out filed as income; the title says " + hit[0], "rule"
            return "Friend Settlement", "Settle", "money out filed as income; most of these are settlements", "guess"
        if sub == "Bonus":
            if amount >= 5000:
                return None, None, "a large Bonus: a real bonus?", "ask"
            why = "a small credit filed as Bonus" + ("; the title names a person or a settlement" if title else "")
            return "Friend Settlement", "Received", why, "rule" if title and (SETTLE.search(title) or not re.search(r"\d", title)) else "guess"
    if main == "Uncategorized":
        if OWN_NAME.search(text):
            return "Balance Correction", "", "your own name: a move between your accounts", "rule"
        hit = _rule(text, negative, types, rules) if title else None
        if hit:
            return hit[0], hit[1], "the title says " + hit[0], "rule"
        return None, None, "no rule knows it", "ask"
    if main == "Groceries" and sub == "Provisions" and negative and title and not SUPERMARKET.search(title):
        # the title only: a supermarket's note lists the whole basket (milk among 20 items is not "dairy")
        hit = _rule(title, True, types, rules)
        if hit and hit[0] == "Groceries" and hit[1] not in ("Provisions", ""):
            return hit[0], hit[1], "the title names the item", "rule"
    if main == "Transport" and sub == "Transit" and negative:
        hit = _rule(text, True, types, rules)
        if hit and hit[0] == "Transport" and hit[1] not in ("Transit", ""):
            return hit[0], hit[1], "the title says " + hit[1], "rule"
    if main == "Balance Correction" and negative and not title and row.get("unlinked"):
        return None, None, "a Balance Correction without a title and without its other side", "ask"
    return None


def plan(conn: sqlite3.Connection) -> list[dict]:
    """Every move (and every 'needs your answer') for the rows of a Cashew database, by date."""
    cats = Cats(conn)
    wallets = {r[0]: r[1] for r in conn.execute("SELECT wallet_pk, name FROM wallets")}
    types = {c["name"]: c["type"] for c in cashew.load_categories()}
    rules = cashew.load_rules()
    paired_targets = {r[0] for r in conn.execute("SELECT paired_transaction_fk FROM transactions WHERE paired_transaction_fk IS NOT NULL")}
    out = []
    for pk, name, note, amount, cat_fk, sub_fk, wallet, created, paired in conn.execute(
            "SELECT transaction_pk, name, note, amount, category_fk, sub_category_fk, wallet_fk, date_created, "
            "paired_transaction_fk FROM transactions ORDER BY date_created"):
        row = {"pk": pk, "name": name or "", "note": note or "", "amount": float(amount or 0),
               "main": "Balance Correction" if cat_fk == "0" else cats.name.get(cat_fk, "?"),
               "sub": cats.name.get(sub_fk, "") if sub_fk else "",
               "unlinked": cat_fk == "0" and not paired and pk not in paired_targets}
        got = classify(row, types, rules)
        if not got:
            continue
        to_main, to_sub, why, conf = got
        out.append({"apply": "yes" if conf in ("rule", "guess") else "no", "pk": pk,
                    "date": datetime.fromtimestamp(int(created)).strftime("%Y-%m-%d"),
                    "account": wallets.get(wallet, ""), "amount": f"{row['amount']:.2f}", "title": row["name"][:80],
                    "from": row["main"] + (" > " + row["sub"] if row["sub"] else ""),
                    "to": "" if not to_main else (cats.main_name(to_main) + (" > " + to_sub if to_sub else "")),
                    "reason": why, "confidence": conf})
    return out


def write_plan(moves: list[dict], csv_path: Path, md_path: Path) -> None:
    cols = ["apply", "pk", "date", "account", "amount", "title", "from", "to", "reason", "confidence"]
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for m in moves:
            w.writerow(m)
    groups: dict[str, list[dict]] = {}
    for m in moves:
        key = "Needs your answer (not moved)" if m["confidence"] == "ask" else f"{m['from']}  →  {m['to']}"
        groups.setdefault(key, []).append(m)
    lines = [f"# Cashew: categories to fix ({datetime.now():%Y-%m-%d})", "",
             f"Edit the CSV, not this file: `{csv_path}`. Set `apply` to `no` for a row you want to keep as it is.",
             "Rows marked *guess* are likely but not certain: check them.", ""]
    for key in sorted(groups, key=lambda k: (k.startswith("Needs"), -len(groups[k]))):
        rows = groups[key]
        money = sum(float(r["amount"]) for r in rows)
        lines += [f"## {key}: {len(rows)} rows, ₹{money:,.2f}", "", "| date | account | amount | title | why |", "|---|---|---|---|---|"]
        for r in rows:
            title = r["title"].replace("|", "/") or "(no title)"
            lines.append(f"| {r['date']} | {r['account']} | {r['amount']} | {title} | {r['reason']}"
                         + (" (*guess*)" if r["confidence"] == "guess" else "") + " |")
        lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")


def _ensure(conn: sqlite3.Connection, cats: Cats, main: str, sub: str) -> tuple[str, str | None]:
    """(main pk, sub pk) for a target, adding the category or subcategory to Cashew when it is missing."""
    now = int(time.time())
    order = (conn.execute('SELECT max("order") FROM categories').fetchone()[0] or 0) + 1
    main_pk = cats.main_pk(main) if main != "Balance Correction" else "0"
    if main_pk is None:
        widget = {c["name"]: c for c in cashew.load_categories()}.get(main) or {}
        icon, colour = NEW_MAIN_LOOK.get(main, ("charts.png", "0xff607d8b"))
        main_pk = str(uuid.uuid4())
        conn.execute('INSERT INTO categories (category_pk, name, colour, icon_name, emoji_icon_name, date_created, '
                     'date_time_modified, "order", income, method_added, main_category_pk, archived) '
                     'VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, NULL, NULL, 0)',
                     (main_pk, main, colour, icon, now, now, order, 1 if widget.get("type") == "income" else 0))
        cats.mains[main], cats.name[main_pk], cats.main_of[main_pk] = main_pk, main, None
        order += 1
    if not sub:
        return main_pk, None
    sub_pk = cats.subs.get((main_pk, sub))
    if sub_pk is None:
        parent = conn.execute("SELECT colour, icon_name, income FROM categories WHERE category_pk = ?", (main_pk,)).fetchone()
        sub_pk = str(uuid.uuid4())
        conn.execute('INSERT INTO categories (category_pk, name, colour, icon_name, emoji_icon_name, date_created, '
                     'date_time_modified, "order", income, method_added, main_category_pk, archived) '
                     'VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, NULL, ?, 0)',
                     (sub_pk, sub, parent[0], parent[1], now, now, order, parent[2], main_pk))
        cats.subs[(main_pk, sub)] = sub_pk
        cats.name[sub_pk] = sub
    return main_pk, sub_pk


def apply(base: Path, csv_path: Path, out: Path) -> dict:
    """Copy `base` to `out` with the CSV's 'apply = yes' moves. A row whose category changed since the plan is
    skipped. Returns {path, moved, skipped, added_categories, probe}."""
    tmp = out.with_name(out.name + ".tmp")
    shutil.copyfile(base, tmp)
    with open(csv_path, newline="", encoding="utf-8") as fh:
        moves = [m for m in csv.DictReader(fh) if m.get("apply", "").strip().lower() in ("yes", "y", "1") and m.get("to")]
    try:
        conn = sqlite3.connect(tmp)
        cats = Cats(conn)
        before = {r[0] for r in conn.execute("SELECT category_pk FROM categories")}
        moved, skipped, probe = 0, [], []
        for m in moves:
            cur = conn.execute("SELECT category_fk, sub_category_fk FROM transactions WHERE transaction_pk = ?", (m["pk"],)).fetchone()
            if cur is None:
                skipped.append({"pk": m["pk"], "title": m["title"], "reason": "not in Cashew any more"})
                continue
            now_from = ("Balance Correction" if cur[0] == "0" else cats.name.get(cur[0], "?")) + (
                " > " + cats.name.get(cur[1], "") if cur[1] else "")
            if now_from != m["from"]:
                skipped.append({"pk": m["pk"], "title": m["title"], "reason": f"changed since the plan (now {now_from})"})
                continue
            main, _, sub = m["to"].partition(" > ")
            main_pk, sub_pk = _ensure(conn, cats, main, sub)
            conn.execute("UPDATE transactions SET category_fk = ?, sub_category_fk = ? WHERE transaction_pk = ?",
                         (main_pk, sub_pk, m["pk"]))
            moved += 1
            if len(probe) < 5:
                probe.append([m["pk"], main_pk, sub_pk])
        added = sorted(cats.name[pk] for pk in {r[0] for r in conn.execute("SELECT category_pk FROM categories")} - before)
        conn.commit()
        if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("the new database failed its integrity check; nothing was written")
        conn.close()
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    os.replace(tmp, out)
    os.chmod(out, 0o600)
    return {"path": str(out), "moved": moved, "skipped": skipped, "addedCategories": added, "probe": probe}


def imported(conn: sqlite3.Connection, probe: list) -> bool:
    """True when the Cashew database already holds the moves of a recategorise file (its probe rows)."""
    for pk, main_pk, sub_pk in probe:
        got = conn.execute("SELECT category_fk, sub_category_fk FROM transactions WHERE transaction_pk = ?", (pk,)).fetchone()
        if got and got[0] == main_pk and (got[1] or None) == (sub_pk or None):
            return True
    return False


def report(conn: sqlite3.Connection) -> list[tuple[str, int, float]]:
    """(category, rows, money out) per main category, biggest first; transfers left out."""
    cats = Cats(conn)
    acc: dict[str, list] = {}
    for cat_fk, amount in conn.execute("SELECT category_fk, amount FROM transactions"):
        if cat_fk == "0":
            continue
        name = cats.name.get(cat_fk, "?")
        a = acc.setdefault(name, [0, 0.0])
        a[0] += 1
        if (amount or 0) < 0:
            a[1] += -float(amount)
    return sorted(((k, v[0], v[1]) for k, v in acc.items()), key=lambda x: -x[2])
