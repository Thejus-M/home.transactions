"""Edits made in the widget after a row reached Cashew: name, note (own note, bill lines), category.

A memo keeps, per widget id, the values the widget had the last time the sync saw that row in Cashew. On a
sync, a value that differs from the memo was edited in the widget since then, so that field of the matching
Cashew row is updated. A row seen for the first time only fills the memo: Cashew's own detail is never
overwritten by an old widget value. Recurring rows (type 1, 2) are never updated, and nothing is deleted.
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path

from . import cashew

MEMO = Path(os.environ.get("TXDB_CASHEW_EDITS_MEMO") or
            (Path.home() / ".local" / "state" / "omarchy" / "transactions-cashew-edits.json"))
FIELDS = ("title", "notes", "category", "subcategory")


def load(path: Path = MEMO) -> dict:
    try:
        v = json.loads(path.read_text(encoding="utf-8"))
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def save(memo: dict, path: Path = MEMO) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".part")
    tmp.write_text(json.dumps(memo, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def _values(d: dict) -> dict:
    return {k: str(d.get(k) or "") for k in FIELDS}


def _q(v) -> str:
    return "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"


def plan(drafts: list[dict], conn: sqlite3.Connection, memo: dict, now: int | None = None) -> tuple[list[str], dict, list[str]]:
    """drafts: widget rows already marked by cashew_dedupe.mark against `conn` (the live Cashew data).
    Returns (statements, new memo, ids of the rows updated)."""
    now = int(now or time.time())
    memo = dict(memo)
    by_name: dict = {}
    for pk, name, main in conn.execute("SELECT category_pk, name, main_category_pk FROM categories"):
        by_name[(name, main or "")] = pk
    stmts, changed = [], []
    for d in drafts:
        pk = d.get("cashewPk")
        if not d.get("inCashew") or not pk:
            continue
        cur = _values(d)
        old = memo.get(d["id"])
        memo[d["id"]] = dict(cur, pk=pk, pending=bool(d.get("pending")))
        if old is None or {k: old.get(k, "") for k in FIELDS} == cur:
            continue                                   # first sight, or no edit since the last sync
        row = conn.execute("SELECT type FROM transactions WHERE transaction_pk = ?", (pk,)).fetchone()
        if row is None or row[0] in (1, 2):
            continue
        sets = []
        if cur["title"] != old.get("title") and cur["title"]:
            sets.append(f"name = {_q(cur['title'])}")
        if cur["notes"] != old.get("notes"):
            sets.append(f"note = {_q(cur['notes'])}")
        if (cur["category"], cur["subcategory"]) != (old.get("category"), old.get("subcategory")) \
                and cur["category"] and cur["category"] not in cashew.UNCATEGORIZED:
            main = by_name.get((cur["category"], ""))
            if main:
                sub = by_name.get((cur["subcategory"], main)) if cur["subcategory"] else None
                sets.append(f"category_fk = {_q(main)}")
                sets.append(f"sub_category_fk = {_q(sub)}")
        if sets:
            sets.append(f"date_time_modified = {now}")
            stmts.append(f"UPDATE transactions SET {', '.join(sets)} WHERE transaction_pk = {_q(pk)}")
            changed.append(d["id"])
    return stmts, memo, changed


def vanished(memo: dict, widget_ids: set) -> tuple[list[str], dict]:
    """Pending card rows sent to Cashew that are gone from the widget (they settled under another id, often at
    another amount): (statements that delete their Cashew rows with a delete log, the memo without them).
    The settled row is sent as a new row by the same sync."""
    import uuid
    now = int(time.time())
    stmts, keep = [], {}
    for i, v in memo.items():
        if i not in widget_ids and isinstance(v, dict) and v.get("pending") and v.get("pk"):
            stmts.append(f"INSERT INTO delete_logs (delete_log_pk, entry_pk, type, date_time_modified) "
                         f"VALUES ({_q(str(uuid.uuid4()))}, {_q(v['pk'])}, 4, {now})")
            stmts.append(f"DELETE FROM transactions WHERE transaction_pk = {_q(v['pk'])} AND (type IS NULL OR type NOT IN (1, 2))")
            continue
        keep[i] = v
    return stmts, keep
