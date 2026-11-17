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
  txdb cashew-count                      how many transactions the Cashew web app has (the browser's copy)
  txdb cashew-wait <n> [--timeout S]     wait until Cashew has n more transactions (the widget's "Add all")
  (cashew-fix and cashew-twins are not needed any more: links carry categoryPolarity=false, the sign decides)
  txdb cashew-fix [--base FILE] [--out FILE] [--dry-run]  add the rows a Cashew link would get wrong (a refund in its
                                         purchase's category, a payment under an income category) to a COPY of the Cashew
                                         database with the right income flag; import the file in Cashew
  txdb cashew-twins [--backup FILE | --from-browser] [--test-link]  income twins of the expense categories, so a refund is income in
                                         "the same category": lists what the linked refunds need; --backup reads
                                         their ids from a Cashew backup export (or, with --from-browser, from the copy the browser
                                         keeps of the Cashew web app); --test-link prints a one-row test
  txdb receipt-purge-sources [--dry-run] [--hours N]  delete the original photos in the KDE share of bills linked
                                         3+ hours ago that have a compressed copy in the database
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
  txdb refund-link <refundId> <originalId|-> [note]   a credit refunds that purchase ("-" = purchase not in the data)
  txdb refund-unlink <refundId>...       remove the link; the credit is not auto-linked again
  txdb refund-not <refundId>...          this credit is not a refund (same as unlink)
  txdb refund-restore <refundId>...      let a credit be auto-linked again
  txdb refund-mode <refundId> <income|skip|lent>   how the Cashew export treats the pair
  txdb refund-expect <originalId> [amount] [note]  a return was started, the money is not back yet
  txdb refund-unexpect <originalId>      undo that
  txdb refund-verify                     link the credits that can be linked without asking (runs after every fetch)
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
                                         {"finished":true,...}; errors as {"error":"..."} (read only; looks up each row's UPI
                                         remark, note and linked bill in the database)

Arguments come as separate argv entries (no shell), so names and ids need
no quoting."""
from __future__ import annotations

import json
import os
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


def _mark_file_rows(items: list[dict]) -> dict:
    """With the copy of the Cashew web database the browser keeps: mark the drafts Cashew already has
    (txdb/cashew_dedupe.py: inCashew, not included, so "Add all" never sends a row twice), and let
    cashew_fix.flag complete the `viaFile` marks. Returns the dedupe result; {"ok": False, "reason": ...} when
    Cashew could not be read (the widget then warns: the rows cannot be checked for duplicates)."""
    try:
        from . import cashew_dedupe, cashew_fix, cashew_twins
        copy = cashew_twins.find_browser_copy()
        if copy is None:
            return {"ok": False, "reason": "the browser keeps no copy of the Cashew web app"}
        conn = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
        try:
            result = cashew_dedupe.mark(items, conn)
            cashew_fix.flag(items, cashew_fix.Index(conn))
        finally:
            conn.close()
        return result
    except Exception as e:               # noqa: BLE001 - a missing copy must never stop the drafts
        return {"ok": False, "reason": str(e)}


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
                               payload.get("base") or "app", payload.get("transfers") or "page"))
        return 0
    if not Path(DB_PATH).exists():
        print(f"No database at {DB_PATH}", file=sys.stderr)
        return 1
    conn = cashew.open_readonly(DB_PATH)
    state = cashew.load_state(state_path)
    items = cashew.drafts(conn, state)
    dedupe = _mark_file_rows(items)
    if cmd == "cashew-draft":
        out({"categories": cashew.load_categories(), "accountNames": cashew.account_names(state),
             "drafts": items, "state": state, "dedupe": dedupe})
        return 0
    # always real transfers: one transfer page per pair (a link cannot make two rows one linked transfer)
    result = cashew.build_links(items, base=state.get("base") or "app", transfers="page")
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


def _recurring() -> dict:
    """{series: [...], error} for the snapshot and the command. Never raises."""
    try:
        from . import cashew, cashew_recurring, cashew_twins
        base = cashew_twins.find_browser_copy()
        if base is None:
            return {"series": [], "error": "the browser keeps no copy of the Cashew web app"}
        cdb = sqlite3.connect(f"{base.as_uri()}?mode=ro", uri=True)
        items = cashew_recurring.series(cdb)
        cdb.close()
        state = cashew.load_state()
        over = state.get("accounts") or {}
        conn = cashew.open_readonly(DB_PATH)
        since = (datetime.now() - __import__("datetime").timedelta(days=60)).strftime("%Y-%m-%d")
        bank = [{"date": r[0], "amount": r[1] / 100, "account": over.get(r[2]) or cashew.ACCOUNT_MAP.get(r[2], "")}
                for r in conn.execute("SELECT date, amount_paise, account_id FROM transactions WHERE date >= ?", (since,))]
        # the last good fetch of each Cashew account's bank: a series is late only after fresh bank data
        last = {r[0]: r[1] for r in conn.execute(
            "SELECT bank, MAX(finished_at) FROM fetch_runs WHERE outcome = 'done' GROUP BY bank")}
        fetched: dict = {}
        for aid, bank_name in conn.execute("SELECT id, bank FROM accounts"):
            name = over.get(aid) or cashew.ACCOUNT_MAP.get(aid, "")
            if name and last.get(bank_name):
                fetched[name] = min(fetched.get(name, "9999"), str(last[bank_name]))
        return {"series": cashew_recurring.status(items, bank, fetched=fetched), "error": ""}
    except Exception as e:                      # noqa: BLE001 - the snapshot must never fail on this
        return {"series": [], "error": str(e)}


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
    if cmd == "cashew-chromium":
        # cashew-chromium status | pull | open: Cashew in its own Chromium profile (txdb/cashew_chromium.py).
        # The writes run in cashew-sync (option chromiumSync, or --chromium).
        from . import cashew_chromium
        sub = args[0] if args else "status"
        try:
            if sub == "pull":
                cashew_chromium.pull()
            elif sub == "open":
                cashew_chromium.open_window()
            elif sub != "status":
                print("usage: txdb cashew-chromium status | pull | open", file=sys.stderr)
                return 2
            print(json.dumps(cashew_chromium.status(), ensure_ascii=False))
            return 0
        except (ValueError, OSError, RuntimeError, TimeoutError) as e:
            print(json.dumps({"error": str(e)}))
            return 1
    if cmd == "cashew-recurring":
        # cashew-recurring: the recurring transactions set in Cashew and their state this cycle (paid / due /
        # late, matched to the bank rows within 7 days; late only after a fresh fetch). JSON. (txdb/cashew_recurring.py)
        print(json.dumps(_recurring(), ensure_ascii=False))
        return 0
    if cmd == "cashew-recat":
        # cashew-recat --plan | --apply CSV | --report: fix the categories of rows already in Cashew
        # (txdb/cashew_recat.py). --plan writes the review list (CSV + Markdown); --apply builds the import file
        # from the reviewed CSV and makes the automatic sync wait for its import; --report: money per category.
        from . import cashew_file, cashew_recat, cashew_twins
        base = cashew_twins.find_browser_copy()
        if base is None:
            print("cashew-recat: the browser keeps no copy of the Cashew web app", file=sys.stderr)
            return 3
        conn = sqlite3.connect(f"{base.as_uri()}?mode=ro", uri=True)
        if "--report" in args:
            for name, n, money in cashew_recat.report(conn):
                print(f"{name:<22} {n:>5} rows   ₹{money:>12,.2f} out")
            return 0
        if "--apply" in args:
            src = Path(args[args.index("--apply") + 1])
            folder = cashew_file.default_dir()
            folder.mkdir(parents=True, exist_ok=True)
            out = folder / f"cashew-recategorise-{datetime.now().strftime('%Y%m%d-%H%M%S')}.sql"
            r = cashew_recat.apply(base, src, out)
            mk = cashew_recat.marker_path()
            mk.parent.mkdir(parents=True, exist_ok=True)
            mk.write_text(json.dumps({"path": r["path"], "probe": r["probe"]}), encoding="utf-8")
            (folder / "cashew-sync.sql").unlink(missing_ok=True)   # an older sync file would undo the import
            print(json.dumps({k: v for k, v in r.items() if k != "probe"}, ensure_ascii=False))
            return 0
        notes = Path(os.environ.get("TXDB_NOTES_DIR") or "/run/media/pc/MY Drive/Docs/Notes")
        if not notes.is_dir():
            print(f"cashew-recat: {notes} is not there (is the drive mounted?)", file=sys.stderr)
            return 1
        moves = cashew_recat.plan(conn)
        stem = f"cashew-recategorise-{datetime.now():%Y-%m-%d}"
        cashew_recat.write_plan(moves, notes / (stem + ".csv"), notes / (stem + ".md"))
        groups: dict = {}
        for m in moves:
            k = "needs your answer" if m["confidence"] == "ask" else f"{m['from']} -> {m['to']}"
            g = groups.setdefault(k, [0, 0.0, 0])
            g[0] += 1
            g[1] += float(m["amount"])
            g[2] += m["confidence"] == "guess"
        for k, (n, money, guess) in sorted(groups.items(), key=lambda x: -x[1][0]):
            print(f"{n:>4}  {money:>12,.2f}  {k}" + (f"   ({guess} guesses)" if guess else ""))
        print(f"review: {notes / (stem + '.md')}\nedit:   {notes / (stem + '.csv')}", file=sys.stderr)
        return 0
    if cmd == "cashew-stamp":
        # cashew-stamp: one line that changes whenever Cashew's storage in Zen changes (the modification times
        # and sizes of the IndexedDB files). Cheap: the widget runs it every few seconds and runs cashew-sync
        # only when the line changes.
        from . import cashew_twins
        home = Path(os.environ.get("TXDB_BROWSER_HOME") or Path.home())
        parts = []
        for pattern in (".config/*/*/storage/default/https+++budget-track.web.app/idb/*",
                        ".mozilla/firefox/*/storage/default/https+++budget-track.web.app/idb/*"):
            for p in sorted(home.glob(pattern)):
                try:
                    st = p.stat()
                    parts.append(f"{p.name}:{st.st_mtime_ns}:{st.st_size}")
                except OSError:
                    continue
        print("|".join(parts))
        return 0
    if cmd == "cashew-sync":
        # cashew-sync [--dry-run]: the automatic sync. Every untracked row that is ready (ticked, a confirmed
        # category, not waiting for the AI) and not yet in Cashew goes into ONE file, cashew-sync.sql, made
        # again on every run (removed when nothing waits). The widget runs it after every change and shows
        # the result next to the Cashew chip; the person imports the file in Cashew. Prints JSON:
        # {pending, transfers, waitingCategory, inCashewIds, path, base, skipped}.
        from . import cashew, cashew_file, cashew_twins
        try:
            chromium = cashew.load_state().get("chromiumSync") is True or "--chromium" in args
            chromium_open = None
            if chromium:
                # Cashew in its own Chromium profile (txdb/cashew_chromium.py): refresh the copy when the
                # person used the window since the last read; never while the window is open
                from . import cashew_chromium
                chromium_open = cashew_chromium.in_use()
                if not chromium_open and cashew_chromium.stale():
                    cashew_chromium.pull()
            base = cashew_twins.find_browser_copy()
            if base is None:
                raise ValueError("the browser keeps no copy of the Cashew web app")
            # A recategorise file waits for its import: it replaces the whole database, so nothing may be built
            # on the old one meanwhile. The wait ends when Cashew holds the file's moves (or the file is gone).
            from . import cashew_recat
            mk = cashew_recat.marker_path()
            if mk.exists():
                try:
                    m = json.loads(mk.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    m = {}
                cdb = sqlite3.connect(f"{base.as_uri()}?mode=ro", uri=True)
                done = not m.get("path") or not Path(m["path"]).exists() or cashew_recat.imported(cdb, m.get("probe") or [])
                cdb.close()
                if done:
                    mk.unlink(missing_ok=True)
                else:
                    print(json.dumps({"pending": 0, "transfers": 0, "waitingCategory": 0, "inCashewIds": [], "path": "",
                                      "recatWaiting": m["path"], "autoTrack": False}))
                    return 0
            conn = cashew.open_readonly(DB_PATH)
            state = cashew.load_state()
            auto_track = state.get("autoTrack") is not False
            # the option "write straight into Cashew while Zen is closed" (off by default), or --direct
            direct = "--direct" in args or state.get("directSync") is True
            every = cashew.drafts(conn, state, all_rows=True)      # tracked rows too: for notes and the catch-up
            tracked_ids = {r[0] for r in conn.execute("SELECT transaction_id FROM tracked")}
            items = [d for d in every if d["id"] not in tracked_ids]
            # one-time catch-up: tracked rows that never reached Cashew (cashew-catchup; chosen 2026-11-17)
            catch_path = Path(os.environ.get("TXDB_CASHEW_CATCHUP") or
                              (Path.home() / ".local" / "state" / "omarchy" / "transactions-cashew-catchup.json"))
            try:
                catch_ids = set(json.loads(catch_path.read_text(encoding="utf-8")).get("ids") or [])
            except (OSError, ValueError):
                catch_ids = set()
            items += [dict(d, include=True) for d in every if d["id"] in catch_ids and d["id"] in tracked_ids]
            waiting = [d for d in items if d.get("include", True) and (d.get("askAi")
                       or (d.get("kind") != "transfer" and d.get("category") in (None, "", cashew.UNCATEGORIZED[0])
                           and d.get("subcategory") != "Miscellaneous") or d.get("warn"))]
            ready = [d for d in items if d.get("include", True) and d not in waiting]
            # the bank's last statement balance per savings account (worked-out balances are not used)
            over = state.get("accounts") or {}
            balances = []
            for aid, in conn.execute("SELECT id FROM accounts WHERE closed_at IS NULL AND account_type = 'checking'"):
                b = conn.execute("SELECT date, balance_paise FROM transactions WHERE account_id = ? AND balance_paise IS NOT NULL "
                                 "AND NOT balance_derived ORDER BY date DESC, seq DESC LIMIT 1", (aid,)).fetchone()
                name = over.get(aid) or cashew.ACCOUNT_MAP.get(aid, "")
                if b and name:
                    balances.append({"account": name, "date": b[0], "paise": int(b[1])})
            folder = cashew_file.default_dir()
            folder.mkdir(parents=True, exist_ok=True)
            out = folder / "cashew-sync.sql"
            if chromium and not chromium_open and "--dry-run" not in args:
                # write straight into the Chromium profile, then open the Cashew window so it syncs
                d = cashew_chromium.push(ready, note_drafts=every, open_after="--no-open" not in args)
                if out.exists() and d["written"]:
                    out.unlink()
                print(json.dumps({"chromium": True, "pending": 0, "rows": 0, "written": d["written"],
                                  "notes": d.get("notesUpdated", 0), "transfers": d["transfers"],
                                  "waitingCategory": len(waiting), "inCashewIds": [], "path": "",
                                  "backup": d["backup"], "base": d["base"], "skipped": d["skipped"],
                                  "opened": d["opened"], "autoTrack": auto_track}, ensure_ascii=False))
                return 0
            if direct:
                # EXPERIMENTAL (txdb/cashew_direct.py): straight into Zen's storage, only while Zen is closed.
                from . import cashew_direct
                spots = cashew_direct.storages()
                if len(spots) == 1 and not cashew_direct.in_use(spots[0]):
                    d = cashew_direct.apply(spots[0], ready, folder.parent / "cashew-direct", dry_run="--dry-run" in args)
                    if out.exists() and "--dry-run" not in args:
                        out.unlink()              # written straight in: no import file needed
                    print(json.dumps({"direct": True, "pending": d["would"] if "--dry-run" in args else 0,
                                      "written": d["written"], "transfers": d["transfers"],
                                      "waitingCategory": len(waiting), "inCashewIds": [], "path": "",
                                      "backup": d["backup"], "base": d["base"], "skipped": d["skipped"],
                                      "writtenIds": d["ids"] if d["written"] else [], "autoTrack": auto_track},
                                     ensure_ascii=False))
                    return 0
            # skip the rewrite when the ready rows and Cashew's size did not change since the last file
            memo_path = Path(os.environ.get("TXDB_CASHEW_SYNC_MEMO") or
                             (Path.home() / ".local" / "state" / "omarchy" / "transactions-cashew-sync.json"))
            import hashlib
            # rows waiting for a category, per account, that Cashew does not have yet (for the balance)
            from . import cashew_dedupe as _dd
            _cdb = sqlite3.connect(f"{base.as_uri()}?mode=ro", uri=True)
            _w = [dict(d, include=True) for d in waiting]
            _dd.mark(_w, _cdb)
            _cdb.close()
            for b in balances:
                mine = [d for d in _w if not d.get("inCashew") and d.get("account") == b["account"] and str(d.get("date")) <= b["date"]]
                b["waitingPaise"] = sum(round(float(d.get("amount") or 0) * 100) for d in mine)
                b["waitingRows"] = len(mine)
            BUILD_VERSION = 4                      # part of the memo key: a code change makes the file again
            key = [BUILD_VERSION, sorted(str(d.get("id")) + "|" + str(d.get("category")) + "|" + str(d.get("amount")) + "|"
                          + str(d.get("notes")) + "|" + str(d.get("title")) for d in ready),
                   hashlib.sha1("".join(sorted(str(d["id"]) + str(d.get("notes")) for d in every)).encode()).hexdigest(),
                   balances,
                   base.stat().st_size, sqlite3.connect(f"{base.as_uri()}?mode=ro", uri=True).execute(
                       "SELECT count(*), max(date_time_modified) FROM transactions").fetchone()]
            memo = {}
            try:
                memo = json.loads(memo_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                pass
            if "--dry-run" not in args and memo.get("key") == json.loads(json.dumps(key)) and \
                    (memo.get("result", {}).get("path") == "" or out.exists()):
                r = memo["result"]
            else:
                r = cashew_file.build(base, out, ready, dry_run="--dry-run" in args, note_drafts=every, balances=balances)
                if "--dry-run" not in args:
                    memo_path.parent.mkdir(parents=True, exist_ok=True)
                    memo_path.write_text(json.dumps({"key": key, "result": r}, ensure_ascii=False), encoding="utf-8")
            if r.get("changes", r["added"]) == 0 and out.exists() and "--dry-run" not in args:
                out.unlink()                      # nothing waits: no stale file to import by mistake
            # which untracked rows Cashew already has
            from . import cashew_dedupe
            cdb = sqlite3.connect(f"{base.as_uri()}?mode=ro", uri=True)
            probe = [dict(d) for d in items]
            cashew_dedupe.mark(probe, cdb)
            cdb.close()
            in_cashew = [d["id"] for d in probe if d.get("inCashew")]
        except (ValueError, OSError, sqlite3.Error) as e:
            print(json.dumps({"error": str(e)}))
            return 1
        print(json.dumps({"pending": r.get("changes", r["added"]), "rows": r["added"], "transfers": r["transfers"],
                          "notes": r.get("notesUpdated", 0), "corrections": r.get("corrections", []),
                          "waitingCategory": len(waiting), "inCashewIds": [i for i in in_cashew if i not in tracked_ids],
                          "path": r["path"], "base": r["base"], "skipped": r["skipped"],
                          "autoTrack": auto_track, "directOn": direct}, ensure_ascii=False))
        return 0
    if cmd == "cashew-file":
        # cashew-file [- | --all] [--dry-run] [--out FILE]: write the selected rows into a copy of the Cashew web
        # database for Cashew's own import (txdb/cashew_file.py). "-" reads {"drafts": [...]} from stdin (the
        # window's ticks); --all takes every untracked row. Prints JSON.
        from . import cashew, cashew_file, cashew_twins
        try:
            base = cashew_twins.find_browser_copy()
            if base is None:
                raise ValueError("the browser keeps no copy of the Cashew web app")
            if "-" in args:
                # one JSON line: the widget writes it and keeps the pipe open
                drafts = json.loads(sys.stdin.readline() or "{}").get("drafts") or []
            else:
                conn = cashew.open_readonly(DB_PATH)
                drafts = cashew.drafts(conn, cashew.load_state())
            if "--out" in args:
                out = Path(args[args.index("--out") + 1])
            else:
                folder = cashew_file.default_dir()
                folder.mkdir(parents=True, exist_ok=True)
                # .sql like Cashew's own export (Cashew's import warns on other names)
                out = folder / f"cashew-import-{datetime.now().strftime('%Y%m%d-%H%M%S')}.sql"
            result = cashew_file.build(base, out, drafts, dry_run="--dry-run" in args)
        except (ValueError, OSError, sqlite3.Error) as e:
            print(json.dumps({"error": str(e)}))
            return 1
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if cmd == "cashew-tabs":
        # cashew-tabs: the open Cashew web tabs in Zen's saved session (txdb/zen_tabs.py), as JSON.
        from . import zen_tabs
        print(json.dumps(zen_tabs.check(), ensure_ascii=False))
        return 0
    if cmd == "cashew-dupes":
        # cashew-dupes [--json]: rows Cashew holds more often than the bank has them (txdb/cashew_dupes.py)
        from . import cashew, cashew_dupes, cashew_twins
        copy = cashew_twins.find_browser_copy()
        if copy is None:
            print("cashew-dupes: the browser keeps no copy of the Cashew web app", file=sys.stderr)
            return 3
        cdb = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
        conn = cashew.open_readonly(DB_PATH)
        rows = cashew_dupes.report(cdb, conn, cashew.load_state())
        if "--json" in args:
            print(json.dumps(rows, ensure_ascii=False))
        else:
            for r in rows:
                print(f"{r['day']}  {r['amount']:>12}  {r['account']:<10}  in Cashew {r['inCashew']}, bank {r['inBank']}"
                      f"  -> delete {r['extra']}   {' | '.join(r['names'])[:70]}")
            print(f"{len(rows)} days/amounts, {sum(r['extra'] for r in rows)} rows to delete", file=sys.stderr)
        return 0
    if cmd == "cashew-count":
        # How many transactions the Cashew web app has (the copy the browser keeps). Exit 3 when there is none.
        from . import cashew_twins
        n = cashew_twins.browser_count()
        if n is None:
            print("cashew-count: the browser keeps no copy of the Cashew web app", file=sys.stderr)
            return 3
        print(n)
        return 0
    if cmd == "cashew-wait":
        # cashew-wait <expect> [--timeout S] [--poll S]: wait until Cashew has <expect> more transactions.
        # Prints {"ready":true,"base":n} (open the link now), then {"added":k,"of":n} per change.
        # Exit 0 all added, 2 timeout, 3 no browser copy. (txdb/cashew_twins.py wait_added)
        from . import cashew_twins
        try:
            expect = int(args[0])
            timeout = float(args[args.index("--timeout") + 1]) if "--timeout" in args else 60.0
            poll = float(args[args.index("--poll") + 1]) if "--poll" in args else 1.0
        except (IndexError, ValueError):
            print("usage: txdb cashew-wait <expect> [--timeout S] [--poll S]", file=sys.stderr)
            return 2
        return cashew_twins.wait_added(expect, timeout, poll, emit=lambda line: print(line, flush=True))
    if cmd == "cashew-fix":
        # cashew-fix [--base FILE] [--out FILE] [--dry-run]: add the rows a Cashew link would get wrong (a refund in
        # its purchase's category, a payment under an income category) to a copy of the Cashew database, with the
        # right income flag. Import the file in Cashew. The base is the browser's copy of the Cashew web app unless
        # --base names a backup file. (txdb/cashew_fix.py)
        from . import cashew, cashew_fix, cashew_twins
        try:
            base = Path(args[args.index("--base") + 1]) if "--base" in args else cashew_twins.find_browser_copy()
            if base is None:
                raise ValueError("no Cashew database found in the browser; export a backup and pass --base FILE")
            out_path = Path(args[args.index("--out") + 1]) if "--out" in args else Path.home() / "Downloads" / "cashew-import.sql"
            ro = cashew.open_readonly(DB_PATH)
            try:
                items = cashew.drafts(ro, cashew.load_state())
            finally:
                ro.close()
            cdb = sqlite3.connect(f"{Path(base).resolve().as_uri()}?mode=ro", uri=True)
            try:
                idx = cashew_fix.Index(cdb)
                cashew_fix.flag(items, idx)
                steps = cashew_fix.plan(items, idx, cdb)
            finally:
                cdb.close()
            todo = [x for x in steps if not x["problem"] and not x["duplicate"]]
            for x in steps:
                d = x["draft"]
                status = x["problem"] and f"SKIPPED: {x['problem']}" or (x["duplicate"] and "already in Cashew" or "will be added")
                print(f"  {d['date']} {d['amount']:>10}  {d['title'][:34]:34}  {d['category']} › {d.get('subcategory') or '-'}"
                      f"  [{'income' if x['income'] else 'expense'}]  {status}")
            if "--dry-run" in args or not todo:
                print(f"{len(todo)} rows to add" + ("" if todo else "; nothing to do") + " (dry run: no file written)" if "--dry-run" in args else f"{len(todo)} rows to add; nothing to do")
                return 0
            added = cashew_fix.apply(base, out_path, steps)
            print(f"{added} rows added. Import this file in Cashew: {out_path}")
        except (ValueError, IndexError, sqlite3.Error, OSError) as e:
            print(f"cashew-fix: {e}", file=sys.stderr)
            return 2
        return 0
    if cmd == "cashew-twins":
        # cashew-twins [--backup FILE] [--test-link]: income twins of the expense categories, for refunds
        # (txdb/cashew_twins.py). No arguments: which twins the linked refunds need, and which are known.
        from . import cashew, cashew_twins
        if "--backup" in args or "--from-browser" in args:
            try:
                if "--from-browser" in args:
                    copy = cashew_twins.find_browser_copy()
                    if copy is None:
                        raise ValueError("no Cashew database found in the browser's storage for budget-track.web.app")
                    found = cashew_twins.read_backup(copy)
                else:
                    found = cashew_twins.read_backup(args[args.index("--backup") + 1])
            except (ValueError, IndexError) as e:
                print(f"cashew-twins: {e}", file=sys.stderr)
                return 2
            where = cashew_twins.save(found)
            print(f"{len(found)} income categories read from the backup, saved to {where}")
        twins = cashew_twins.load()
        ro = cashew.open_readonly(DB_PATH)
        try:
            ds = cashew.drafts(ro, cashew.load_state(), all_rows=True, with_notes=False)
        finally:
            ro.close()
        need = {}
        for d in ds:
            if d.get("kind") == "refund" and d.get("refundCategory"):
                need[(d["refundCategory"], d.get("refundSubcategory") or "")] = None
        for (cat, sub) in sorted(need):
            got = cashew_twins.lookup(twins, cat, sub)
            label = f"{cat} › {sub}" if sub else cat
            state = ("ready" + ("" if (got and (got[1] or not sub)) else f" (the sub-category '{sub}' is missing in the twin)")) if got \
                else f"MISSING: create an INCOME category named '{cat}'" + (f" with a sub-category '{sub}'" if sub else "") + " in Cashew"
            print(f"  {label}: {state}")
        if not need:
            print("  no linked refund needs a twin yet")
        if "--test-link" in args:
            pick = next(((c, s_) for (c, s_) in sorted(need) if cashew_twins.lookup(twins, c, s_)), None)
            if not pick:
                print("cashew-twins: no twin is known yet; import a backup first (--backup FILE)", file=sys.stderr)
                return 2
            pk, sub_pk = cashew_twins.lookup(twins, *pick)
            entry = {"amount": "1.00", "title": f"TEST income twin of {pick[0]}", "date": datetime.now().strftime("%Y-%m-%d"),
                     "notes": "twin test, delete me", "categoryPk": pk, **({"subcategoryPk": sub_pk} if sub_pk else {}),
                     "fallbackCategory": cashew.FALLBACK_CATEGORY}
            url, _text = cashew._url([entry], cashew.WEB_BASE)
            print("Open this link; the row must show GREEN (income) under the twin, then delete it:")
            print(url)
        return 0
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
        # dumps, not dump: dump to a stream skips the C encoder and is about 3x slower.
        sys.stdout.write(json.dumps(queries.snapshot(conn), ensure_ascii=False, separators=(",", ":")))
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
        elif cmd == "receipt-purge-sources":
            # receipt-purge-sources [--dry-run] [--hours N]: delete the original photos in the KDE share
            # of bills linked N (default 3) hours ago whose compressed copy is in the database.
            hours = float(args[args.index("--hours") + 1]) if "--hours" in args else receipts.PURGE_AFTER_HOURS
            for item in receipts.purge_source_photos(conn, hours, dry_run="--dry-run" in args):
                print(f"{item['id']}: {item['action']}  {item['path']}")
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
    elif cmd.startswith("refund-"):
        from . import refunds
        try:
            if cmd == "refund-link":
                # refund-link <refundId> <originalId|-> [note...]  ("-" = the purchase is not in the data)
                original = None if args[1] in ("-", "") else args[1]
                refunds.set_link(conn, args[0], original, "manual", " ".join(args[2:]))
            elif cmd == "refund-unlink":
                for tid in args:
                    refunds.clear_link(conn, tid)
            elif cmd == "refund-not":
                for tid in args:
                    refunds.mark_not(conn, tid)
            elif cmd == "refund-restore":
                for tid in args:
                    refunds.restore(conn, tid)
            elif cmd == "refund-mode":
                refunds.set_mode(conn, args[0], args[1])
            elif cmd == "refund-expect":
                paise = round(float(args[1]) * 100) if len(args) > 1 and args[1] not in ("", "-") else None
                refunds.expect(conn, args[0], paise, " ".join(args[2:]))
            elif cmd == "refund-unexpect":
                refunds.unexpect(conn, args[0])
            elif cmd == "refund-verify":
                print(json.dumps(refunds.verify(conn)))
            else:
                print(f"Unknown command {cmd}", file=sys.stderr)
                return 2
        except (ValueError, IndexError) as e:
            print(f"{cmd}: {e}", file=sys.stderr)
            return 2
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
        from . import refunds as _refunds
        rl = conn.execute("SELECT COUNT(*) FROM refund_links").fetchone()[0]
        lost = _refunds.orphans(conn)
        print(f"refund links: {rl} linked, {len(lost)} orphaned")
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
    elif cmd == "heal-refunds":
        from . import refunds
        print(json.dumps(refunds.heal(conn), indent=2))
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
