"""Command line for the widget (and for looking at the data by hand).

  txdb snapshot                          JSON for the widget
  txdb set-tracked <id> <0|1>
  txdb set-tracked-many <0|1> <id>...
  txdb rename <groupKey> [name]          no name = clear the rename
  txdb txn-category <txnId> <category> [<sub>] [--only-this]   teach a category (empty = clear)
  txdb account-name <account> [name]     account = id (BANK|type|last4) or last4
  txdb receipt-link <receiptId> <txnId>  file a bill against a transaction
  txdb heal-links                        re-point links whose transaction id changed
  txdb receipt-unlink <receiptId>        back to the top of the list
  txdb receipt-cash <receiptId>          paid in cash: park it, stop asking
  txdb receipt-ignore <receiptId>        not a bill, or a duplicate photo
  txdb receipt-review <receiptId> <0|1>  raise or clear "check this parse"
  txdb receipt-forget <receiptId>        drop the row
  txdb receipt-edit <receiptId> <field> [value]   empty value clears it
  txdb receipt-edit-item <receiptId> <lineNo> <field> [value]
  txdb receipt-add-item <receiptId> <desc> [qty] [unit] [rate] [amount] [gstRate]
  txdb receipt-delete-item <receiptId> <lineNo>
  txdb receipt-edit-tax <receiptId> <rate> <cgst|sgst|igst|cess|taxable> [value]
  txdb transfers-verify                  check every transaction for a transfer partner (runs after every fetch)
  txdb transfers-mark-seen               clear the "new" mark on newly matched transfers
  txdb transfer-split <txnId>...         say a detected transfer pair is NOT a transfer
  txdb transfer-restore <txnId>...       undo that
  txdb receipt-add-fee <receiptId> <label> <amount> [original] [waived 0|1]   platform / delivery / service fee
  txdb receipt-edit-fee <receiptId> <lineNo> <label|amount|original|waived> <value>
  txdb receipt-set-category <receiptId> <category> [sub]   the user's category for a bill (empty = remove it)
  txdb receipt-use-computed <receiptId>  replace the printed total by what the parts add up to (explicit override)
  txdb receipt-delete-fee <receiptId> <lineNo>
  txdb receipt-add-tax <receiptId> <slabRate> <cgst|sgst|igst|cess> <amount>
  txdb receipt-recalc <receiptId> [verify]  (verify also clears warnings) subtotal = sum of items, total = subtotal - discount + round off
  txdb receipt-remove <receiptId>        remove the bill altogether (row, photo files, database copy); never re-imported
  txdb receipt-image-export <receiptId> <file>   write the photo kept in the database to a file
  txdb account-close <accountId> [--reopen]  hide a closed account (keeps its history); --reopen shows it again
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
  txdb cashew-draft [--state PATH]       JSON: Cashew categories, account names, one editable draft per
                                         untracked settled transaction, and the saved state (read only)
  txdb cashew-links [FILE|-]             read {"drafts":[...],"maxChars":n,"base":"app"|"web"} from FILE or
                                         stdin, print {"links":[...],"transfers":[{url,pairId,title,date,amount,
                                         accountFrom,accountTo,ids}],"warnings":[...]}
  txdb cashew-links --untracked [--state PATH]   bulk links, then "# transfer pages" and one transfer link per
                                         line, on stdout; a summary on stderr (read only)
  txdb cashew-guess [FILE|-] [--model gemma4:e2b] [--workers 3] [--batch 8] [--url http://127.0.0.1:11434]
                    [--timeout 300]
                                         read {"rows":[{id,title,merchant,notes,amount,kind,bank,accountType}],
                                         "taught":{key:{category,subcategory}}} and ask the local Ollama model for a
                                         Cashew category per row; batches run in parallel; one NDJSON line per
                                         finished batch {"results":[{id,category,subcategory}],done,total}, then
                                         {"finished":true,...}; errors as {"error":"..."} (read only, no database)

Arguments come as separate argv entries (no shell), so names and ids need
no quoting."""
from __future__ import annotations

import json
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

from .db import DB_PATH, connect, now, write

# cashew, ingest, migrate, portfolio, queries, receipts are imported lazily,
# only inside the branch of main() (or _cashew()) that actually needs them —
# a cheap single-row write like set-tracked only needs .db, not every
# subcommand's module, so skipping the unused imports shaves the fixed
# interpreter/import tax off it.


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


