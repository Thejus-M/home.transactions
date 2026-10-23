"""Command line for the widget (and for looking at the data by hand).

  txdb snapshot                          JSON for the widget
  txdb set-tracked <id> <0|1>
  txdb set-tracked-many <0|1> <id>...
  txdb rename <groupKey> [name]          no name = clear the rename
  txdb account-name <account> [name]     account = id (BANK|type|last4) or last4
  txdb bill-paid <account> <0|1>
  txdb bill-notified <account> <YYYY-MM-DD>
  txdb last-run <BANK>                   latest fetch run of a bank, as JSON
  txdb migrate-json                      import the old JSON files (safe to repeat)
  txdb export-json <dir>                 readable copy of everything
  txdb backup                            copy to data/backups/ (keeps 14)
  txdb check                             integrity check, row counts, balance check
  txdb reconcile [BANK]                  running balances vs amounts, as JSON
  txdb derive-balances [BANK]            fill missing running balances by arithmetic
  txdb portfolio-derive                  redo the buy/sell diff over the holding snapshots
  txdb portfolio-check                   units x price vs value, holdings vs the total
  txdb portfolio-ingest <file.json>      load a saved snapshot payload (offline / debug)

Arguments come as separate argv entries (no shell), so names and ids need
no quoting."""
from __future__ import annotations

import json
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

from . import ingest, migrate, portfolio, queries
from .db import DB_PATH, connect, now, write


def _account(conn, ref: str) -> str:
    if "|" in ref:
        if conn.execute("SELECT 1 FROM accounts WHERE id = ?", (ref,)).fetchone():
            return ref
        raise SystemExit(f"Unknown account {ref}")
    rows = conn.execute("SELECT id FROM accounts WHERE last4 = ?", (ref,)).fetchall()
    if len(rows) != 1:
        raise SystemExit(f"last4 {ref} matches {len(rows)} accounts; use the full account id")
    return rows[0][0]


def _set_tracked(conn, ids, on: bool) -> None:
    with write(conn):
        for tid in ids:
            if on:
                conn.execute("INSERT OR IGNORE INTO tracked (transaction_id, tracked_at) VALUES (?, ?)", (tid, now()))
            else:
                conn.execute("DELETE FROM tracked WHERE transaction_id = ?", (tid,))


def backup(conn, keep: int = 14) -> Path:
    folder = DB_PATH.parent / "backups"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"transactions-{datetime.now():%Y%m%d-%H%M%S}.db"
    dest = sqlite3.connect(target)
    with dest:
        conn.backup(dest)
    dest.close()
    target.chmod(0o600)
    for old in sorted(folder.glob("transactions-*.db"))[:-keep]:
        old.unlink()
    return target


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    conn = connect()
    if cmd == "snapshot":
        json.dump(queries.snapshot(conn), sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
    elif cmd == "set-tracked":
        _set_tracked(conn, [args[0]], args[1] == "1")
    elif cmd == "set-tracked-many":
        _set_tracked(conn, args[1:], args[0] == "1")
    elif cmd == "rename":
        name = " ".join(args[1:]).strip()
        with write(conn):
            if name:
                conn.execute("INSERT OR REPLACE INTO merchant_names (group_key, name, updated_at) VALUES (?,?,?)",
                             (args[0], name, now()))
            else:
                conn.execute("DELETE FROM merchant_names WHERE group_key = ?", (args[0],))
    elif cmd == "account-name":
        aid = _account(conn, args[0])
        name = " ".join(args[1:]).strip() or None
        with write(conn):
            conn.execute("UPDATE accounts SET display_name = ? WHERE id = ?", (name, aid))
    elif cmd in ("bill-paid", "bill-notified"):
        aid = _account(conn, args[0])
        column, value = ("marked_paid", 1 if args[1] == "1" else 0) if cmd == "bill-paid" else ("notified_date", args[1])
        with write(conn):
            conn.execute("INSERT OR IGNORE INTO bills (account_id) VALUES (?)", (aid,))
            conn.execute(f"UPDATE bills SET {column} = ? WHERE account_id = ?", (value, aid))
    elif cmd == "last-run":
        r = conn.execute("SELECT * FROM fetch_runs WHERE bank = ? ORDER BY id DESC LIMIT 1", (args[0].upper(),)).fetchone()
        print(json.dumps(dict(r) if r else {}, ensure_ascii=False))
    elif cmd == "migrate-json":
        print(json.dumps(migrate.run(conn), indent=2, ensure_ascii=False))
    elif cmd == "export-json":
        folder = Path(args[0])
        folder.mkdir(parents=True, exist_ok=True)
        for table in [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]:
            rows = [dict(r) for r in conn.execute(f"SELECT * FROM {table}")]
            (folder / f"{table}.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Exported to {folder}")
    elif cmd == "backup":
        print(backup(conn))
    elif cmd == "check":
        print("integrity:", conn.execute("PRAGMA integrity_check").fetchone()[0])
        print("schema:", conn.execute("PRAGMA user_version").fetchone()[0])
        problems = queries.reconcile(conn)
        print("balances:", "all add up" if not problems else queries.reconcile_summary(conn))
        holdings = portfolio.reconcile(conn)
        print("portfolio:", "all adds up" if not holdings else portfolio.reconcile_summary(conn))
        counts = conn.execute("SELECT COUNT(*) FILTER (WHERE balance_paise IS NOT NULL), "
                              "COUNT(*) FILTER (WHERE balance_derived = 1) FROM transactions").fetchone()
        print(f"  {counts[0]} rows carry a balance, {counts[1]} of them worked out rather than read")
        for table in [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]:
            print(f"  {table}: {conn.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]}")
    elif cmd == "derive-balances":
        print(f"filled {ingest.derive_balances(conn, args[0] if args else None)} balances")
    elif cmd == "reconcile":
        print(json.dumps(queries.reconcile(conn, args[0] if args else None), indent=2))
    elif cmd == "portfolio-derive":
        print(f"{portfolio.derive_activity(conn)} activity rows worked out from the snapshots")
    elif cmd == "portfolio-check":
        print(json.dumps(portfolio.reconcile(conn), indent=2))
    elif cmd == "portfolio-ingest":
        snap = json.loads(Path(args[0]).read_text(encoding="utf-8"))
        saved = portfolio.record_snapshot(conn, snap)
        print(f"{saved} holdings saved for {snap['as_of']}, "
              f"{portfolio.derive_activity(conn)} activity rows")
    else:
        print(f"Unknown command {cmd!r}\n{__doc__}", file=sys.stderr)
        return 2
    return 0
