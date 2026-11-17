"""The difference between two Cashew databases as SQL statements, to run on Cashew's live database.

cashew_file.build makes a whole new database (the live one + the new rows, notes, subcategories). Inside the
open Cashew page only the change is applied: statements(base, new) compares every table by its primary key
and gives an INSERT for each new row and an UPDATE (changed columns only) for each changed row. Rows are
never deleted, and recurring rows (transactions.type 1 or 2) are never updated.
"""
from __future__ import annotations

import sqlite3

SKIP_TABLES = {"sqlite_sequence", "android_metadata"}


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _lit(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, bytes):
        return "X'" + v.hex() + "'"
    return "'" + str(v).replace("'", "''") + "'"


def statements(base: sqlite3.Connection, new: sqlite3.Connection) -> list[str]:
    out: list[str] = []
    tables = [r[0] for r in new.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]
    base_tables = {r[0] for r in base.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    for t in tables:
        if t in SKIP_TABLES or t.startswith("sqlite_"):
            continue
        if t not in base_tables:
            raise ValueError(f"table {t} is new: the schema changed, nothing applied")
        info = list(new.execute(f"PRAGMA table_info({_q(t)})"))
        cols = [c[1] for c in info]
        pk = [c[1] for c in sorted(info, key=lambda c: c[5]) if c[5] > 0]
        if not pk:
            continue                                   # no key: cannot compare (Cashew's tables all have one)
        if [c[1] for c in base.execute(f"PRAGMA table_info({_q(t)})")] != cols:
            raise ValueError(f"the columns of {t} differ: nothing applied")
        sel = f"SELECT {', '.join(map(_q, cols))} FROM {_q(t)}"
        idx = [cols.index(k) for k in pk]
        old = {tuple(r[i] for i in idx): r for r in base.execute(sel)}
        for r in new.execute(sel):
            key = tuple(r[i] for i in idx)
            was = old.get(key)
            if was is None:
                out.append(f"INSERT INTO {_q(t)} ({', '.join(map(_q, cols))}) VALUES ({', '.join(map(_lit, r))})")
            elif was != r:
                if t == "transactions" and "type" in cols and was[cols.index("type")] in (1, 2):
                    continue                           # never touch a recurring row
                sets = [f"{_q(c)} = {_lit(v)}" for c, v, w in zip(cols, r, was) if v != w]
                where = " AND ".join(f"{_q(k)} = {_lit(v)}" for k, v in zip(pk, key))
                out.append(f"UPDATE {_q(t)} SET {', '.join(sets)} WHERE {where}")
    return out