def _cashew(cmd: str, args: list[str]) -> int:
    """The Cashew commands never write: the database is opened read only."""
    from . import cashew
    state_path = None
    if "--state" in args:
        i = args.index("--state")
        state_path = args[i + 1] if i + 1 < len(args) else None
        args = args[:i] + args[i + 2:]
    out = lambda obj: (json.dump(obj, sys.stdout, ensure_ascii=False, separators=(",", ":")), sys.stdout.write("\n"))
    if cmd == "cashew-links" and "--untracked" not in args:
        src = args[0] if args else "-"
        payload = json.loads(sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8"))
        out(cashew.build_links(payload.get("drafts") or [], int(payload.get("maxChars") or cashew.DEFAULT_MAX_CHARS),
                               payload.get("base") or "app"))
        return 0
    if not Path(DB_PATH).exists():
        print(f"No database at {DB_PATH}", file=sys.stderr)
        return 1
    conn = cashew.open_readonly(DB_PATH)
    state = cashew.load_state(state_path)
    items = cashew.drafts(conn, state)
    if cmd == "cashew-draft":
        out({"categories": cashew.load_categories(), "accountNames": cashew.account_names(state),
             "drafts": items, "state": state})
        return 0
    result = cashew.build_links(items, base=state.get("base") or "app")
    for link in result["links"]:
        print(link["url"])
    if result["transfers"]:
        print("# transfer pages (tap Save in Cashew for each):")
        for t in result["transfers"]:
            print(t["url"])
    need = sum(1 for d in items if d["category"] == cashew.UNCATEGORIZED[0])
    print(f"{len(items)} transactions in {len(result['links'])} links and {len(result['transfers'])} transfer pages; "
          f"{need} need a category", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "cashew-guess":
        from . import cashew_guess
        return cashew_guess.main(args)
    if cmd in ("cashew-draft", "cashew-links"):
        return _cashew(cmd, args)
    if cmd == "txn-category":
        # txdb txn-category <txnId> <category> [<sub>] [--only-this]; empty category clears
        from . import cashew
        only = "--only-this" in args
        rest = [a for a in args if a != "--only-this"] + ["", "", ""]
        conn = cashew.open_readonly(DB_PATH)
        try:
            cashew.set_category(conn, rest[0], rest[1], rest[2], only_this=only)
        except ValueError as e:
            print(f"txn-category: {e}", file=sys.stderr)
            return 2
        return 0
    conn = connect()
    if cmd == "snapshot":
        from . import queries
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
    elif cmd == "txn-note":
        from . import receipts
        receipts.set_txn_note(conn, args[0], " ".join(args[1:]))
    elif cmd == "note-bill":
        from . import receipts
        print(receipts.note_bill(conn, args[0], " ".join(args[1:]).replace("\\n", "\n")))
    elif cmd == "account-name":
        aid = _account(conn, args[0])
        name = " ".join(args[1:]).strip() or None
        with write(conn):
            conn.execute("UPDATE accounts SET display_name = ? WHERE id = ?", (name, aid))
    elif cmd == "account-close":
        ref = [a for a in args if a != "--reopen"]
        if len(ref) != 1 or not conn.execute("SELECT 1 FROM accounts WHERE id = ?", (ref[0],)).fetchone():
            print(f"Unknown account {ref[0] if ref else ''}", file=sys.stderr)
            return 2
        closed_at = None if "--reopen" in args else now()
        with write(conn):
            conn.execute("UPDATE accounts SET closed_at = ? WHERE id = ?", (closed_at, ref[0]))
        print(json.dumps({"id": ref[0], "closedAt": closed_at}))
    elif cmd.startswith("receipt-"):
        from . import receipts
        if cmd == "receipt-link":
            receipts.set_link(conn, args[0], transaction_id=args[1], state="linked",
                              matched_by="manual")
        elif cmd == "receipt-unlink":
            receipts.clear_link(conn, args[0])
        elif cmd in ("receipt-cash", "receipt-ignore"):
            receipts.set_link(conn, args[0], transaction_id=None,
                              state="cash" if cmd == "receipt-cash" else "ignored",
                              matched_by="manual")
        elif cmd == "receipt-review":
            receipts.set_review(conn, args[0], args[1] == "1")
        elif cmd == "receipt-forget":
            receipts.forget(conn, args[0])
        elif cmd == "receipt-edit":
            receipts.edit_field(conn, args[0], args[1], " ".join(args[2:]))
        elif cmd == "receipt-edit-item":
            receipts.edit_item_field(conn, args[0], args[1], args[2], " ".join(args[3:]))
        elif cmd == "receipt-add-item":
            receipts.add_item(conn, args[0], args[1], *(args[2:7] + [None] * (5 - len(args[2:7]))))
        elif cmd == "receipt-delete-item":
            receipts.delete_item(conn, args[0], args[1])
        elif cmd == "receipt-edit-tax":
            receipts.edit_tax_field(conn, args[0], args[1], args[2], " ".join(args[3:]))
        elif cmd == "receipt-add-fee":
            receipts.add_fee(conn, args[0], args[1], args[2], *(args[3:5]))
        elif cmd == "receipt-edit-fee":
            receipts.edit_fee(conn, args[0], args[1], args[2], " ".join(args[3:]))
        elif cmd == "receipt-delete-fee":
            receipts.delete_fee(conn, args[0], args[1])
        elif cmd == "receipt-add-tax":
            receipts.add_tax(conn, args[0], args[1], args[2], args[3])
        elif cmd == "receipt-set-category":
            receipts.set_category(conn, args[0], args[1] if len(args) > 1 else "", args[2] if len(args) > 2 else "")
        elif cmd == "receipt-use-computed":
            receipts.use_computed_total(conn, args[0])
        elif cmd == "receipt-recalc":
            receipts.recalc_totals(conn, args[0], clear_flags=len(args) > 1 and args[1] == "verify")
        elif cmd == "receipt-remove":
            for rel in receipts.remove_receipt(conn, args[0]):
                (DB_PATH.parent / rel).unlink(missing_ok=True)
        elif cmd == "receipt-image-export":
            ok = receipts.export_image(conn, args[0], args[1])
            print("written" if ok else "no saved copy of that photo")
            return 0 if ok else 1
        else:
            print(f"Unknown command {cmd!r}\n{__doc__}", file=sys.stderr)
            return 2
    elif cmd == "transfers-verify":
        from . import transfers
        json.dump(transfers.verify(conn), sys.stdout)
        sys.stdout.write("\n")
    elif cmd == "transfers-mark-seen":
        from . import transfers
        transfers.mark_seen(conn)
    elif cmd == "transfer-split":
        with write(conn):
            for tid in args:
                conn.execute("INSERT OR REPLACE INTO transfer_splits (txn_id, split_at) VALUES (?, ?)", (tid, now()))
    elif cmd == "transfer-restore":
        with write(conn):
            for tid in args:
                conn.execute("DELETE FROM transfer_splits WHERE txn_id = ?", (tid,))
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
        from . import migrate
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
        from . import portfolio, queries
        print("integrity:", conn.execute("PRAGMA integrity_check").fetchone()[0])
        print("schema:", conn.execute("PRAGMA user_version").fetchone()[0])
        problems = queries.reconcile(conn)
        print("balances:", "all add up" if not problems else queries.reconcile_summary(conn))
        holdings = portfolio.reconcile(conn)
        print("portfolio:", "all adds up" if not holdings else portfolio.reconcile_summary(conn))
        links = conn.execute("SELECT COUNT(*) FILTER (WHERE state = 'linked'), "
                             "COUNT(*) FILTER (WHERE state = 'linked' AND NOT EXISTS "
                             "(SELECT 1 FROM transactions t WHERE t.id = transaction_id)) FROM receipt_links").fetchone()
        unlinked = conn.execute("SELECT COUNT(*) FROM receipts r WHERE NOT EXISTS "
                                "(SELECT 1 FROM receipt_links l WHERE l.receipt_id = r.id)").fetchone()[0]
        print(f"receipt links: {links[0]} linked, {links[1]} orphaned, {unlinked} bills not filed")
        from . import cashew
        off = cashew.category_mismatches(conn)
        print("categories:", "every saved answer is in force" if not off else f"{len(off)} rows do not use the answer you saved")
        for m in off[:20]:
            print(f"  {m['date']} {m['merchant'][:36]}: saved {m['wanted'][0]} > {m['wanted'][1]}, shows {m['shows'][0]} > {m['shows'][1]}")
        counts = conn.execute("SELECT COUNT(*) FILTER (WHERE balance_paise IS NOT NULL), "
                              "COUNT(*) FILTER (WHERE balance_derived = 1) FROM transactions").fetchone()
        print(f"  {counts[0]} rows carry a balance, {counts[1]} of them worked out rather than read")
        for table in [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]:
            print(f"  {table}: {conn.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]}")
    elif cmd == "heal-links":
        from . import ingest
        print(json.dumps(ingest.heal_links(conn), indent=2))
    elif cmd == "derive-balances":
        from . import ingest
        print(f"filled {ingest.derive_balances(conn, args[0] if args else None)} balances")
    elif cmd == "reconcile":
        from . import queries
        print(json.dumps(queries.reconcile(conn, args[0] if args else None), indent=2))
    elif cmd == "portfolio-derive":
        from . import portfolio
        print(f"{portfolio.derive_activity(conn)} activity rows worked out from the snapshots")
    elif cmd == "portfolio-check":
        from . import portfolio
        print(json.dumps(portfolio.reconcile(conn), indent=2))
    elif cmd == "portfolio-ingest":
        from . import portfolio
        snap = json.loads(Path(args[0]).read_text(encoding="utf-8"))
        saved = portfolio.record_snapshot(conn, snap)
        print(f"{saved} holdings saved for {snap['as_of']}, "
              f"{portfolio.derive_activity(conn)} activity rows")
    else:
        print(f"Unknown command {cmd!r}\n{__doc__}", file=sys.stderr)
        return 2
    return 0
