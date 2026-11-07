"""Tests for the transactions database (stdlib unittest):
  python3 -m unittest discover -s tests"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, ingest, keys, queries, receipts  # noqa: E402

SBI_UPI = "UPI- TRANSFER TO 4897692162094 UPI/DR/125045259403/THEJUS M/HDFC/8921768575/NO RE"
AXIS_UPI = "UPI/P2A/125226240762/THEJUS M /HDFC/MF and F/"
HDFC_UPI = "UPI-GREESHA RAJ-GREESHARAJ01@OKICICI-SBIN0070025-627610349848-UPI"


def row(i, date, amount, merchant="SHOP", **extra):
    return {"id": f"t-{i}", "date": date, "merchant": merchant, "amount": amount, "currency": "INR",
            "rawStatementRowId": str(i), **extra}


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()


class SchemaTests(Base):
    def test_schema_created_once_and_private(self):
        self.assertEqual(self.conn.execute("PRAGMA user_version").fetchone()[0], len(db.MIGRATIONS))
        db.connect(self.path).close()  # reopening doesn't re-run migrations
        self.assertEqual(oct(os.stat(self.path).st_mode & 0o777), "0o600")

    def test_writes_update_change_marker(self):
        marker = self.path.parent / ".changed"
        ingest.ensure_account(self.conn, "SBI", "checking", "1111")
        first = marker.read_text()
        ingest.ensure_account(self.conn, "SBI", "checking", "1111")
        self.assertNotEqual(first, marker.read_text())


class KeyTests(unittest.TestCase):
    def test_sbi_axis_hdfc_keys(self):
        """Each bank writes the transfer its own way; all three give the
        same counterparty NAME, but each bank has its own rename key."""
        self.assertEqual(keys.describe("SBI", SBI_UPI), ("UPI|SBI|THEJUS M", "THEJUS M", ""))
        self.assertEqual(keys.describe("AXIS", AXIS_UPI), ("UPI|AXIS|THEJUS M", "THEJUS M", "MF and F"))
        self.assertEqual(keys.describe("HDFC", HDFC_UPI), ("UPI|HDFC|GREESHA RAJ", "GREESHA RAJ", ""))

    def test_one_key_per_person_per_bank_whatever_the_vpa(self):
        masked = "UPI-LAKSHMI MOHAN-**************2002@OKSBI-SBIN0070528-627610349848-NO REMARK"
        unmasked = "UPI-LAKSHMI MOHAN-LMLAKSHMIMOHAN2002@OKAXIS-SBIN0070528-182323626-FOR CC BILLS"
        axis = "UPI/P2A/174619831194/LAKSHMI MOHAN /NO REM/SBIN"
        # within HDFC the masked and unmasked VPA are still one group ...
        self.assertEqual({keys.group_key("HDFC", masked), keys.group_key("HDFC", unmasked)},
                         {"UPI|HDFC|LAKSHMI MOHAN"})
        # ... but the same person on another bank is a different group, so a
        # rename on one bank can never change the other.
        self.assertEqual(keys.group_key("AXIS", axis), "UPI|AXIS|LAKSHMI MOHAN")
        self.assertNotEqual(keys.group_key("HDFC", masked), keys.group_key("AXIS", axis))
        self.assertNotEqual(keys.group_key("SBI", SBI_UPI), keys.group_key("AXIS", AXIS_UPI))

    def test_renaming_on_one_bank_leaves_the_same_person_on_another_bank_alone(self):
        # The reported bug: a transfer between your own accounts shows once on
        # HDFC (debit) and once on SBI (credit); renaming one used to rename both.
        hdfc = "UPI-THEJUS M-THEJUS@OKSBI-SBIN0070528-627610349848-NO REMARK"
        self.assertEqual(keys.describe("SBI", SBI_UPI)[1], keys.describe("HDFC", hdfc)[1])
        with tempfile.TemporaryDirectory() as tmp:
            conn = db.connect(Path(tmp) / "t.db")
            h = ingest.ensure_account(conn, "HDFC", "checking", "7367")
            s = ingest.ensure_account(conn, "SBI", "checking", "1111")
            ingest.upsert_rows(conn, h, [row(1, "2026-10-01", -100.0, hdfc)])
            ingest.upsert_rows(conn, s, [row(2, "2026-10-01", 100.0, SBI_UPI)])
            hk = conn.execute("SELECT group_key FROM transactions WHERE id = 't-1'").fetchone()[0]
            sk = conn.execute("SELECT group_key FROM transactions WHERE id = 't-2'").fetchone()[0]
            self.assertNotEqual(hk, sk)
            with db.write(conn):
                conn.execute("INSERT INTO merchant_names (group_key, name, updated_at) VALUES (?,?,?)",
                             (hk, "Thejus (HDFC side)", db.now()))
            names = queries.snapshot(conn)["merchantNames"]
            self.assertEqual(names, {hk: "Thejus (HDFC side)"})       # the SBI row has no name of its own
            conn.close()

    def test_text_nothing_can_parse_still_stays_with_its_bank(self):
        """A bank charge or an ATM line has no counterparty to match on, so
        its text is its identity — and one bank's wording must not rename
        another's."""
        self.assertNotEqual(keys.group_key("HDFC", "BRN-SI-D113157025"), keys.group_key("AXIS", "BRN-SI-D113157025"))


class IngestTests(Base):
    def setUp(self):
        super().setUp()
        self.aid = ingest.ensure_account(self.conn, "SBI", "checking", "9373")

    def test_upsert_counts_new_and_keeps_tracked(self):
        self.assertEqual(ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -5.0)]), 1)
        self.conn.execute("INSERT INTO tracked VALUES ('t-1', 'x')")
        self.assertEqual(ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -5.0), row(2, "2026-10-02", 3.0)]), 1)
        snap = queries.snapshot(self.conn)
        self.assertEqual([t["id"] for t in snap["transactions"]], ["t-2", "t-1"])
        self.assertTrue(snap["transactions"][1]["tracked"])
        self.assertEqual(snap["transactions"][1]["amount"], -5.0)

    def test_raw_row_written_and_cascades(self):
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -8000.0, SBI_UPI,
                                                     raw={"date_text": "01/10/2026", "direction_icon": "up"})])
        self.assertEqual(self.conn.execute("SELECT direction_icon FROM sbi_transactions").fetchone()[0], "up")
        self.assertEqual(self.conn.execute("SELECT group_key FROM sbi_view").fetchone()[0], "UPI|SBI|THEJUS M")
        with db.write(self.conn):
            self.conn.execute("DELETE FROM transactions WHERE id = 't-1'")
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM sbi_transactions").fetchone()[0], 0)

    def test_replace_window_removes_only_inside_window(self):
        aid = ingest.ensure_account(self.conn, "AXIS", "checking", "2934")
        ingest.upsert_rows(self.conn, aid, [row(1, "2024-01-01", 1.0), row(2, "2026-05-01", 2.0), row(3, "2026-06-01", 3.0)])
        added = ingest.replace_window(self.conn, aid, [row(3, "2026-06-01", 3.0), row(4, "2026-07-01", 4.0)],
                                      "2025-10-01", "2026-10-01")
        self.assertEqual(added, 1)
        self.assertEqual(ingest.known_ids(self.conn, aid), {"t-1", "t-3", "t-4"})

    def test_unsettled_replaced_and_tracked_moves_when_settled(self):
        aid = ingest.ensure_account(self.conn, "HDFC", "credit", "0220")
        ingest.replace_unsettled(self.conn, aid, [row("u1", "2026-10-05", -99.0, "CAFE")])
        self.conn.execute("INSERT INTO tracked VALUES ('t-u1', 'x')")
        ingest.upsert_rows(self.conn, aid, [row("s1", "2026-10-05", -99.0, "CAFE")])
        ingest.replace_unsettled(self.conn, aid, [])
        self.assertEqual(ingest.known_ids(self.conn, aid), {"t-s1"})
        self.assertEqual([r[0] for r in self.conn.execute("SELECT transaction_id FROM tracked")], ["t-s1"])

    def test_balance_none_keeps_previous(self):
        ingest.set_balance(self.conn, self.aid, 100.5)
        ingest.set_balance(self.conn, self.aid, None)
        self.assertEqual(queries.snapshot(self.conn)["balances"][0]["balance"], 100.5)

    def test_card_cycle_raw_strings_and_numbers(self):
        aid = ingest.ensure_account(self.conn, "HDFC", "credit", "7462")
        ingest.set_card_cycle(self.conn, aid, {"name": "MILLENNIA", "total_outstanding": "- ₹956.62",
                                               "payment_status": "FULLY PAID"})
        self.assertEqual(self.conn.execute("SELECT total_outstanding_paise FROM card_cycles").fetchone()[0], -95662)
        self.assertEqual(queries.snapshot(self.conn)["cardOverviews"][0]["total_outstanding"], "- ₹956.62")

    def test_card_cycle_outstanding_summary_fields(self):
        """The Overview tab's second block: the bill already generated, the
        credits paid against it, next month's spend so far and the unsettled
        remainder. They add up to the total the first block shows."""
        aid = ingest.ensure_account(self.conn, "HDFC", "credit", "7462")
        ingest.set_card_cycle(self.conn, aid, {
            "name": "MILLENNIA", "total_outstanding": "\u20b9595.38", "upcoming_payment_due": "\u20b9595.00",
            "unbilled_amount": "\u20b90.00", "payment_status": "PARTIALLY PAID",
            "last_statement_amount": "\u20b94,374.00", "unbilled_credits": "- \u20b93,779.00",
            "unbilled_purchases": "\u20b90.00", "unsettled_amount": "\u20b90.38"})

        paise = self.conn.execute("SELECT last_statement_paise, unbilled_credits_paise, "
                                  "unbilled_purchases_paise, unsettled_paise, total_outstanding_paise "
                                  "FROM card_cycles").fetchone()
        # Credits stay negative, the way the page prints them: money paid in.
        self.assertEqual(tuple(paise), (437400, -377900, 0, 38, 59538))
        self.assertEqual(paise[0] + paise[1] + paise[2] + paise[3], paise[4])

        card = queries.snapshot(self.conn)["cardOverviews"][0]
        self.assertEqual(card["last_statement_amount"], "\u20b94,374.00")
        self.assertEqual(card["unbilled_credits"], "- \u20b93,779.00")
        self.assertEqual(card["unbilled_purchases"], "\u20b90.00")
        self.assertEqual(card["unsettled_amount"], "\u20b90.38")

    def test_card_cycle_without_outstanding_summary_leaves_the_new_fields_empty(self):
        """A card scraped before that block was read (or by another bank's
        fetcher later) must still save, with the new columns NULL and the
        snapshot keys empty strings."""
        aid = ingest.ensure_account(self.conn, "HDFC", "credit", "0220")
        ingest.set_card_cycle(self.conn, aid, {"name": "RUPAY BIZ UPI", "total_outstanding": "\u20b9100.00"})

        self.assertEqual(tuple(self.conn.execute(
            "SELECT last_statement_paise, unbilled_credits_paise, unbilled_purchases_paise, unsettled_paise "
            "FROM card_cycles").fetchone()), (None, None, None, None))
        card = queries.snapshot(self.conn)["cardOverviews"][0]
        self.assertEqual([card[f] for f in ("last_statement_amount", "unbilled_credits",
                                            "unbilled_purchases", "unsettled_amount")], ["", "", "", ""])

    def test_balance_reaches_the_snapshot(self):
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0, balance=900.0)])
        card = queries.snapshot(self.conn)["transactions"][0]
        self.assertEqual(card["balance"], 900.0)

    def test_reconcile_is_quiet_when_the_running_balances_add_up(self):
        rows = [row(1, "2026-10-01", -100.0, balance=900.0),
                row(2, "2026-10-02", -50.0, balance=850.0),
                row(3, "2026-10-03", 200.0, balance=1050.0)]
        ingest.upsert_rows(self.conn, self.aid, rows)
        ingest.set_balance(self.conn, self.aid, 1050.0)
        self.assertEqual(queries.reconcile(self.conn), [])
        self.assertEqual(queries.reconcile_summary(self.conn), "")

    def test_reconcile_catches_a_balance_that_does_not_follow_its_amount(self):
        """The scrape read an amount or a balance wrong: without this the
        widget would show the wrong running balance and never say so."""
        rows = [row(1, "2026-10-01", -100.0, balance=900.0),
                row(2, "2026-10-02", -50.0, balance=800.0)]  # should be 850
        ingest.upsert_rows(self.conn, self.aid, rows)
        problems = queries.reconcile(self.conn)
        self.assertEqual([p["kind"] for p in problems], ["step"])
        self.assertEqual(problems[0]["expected"], 850.0)
        self.assertEqual(problems[0]["found"], 800.0)
        self.assertEqual(problems[0]["off_by"], -50.0)
        self.assertIn("balance mismatch", queries.reconcile_summary(self.conn))

    def test_reconcile_catches_a_newest_row_that_disagrees_with_the_account(self):
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0, balance=900.0)])
        ingest.set_balance(self.conn, self.aid, 975.0)
        problems = queries.reconcile(self.conn)
        self.assertEqual([p["kind"] for p in problems], ["current"])
        self.assertEqual(problems[0]["off_by"], -75.0)

    def test_reconcile_skips_rows_without_a_balance_and_credit_cards(self):
        """Older rows were saved before the balance was scraped, and a credit
        card has no running balance at all — neither is a mismatch."""
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0),
                                                 row(2, "2026-10-02", -50.0, balance=850.0)])
        card_aid = ingest.ensure_account(self.conn, "HDFC", "credit", "7462")
        ingest.upsert_rows(self.conn, card_aid, [row(3, "2026-10-02", -700.0, balance=None)])
        self.assertEqual(queries.reconcile(self.conn), [])

    def test_derive_balances_walks_back_from_the_current_balance(self):
        """Rows scraped before the statement's balance was kept get one
        worked out instead: the newest ends at the account's balance, each
        earlier one at the next row's balance less the next row's amount."""
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0),
                                                 row(2, "2026-10-02", -50.0),
                                                 row(3, "2026-10-03", 200.0)])
        ingest.set_balance(self.conn, self.aid, 1050.0)

        self.assertEqual(ingest.derive_balances(self.conn), 3)
        got = self.conn.execute("SELECT balance_paise, balance_derived FROM transactions "
                                "ORDER BY date").fetchall()
        self.assertEqual([r[0] for r in got], [90000, 85000, 105000])
        self.assertEqual([r[1] for r in got], [1, 1, 1])
        # Arithmetic, so of course it reconciles — the real test comes when
        # a fetch reads the statement's own figures over the top.
        self.assertEqual(queries.reconcile(self.conn), [])

    def test_a_scraped_balance_replaces_a_derived_one(self):
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0)])
        ingest.set_balance(self.conn, self.aid, 900.0)
        ingest.derive_balances(self.conn)

        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0, balance=905.0)])
        self.assertEqual(self.conn.execute("SELECT balance_paise, balance_derived FROM transactions").fetchone()[:],
                         (90500, 0))

    def test_derive_leaves_scraped_balances_and_credit_cards_alone(self):
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0, balance=900.0),
                                                 row(2, "2026-10-02", -50.0)])
        ingest.set_balance(self.conn, self.aid, 850.0)
        card_aid = ingest.ensure_account(self.conn, "HDFC", "credit", "7462")
        ingest.upsert_rows(self.conn, card_aid, [row(3, "2026-10-02", -700.0)])

        self.assertEqual(ingest.derive_balances(self.conn), 1)   # only the row that had none
        self.assertIsNone(self.conn.execute("SELECT balance_paise FROM transactions WHERE id = 't-3'").fetchone()[0])
        self.assertEqual(self.conn.execute("SELECT balance_derived FROM transactions WHERE id = 't-1'").fetchone()[0], 0)

    def test_snapshot_says_whether_a_balance_was_derived(self):
        ingest.upsert_rows(self.conn, self.aid, [row(1, "2026-10-01", -100.0)])
        ingest.set_balance(self.conn, self.aid, 900.0)
        ingest.derive_balances(self.conn)
        card = queries.snapshot(self.conn)["transactions"][0]
        self.assertEqual((card["balance"], card["balanceDerived"]), (900.0, True))

    def test_fetch_runs(self):
        run = ingest.start_run(self.conn, "SBI")
        ingest.finish_run(self.conn, run, "done", "ok", 2, 10)
        self.assertEqual(self.conn.execute("SELECT outcome, added FROM fetch_runs").fetchone()[:], ("done", 2))


class MigrationTests(unittest.TestCase):
    """The database is live on this machine, so every migration has to land on
    an existing file rather than a fresh one."""

    def test_v3_adds_the_outstanding_summary_columns_to_a_v2_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.db"
            with unittest.mock.patch.object(db, "MIGRATIONS", db.MIGRATIONS[:2]):
                conn = db.connect(path)
                aid = ingest.ensure_account(conn, "HDFC", "credit", "7462")
                # The v2 writer knew nothing of the new columns, so this row
                # is written the way that version wrote it.
                with db.write(conn):
                    conn.execute("INSERT INTO hdfc_card_cycles_raw (account_id, name, total_outstanding, "
                                 "fetched_at) VALUES (?,?,?,?)", (aid, "MILLENNIA", "\u20b9595.38", db.now()))
                conn.close()

            conn = db.connect(path)  # reopening runs v3
            self.addCleanup(conn.close)
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], len(db.MIGRATIONS))
            row = conn.execute("SELECT total_outstanding, last_statement_amount FROM hdfc_card_cycles_raw").fetchone()
            self.assertEqual(tuple(row), ("\u20b9595.38", None))
            columns = {r[1] for r in conn.execute("PRAGMA table_info(card_cycles)")}
            self.assertLessEqual({"last_statement_paise", "unbilled_credits_paise",
                                  "unbilled_purchases_paise", "unsettled_paise"}, columns)


class RekeyMigrationTests(unittest.TestCase):
    def test_v5_merges_a_counterparty_and_carries_the_rename_over(self):
        """Before v5 the same person held one key per bank and per VPA, so a
        rename only ever covered one of them."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.db"
            masked = "UPI-LAKSHMI MOHAN-**********2002@OKSBI-SBIN0070528-627610349848-NO REMARK"
            axis_text = "UPI/P2A/174619831194/LAKSHMI MOHAN /NO REM/SBIN"

            with unittest.mock.patch.object(db, "MIGRATIONS", db.MIGRATIONS[:4]):
                conn = db.connect(path)
                hdfc = ingest.ensure_account(conn, "HDFC", "checking", "7367")
                axis = ingest.ensure_account(conn, "AXIS", "checking", "2934")
                # Written as a v4 database would have: the current writer
                # knows columns this schema does not have yet, and the keys
                # of the day were one per bank, with HDFC's left unparsed.
                old_hdfc = "HDFC|UPI-LAKSHMI MOHAN-**********2002@OKSBI-SBIN0070528"
                old_axis = "AXIS|UPI|LAKSHMI MOHAN|NO REM"
                with db.write(conn):
                    for tid, aid, date, amount, merchant, key, name in (
                            ("t-1", hdfc, "2026-10-01", -10000, masked, old_hdfc, None),
                            ("t-2", axis, "2026-10-02", -5000, axis_text, old_axis, "LAKSHMI MOHAN")):
                        conn.execute(
                            "INSERT INTO transactions (id, account_id, date, merchant, amount_paise, currency, "
                            "status, group_key, counterparty, seq, first_seen_at, last_seen_at) "
                            "VALUES (?,?,?,?,?,'INR','settled',?,?,0,?,?)",
                            (tid, aid, date, merchant, amount, key, name, db.now(), db.now()))
                    conn.execute("INSERT INTO merchant_names (group_key, name, updated_at) VALUES (?,?,?)",
                                 (old_axis, "Lakshmi", db.now()))
                conn.close()

            conn = db.connect(path)  # v5 runs here
            self.addCleanup(conn.close)
            # v5 merged the variants; v17 then split the key per bank again,
            # copying the saved name to both banks' keys.
            self.assertEqual({r[0] for r in conn.execute("SELECT group_key FROM transactions")},
                             {"UPI|HDFC|LAKSHMI MOHAN", "UPI|AXIS|LAKSHMI MOHAN"})
            self.assertEqual([r[0] for r in conn.execute("SELECT counterparty FROM transactions")],
                             ["LAKSHMI MOHAN", "LAKSHMI MOHAN"])
            # (this old-database path runs v5 with today's per-bank keys, so the
            # name saved under the Axis key stays on the Axis key only)
            self.assertEqual([tuple(r) for r in conn.execute("SELECT group_key, name FROM merchant_names")],
                             [("UPI|AXIS|LAKSHMI MOHAN", "Lakshmi")])


class SplitNamesByBankTests(unittest.TestCase):
    def test_v17_copies_a_shared_name_to_each_banks_own_key(self):
        """A database as it was at v16: one shared key "UPI|THEJUS M" across HDFC
        and SBI, with one saved name. After v17 each bank has its own key and
        both keep the name - which can then be changed separately."""
        hdfc_text = "UPI-THEJUS M-THEJUS@OKSBI-SBIN0070528-627610349848-NO REMARK"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "old.db"
            with unittest.mock.patch.object(db, "MIGRATIONS", db.MIGRATIONS[:16]):
                conn = db.connect(path)
                h = ingest.ensure_account(conn, "HDFC", "checking", "7367")
                s = ingest.ensure_account(conn, "SBI", "checking", "1111")
                with db.write(conn):
                    for tid, aid, merchant in (("t-1", h, hdfc_text), ("t-2", s, SBI_UPI)):
                        conn.execute(
                            "INSERT INTO transactions (id, account_id, date, merchant, amount_paise, currency, "
                            "status, group_key, counterparty, seq, first_seen_at, last_seen_at) "
                            "VALUES (?,?,?,?,?,'INR','settled','UPI|THEJUS M','THEJUS M',0,?,?)",
                            (tid, aid, "2026-10-01", merchant, -1000, db.now(), db.now()))
                    conn.execute("INSERT INTO merchant_names (group_key, name, updated_at) VALUES (?,?,?)",
                                 ("UPI|THEJUS M", "Thejus", db.now()))
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 16)
                conn.close()
            conn = db.connect(path)                                       # v17 runs here
            self.addCleanup(conn.close)
            keys_by_id = dict((r[0], r[1]) for r in conn.execute("SELECT id, group_key FROM transactions"))
            self.assertEqual(keys_by_id, {"t-1": "UPI|HDFC|THEJUS M", "t-2": "UPI|SBI|THEJUS M"})
            self.assertEqual({r[0]: r[1] for r in conn.execute("SELECT group_key, name FROM merchant_names")},
                             {"UPI|HDFC|THEJUS M": "Thejus", "UPI|SBI|THEJUS M": "Thejus"})
            # renaming the HDFC side now leaves the SBI side alone
            with db.write(conn):
                conn.execute("UPDATE merchant_names SET name = 'Thejus HDFC' WHERE group_key = 'UPI|HDFC|THEJUS M'")
            self.assertEqual(conn.execute("SELECT name FROM merchant_names WHERE group_key = 'UPI|SBI|THEJUS M'"
                                          ).fetchone()[0], "Thejus")


class CliTests(Base):
    def cli(self, *args):
        env = {**os.environ, "TXDB_DB": str(self.path)}
        return subprocess.run([sys.executable, str(ROOT / "bin/txdb"), *args], env=env,
                              capture_output=True, text=True, check=True).stdout

    def test_widget_commands_round_trip(self):
        aid = ingest.ensure_account(self.conn, "HDFC", "credit", "0220")
        ingest.upsert_rows(self.conn, aid, [row(1, "2026-10-01", -5.0, HDFC_UPI), row(2, "2026-10-02", -6.0)])
        self.cli("set-tracked-many", "1", "t-1", "t-2")
        self.cli("set-tracked", "t-2", "0")
        self.cli("rename", keys.group_key("HDFC", HDFC_UPI), "Greesha's  shop")
        self.cli("account-name", "0220", "Rupay card")
        self.cli("bill-paid", "0220", "1")
        self.cli("bill-notified", "HDFC|credit|0220", "2026-10-07")
        snap = json.loads(self.cli("snapshot"))
        self.assertEqual({t["id"]: t["tracked"] for t in snap["transactions"]}, {"t-1": True, "t-2": False})
        self.assertEqual(list(snap["merchantNames"].values()), ["Greesha's  shop"])
        self.assertEqual(snap["accountNames"], {"0220": "Rupay card"})
        self.assertEqual(snap["bills"], {"0220": {"markedPaid": True, "notifiedDate": "2026-10-07"}})
        self.cli("rename", keys.group_key("HDFC", HDFC_UPI))
        self.assertEqual(json.loads(self.cli("snapshot"))["merchantNames"], {})

    def test_concurrent_writers_queue(self):
        aid = ingest.ensure_account(self.conn, "SBI", "checking", "1")
        ingest.upsert_rows(self.conn, aid, [row(i, "2026-10-01", 1.0) for i in range(40)])
        env = {**os.environ, "TXDB_DB": str(self.path)}
        procs = [subprocess.Popen([sys.executable, str(ROOT / "bin/txdb"), "set-tracked", f"t-{i}", "1"], env=env)
                 for i in range(40)]
        self.assertTrue(all(p.wait() == 0 for p in procs))
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM tracked").fetchone()[0], 40)


if __name__ == "__main__":
    unittest.main()


class ReceiptTests(Base):
    """Photographed bills. The OCR pipeline lives in another project and is
    never a dependency here: what arrives is already a dict of figures."""

    PARSE = {
        "image_sha256": "a" * 64, "stored_path": "receipts/aa/aaa.jpg",
        "source_path": "/mnt/share/RUID1.jpg", "merchant": "KUNNIL MARGINFREE HYPERMARKET",
        "date": "2026-11-05", "total_paise": 45600, "subtotal_paise": 46082,
        "discount_paise": 461, "round_off_paise": -21, "payment_hint": "UPI",
        "confidence": 92, "needs_review": False, "warnings": [],
        "raw_text": "KUNNIL MARGINFREE\nTOBLERONE 240.16\nARUM CHEMBU 103.31",
        "items": [{"description": "TOBLERONE", "amount": 240.16, "qty": 1},
                  {"description": "ARUM CHEMBU", "amount": 103.31, "qty": 1.448}],
        "taxes": [{"rate": 5.0, "taxable": 340.47, "cgst": 8.52, "sgst": 8.52}],
    }

    def _account_and_txn(self, amount_paise=-45600, tracked=False):
        aid = ingest.ensure_account(self.conn, "HDFC", "checking", "7367")
        ingest.upsert_rows(self.conn, aid, [{
            "id": "hdfc-1", "date": "2026-11-05", "merchant": "Upi-kunnil Marginfree",
            "amount": amount_paise / 100, "currency": "INR"}])
        if tracked:
            with db.write(self.conn):
                self.conn.execute("INSERT INTO tracked (transaction_id, tracked_at) VALUES (?,?)",
                                  ("hdfc-1", db.now()))
        return "hdfc-1"

    def test_the_same_photo_is_one_receipt_however_often_it_is_read(self):
        first = receipts.save_parse(self.conn, self.PARSE)
        second = receipts.save_parse(self.conn, dict(self.PARSE, source_path="/elsewhere/copy.jpg"))
        self.assertEqual(first, second)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM receipts").fetchone()[0], 1)

    def test_a_re_parse_replaces_the_items_and_keeps_the_filing(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        txn = self._account_and_txn()
        receipts.set_link(self.conn, rid, transaction_id=txn)
        receipts.save_parse(self.conn, dict(self.PARSE, items=[{"description": "ONE", "amount": 1.0}]))
        self.assertEqual(self.conn.execute(
            "SELECT COUNT(*) FROM receipt_items WHERE receipt_id = ?", (rid,)).fetchone()[0], 1)
        link = self.conn.execute("SELECT transaction_id, state FROM receipt_links").fetchone()
        self.assertEqual(tuple(link), (txn, "linked"))

    def test_an_unfiled_receipt_comes_first_in_the_snapshot(self):
        receipts.save_parse(self.conn, self.PARSE)
        rid2 = receipts.save_parse(self.conn, dict(self.PARSE, image_sha256="b" * 64,
                                                   date="2026-11-09", stored_path="r/b.jpg"))
        receipts.set_link(self.conn, rid2, transaction_id=self._account_and_txn())
        states = [r["state"] for r in receipts.snapshot(self.conn)["receipts"]]
        self.assertEqual(states[0], "unmatched")

    def test_one_transaction_holds_one_receipt(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        other = receipts.save_parse(self.conn, dict(self.PARSE, image_sha256="c" * 64,
                                                    stored_path="r/c.jpg"))
        txn = self._account_and_txn()
        receipts.set_link(self.conn, rid, transaction_id=txn)
        with self.assertRaises(SystemExit):
            receipts.set_link(self.conn, other, transaction_id=txn)

    def test_a_cash_bill_can_be_parked_and_stops_asking(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.set_link(self.conn, rid, state="cash")
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["state"], "cash")
        self.assertIsNone(row["transactionId"])

    def test_parking_a_bill_against_a_transaction_is_refused(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        with self.assertRaises(SystemExit):
            receipts.set_link(self.conn, rid, transaction_id="hdfc-1", state="cash")

    def test_a_filing_survives_the_transaction_disappearing(self):
        # Re-fetching a statement can rewrite transaction ids, and the link
        # deliberately carries no foreign key, so this must not raise.
        rid = receipts.save_parse(self.conn, self.PARSE)
        txn = self._account_and_txn()
        receipts.set_link(self.conn, rid, transaction_id=txn)
        with db.write(self.conn):
            self.conn.execute("DELETE FROM transactions WHERE id = ?", (txn,))
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertTrue(row["linkMissing"])
        self.assertEqual(row["state"], "linked")

    def test_the_figures_come_back_as_money_and_quantities(self):
        receipts.save_parse(self.conn, self.PARSE)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["total"], 456.00)
        self.assertEqual(row["discount"], 4.61)
        self.assertEqual(row["roundOff"], -0.21)
        self.assertEqual(row["items"][1]["qty"], 1.448)
        self.assertEqual(row["taxes"][0]["cgst"], 8.52)
        self.assertEqual(row["rawText"], self.PARSE["raw_text"])

    def test_a_checkout_capture_is_still_a_bill(self):
        # Photographed before paying because the receipt afterwards drops the
        # item detail: recorded, not rejected.
        receipts.save_parse(self.conn, dict(self.PARSE, before_payment=True))
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertTrue(row["beforePayment"])
        self.assertEqual(row["state"], "unmatched")

    def test_unknown_receipts_are_refused_rather_than_silently_ignored(self):
        with self.assertRaises(SystemExit):
            receipts.clear_link(self.conn, "rcpt-nope")

    def test_a_hand_edited_field_round_trips_through_the_snapshot(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.edit_field(self.conn, rid, "merchant", "KUNNIL MARGINFREE (CORRECTED)")
        receipts.edit_field(self.conn, rid, "total", "500.00")
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["merchant"], "KUNNIL MARGINFREE (CORRECTED)")
        self.assertEqual(row["total"], 500.00)

    def test_a_blank_edit_clears_the_field(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.edit_field(self.conn, rid, "gstin", "")
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertIsNone(row["gstin"])

    def test_the_snapshot_says_when_a_receipt_was_linked(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        self.assertIsNone(receipts.snapshot(self.conn)["receipts"][0]["linkedAt"])
        receipts.set_link(self.conn, rid, transaction_id=self._account_and_txn())
        self.assertTrue(receipts.snapshot(self.conn)["receipts"][0]["linkedAt"])

    def test_photo_metadata_is_stored_with_the_receipt_and_comes_back(self):
        meta = {"taken": "2026-06-25 22:39:08", "camera": "Google Pixel 8", "width": 3000, "height": 4000}
        rid = receipts.save_parse(self.conn, dict(self.PARSE, image_meta=meta))
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["imageMeta"], meta)
        self.assertEqual(row["sourcePath"], self.PARSE["source_path"])
        self.assertTrue(row["importedAt"])
        # a re-read replaces it; a re-read with none leaves a bare dict
        receipts.save_parse(self.conn, dict(self.PARSE, image_meta=None))
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["imageMeta"], {})
        self.assertEqual(rid, receipts.snapshot(self.conn)["receipts"][0]["id"])

    def test_a_date_must_be_a_real_iso_date(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.edit_field(self.conn, rid, "date", "2026-06-25")
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["date"], "2026-06-25")
        for bad in ("25-06-2026", "2026-02-31", "tomorrow"):
            with self.assertRaises(SystemExit):
                receipts.edit_field(self.conn, rid, "date", bad)
        receipts.edit_field(self.conn, rid, "date", "")
        self.assertIsNone(receipts.snapshot(self.conn)["receipts"][0]["date"])

    def test_a_non_editable_field_is_refused(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        with self.assertRaises(SystemExit):
            receipts.edit_field(self.conn, rid, "stored_path", "/tmp/elsewhere.jpg")

    def test_a_non_numeric_money_field_is_refused(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        with self.assertRaises(SystemExit):
            receipts.edit_field(self.conn, rid, "total", "not a number")

    def test_a_hand_edited_item_round_trips_through_the_snapshot(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        line = receipts.snapshot(self.conn)["receipts"][0]["items"][0]["line"]
        receipts.edit_item_field(self.conn, rid, str(line), "description", "TOBLERONE (corrected)")
        receipts.edit_item_field(self.conn, rid, str(line), "amount", "250.00")
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["items"][0]["description"], "TOBLERONE (corrected)")
        self.assertEqual(row["items"][0]["amount"], 250.00)

    def test_a_non_editable_item_field_is_refused(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        line = receipts.snapshot(self.conn)["receipts"][0]["items"][0]["line"]
        with self.assertRaises(SystemExit):
            receipts.edit_item_field(self.conn, rid, str(line), "gst_rate_e2", "500")

    def test_editing_an_item_on_a_nonexistent_line_is_refused(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        with self.assertRaises(SystemExit):
            receipts.edit_item_field(self.conn, rid, "999", "amount", "1.00")

    def test_add_item_appends_with_the_next_line_number(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        line = receipts.add_item(self.conn, rid, "Fryums 80g", "1", "pc", "42.86", "45.00")
        items = receipts.snapshot(self.conn)["receipts"][0]["items"]
        self.assertEqual(line, 3)
        self.assertEqual(items[-1]["description"], "Fryums 80g")
        self.assertEqual(items[-1]["amount"], 45.0)
        self.assertEqual(items[-1]["unit"], "pc")

    def test_an_items_own_gst_rate_can_be_added_and_edited(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        line = receipts.add_item(self.conn, rid, "Rum", "2", "pc", "840", "1680", "251")
        items = receipts.snapshot(self.conn)["receipts"][0]["items"]
        self.assertEqual(items[-1]["gstRate"], 251.0)
        receipts.edit_item_field(self.conn, rid, str(line), "gst_rate", "18")
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["items"][-1]["gstRate"], 18.0)
        receipts.edit_item_field(self.conn, rid, str(line), "gst_rate", "")
        self.assertIsNone(receipts.snapshot(self.conn)["receipts"][0]["items"][-1]["gstRate"])
        with self.assertRaises(SystemExit):
            receipts.edit_item_field(self.conn, rid, str(line), "gst_rate", "lots")

    def test_add_item_works_out_a_blank_amount_from_qty_and_rate(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.add_item(self.conn, rid, "Rice", "5", "kg", "65", "")
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["items"][-1]["amount"], 325.0)

    def test_add_item_without_any_amount_is_refused(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        with self.assertRaises(SystemExit):
            receipts.add_item(self.conn, rid, "Mystery")
        with self.assertRaises(SystemExit):
            receipts.add_item(self.conn, rid, "Bad", "x", None, None, "1")

    def test_delete_item_removes_the_line_and_refuses_a_missing_one(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.delete_item(self.conn, rid, "1")
        self.assertEqual(len(receipts.snapshot(self.conn)["receipts"][0]["items"]), 1)
        with self.assertRaises(SystemExit):
            receipts.delete_item(self.conn, rid, "99")

    def test_edit_tax_field_corrects_one_slab_figure(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.edit_tax_field(self.conn, rid, "5", "cgst", "9.00")
        slab = receipts.snapshot(self.conn)["receipts"][0]["taxes"][0]
        self.assertEqual(slab["cgst"], 9.0)
        with self.assertRaises(SystemExit):
            receipts.edit_tax_field(self.conn, rid, "18", "cgst", "1")
        with self.assertRaises(SystemExit):
            receipts.edit_tax_field(self.conn, rid, "5", "rate", "1")

    def test_recalc_sets_subtotal_and_total_from_the_items(self):
        rid = receipts.save_parse(self.conn, dict(self.PARSE, discount_paise=461, round_off_paise=-21))
        receipts.add_item(self.conn, rid, "Fryums", "1", "pc", "42.86", "45.00")
        receipts.recalc_totals(self.conn, rid)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["subtotal"], 388.47)
        self.assertAlmostEqual(row["total"], 388.47 - 4.61 - 0.21, places=2)

    def test_recalc_verify_fills_a_missing_amount_and_clears_the_flags(self):
        rid = receipts.save_parse(self.conn, dict(self.PARSE, warnings=["items add up to 1, the bill says 2"],
                                                  needs_review=True))
        receipts.add_item(self.conn, rid, "Rice", "5", "kg", "65", "325")
        with db.write(self.conn):
            self.conn.execute("UPDATE receipt_items SET amount_paise = NULL WHERE description = 'Rice'")
        receipts.recalc_totals(self.conn, rid, clear_flags=True)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual([i["amount"] for i in row["items"] if i["description"] == "Rice"], [325.0])
        self.assertEqual(row["warnings"], [])
        self.assertFalse(row["needsReview"])

    def test_recalc_adds_tax_back_when_the_bill_printed_it_on_top(self):
        # Malabar Qissa: 772.80 - 0 + (-0.44) + 38.64 tax = 811.00
        rid = receipts.save_parse(self.conn, dict(
            self.PARSE, total_paise=81100, subtotal_paise=77280, discount_paise=None, round_off_paise=-44,
            items=[{"description": "A", "amount": 772.80}],
            taxes=[{"rate": 5.0, "cgst": 19.32, "sgst": 19.32}]))
        receipts.recalc_totals(self.conn, rid)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual((row["subtotal"], row["total"]), (772.8, 811.0))

    def test_add_tax_creates_a_slab_and_fills_a_missing_figure(self):
        rid = receipts.save_parse(self.conn, dict(self.PARSE, taxes=[]))
        receipts.add_tax(self.conn, rid, "5", "cgst", "19.32")
        receipts.add_tax(self.conn, rid, "5", "sgst", "19.32")
        slabs = receipts.snapshot(self.conn)["receipts"][0]["taxes"]
        self.assertEqual([(t["rate"], t["cgst"], t["sgst"]) for t in slabs], [(5.0, 19.32, 19.32)])
        receipts.add_tax(self.conn, rid, "5", "cgst", "20")
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["taxes"][0]["cgst"], 20.0)
        with self.assertRaises(SystemExit):
            receipts.add_tax(self.conn, rid, "5", "rate", "1")
        with self.assertRaises(SystemExit):
            receipts.add_tax(self.conn, rid, "5", "cgst", "")

    def test_recalc_understands_item_prices_that_already_include_gst(self):
        # Loaded Restaurant: item 250 (GST included), subtotal 238.10, GST 11.90, total 250.
        rid = receipts.save_parse(self.conn, dict(
            self.PARSE, total_paise=25000, subtotal_paise=23810, discount_paise=None, round_off_paise=None,
            items=[{"description": "Loaded Fries", "amount": 250.0}],
            taxes=[{"rate": 5.0, "cgst": 5.95, "sgst": 5.95}]))
        receipts.recalc_totals(self.conn, rid)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual((row["subtotal"], row["total"]), (238.1, 250.0))

    def test_fees_are_saved_edited_deleted_and_counted_by_recalc(self):
        # Flipkart: Selling Price 3795, Platform Fee 10, Total 3805.
        rid = receipts.save_parse(self.conn, dict(
            self.PARSE, total_paise=380500, subtotal_paise=379500, discount_paise=None, round_off_paise=None,
            items=[{"description": "Nike shoes", "amount": 3795.0}], taxes=[],
            fees=[{"label": "Platform Fee", "amount": 10.0}, {"label": "junk", "amount": 0}]))
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["fees"], [{"line": 1, "label": "Platform Fee", "amount": 10.0}])
        line = receipts.add_fee(self.conn, rid, "Delivery", "40")
        receipts.edit_fee(self.conn, rid, str(line), "amount", "45")
        receipts.edit_fee(self.conn, rid, "1", "label", "Platform fee (Flipkart)")
        receipts.recalc_totals(self.conn, rid)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual((row["subtotal"], row["total"]), (3795.0, 3850.0))          # 3795 + 10 + 45
        receipts.delete_fee(self.conn, rid, str(line))
        receipts.recalc_totals(self.conn, rid)
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["total"], 3805.0)
        with self.assertRaises(SystemExit):
            receipts.add_fee(self.conn, rid, "Free", "0")
        with self.assertRaises(SystemExit):
            receipts.delete_fee(self.conn, rid, "99")
        with self.assertRaises(SystemExit):
            receipts.edit_fee(self.conn, rid, "1", "rate", "1")

    def test_a_re_parse_replaces_the_fees(self):
        rid = receipts.save_parse(self.conn, dict(self.PARSE, fees=[{"label": "A", "amount": 5.0}]))
        receipts.save_parse(self.conn, dict(self.PARSE, fees=[]))
        self.assertEqual(receipts.snapshot(self.conn)["receipts"][0]["fees"], [])
        self.assertEqual(rid, receipts.snapshot(self.conn)["receipts"][0]["id"])

    def test_plain_recalc_keeps_the_parser_flags(self):
        rid = receipts.save_parse(self.conn, dict(self.PARSE, warnings=["x"], needs_review=True))
        receipts.recalc_totals(self.conn, rid)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual(row["warnings"], ["x"])
        self.assertTrue(row["needsReview"])

    def test_new_item_commands_round_trip_through_the_cli(self):
        env = {**os.environ, "TXDB_DB": str(self.path)}
        rid = receipts.save_parse(self.conn, self.PARSE)

        def run(*a):
            subprocess.run([sys.executable, str(ROOT / "bin/txdb"), *a], env=env, check=True)
        run("receipt-add-item", rid, "Fryums 80g", "1", "pc", "42.86", "45.00")
        run("receipt-edit-tax", rid, "5", "sgst", "9.5")
        run("receipt-delete-item", rid, "1")
        run("receipt-recalc", rid)
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertEqual([i["description"] for i in row["items"]], ["ARUM CHEMBU", "Fryums 80g"])
        self.assertEqual(row["taxes"][0]["sgst"], 9.5)
        self.assertEqual(row["subtotal"], 148.31)

    def test_a_photo_is_kept_in_the_database_and_can_be_written_back_out(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.save_image(self.conn, rid, b"jpegbytes", "image/jpeg", 800, 1200, original_bytes=9000)
        self.assertEqual(receipts.image_data(self.conn, rid), (b"jpegbytes", "image/jpeg"))
        saved = receipts.snapshot(self.conn)["receipts"][0]["imageSaved"]
        self.assertEqual((saved["bytes"], saved["originalBytes"], saved["width"]), (9, 9000, 800))
        out = Path(self.dir.name) / "back" / "x.jpg"
        self.assertTrue(receipts.export_image(self.conn, rid, out))
        self.assertEqual(out.read_bytes(), b"jpegbytes")
        receipts.save_image(self.conn, rid, b"smaller", "image/jpeg")        # a re-compress replaces it
        self.assertEqual(receipts.image_data(self.conn, rid)[0], b"smaller")

    def test_a_photo_removed_by_an_earlier_version_still_falls_back_to_the_thumbnail(self):
        rid = receipts.save_parse(self.conn, dict(self.PARSE, thumb_path="receipts/thumb/a.jpg"))
        with db.write(self.conn):
            self.conn.execute("UPDATE receipts SET image_deleted = 1 WHERE id = ?", (rid,))
        row = receipts.snapshot(self.conn)["receipts"][0]
        self.assertIsNone(row["storedPath"])
        self.assertEqual(row["thumbPath"], "receipts/thumb/a.jpg")
        self.assertTrue(row["imageDeleted"])

    def test_removing_a_bill_takes_everything_and_remembers_its_photo(self):
        full = self.path.parent / self.PARSE["stored_path"]
        thumb = self.path.parent / "receipts/thumb/a.jpg"
        for f in (full, thumb):
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(b"x")
        rid = receipts.save_parse(self.conn, dict(self.PARSE, thumb_path="receipts/thumb/a.jpg"))
        receipts.set_link(self.conn, rid, transaction_id=self._account_and_txn())
        receipts.save_image(self.conn, rid, b"jpeg")
        env = {**os.environ, "TXDB_DB": str(self.path)}
        subprocess.run([sys.executable, str(ROOT / "bin/txdb"), "receipt-remove", rid], env=env, check=True)
        self.assertFalse(full.exists() or thumb.exists())
        self.assertEqual(receipts.snapshot(self.conn)["receipts"], [])
        for table in ("receipt_items", "receipt_taxes", "receipt_links", "receipt_images"):
            self.assertEqual(self.conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], 0, table)
        self.assertEqual(receipts.removed_hashes(self.conn), {self.PARSE["image_sha256"]})
        # the transaction is free again
        other = receipts.save_parse(self.conn, dict(self.PARSE, image_sha256="e" * 64, stored_path="r/e.jpg"))
        receipts.set_link(self.conn, other, transaction_id="hdfc-1")
        with self.assertRaises(SystemExit):
            receipts.remove_receipt(self.conn, "rcpt-nope")

    def test_no_saved_copy_means_no_snapshot_entry_and_a_false_export(self):
        rid = receipts.save_parse(self.conn, self.PARSE)
        self.assertIsNone(receipts.snapshot(self.conn)["receipts"][0]["imageSaved"])
        self.assertFalse(receipts.export_image(self.conn, rid, Path(self.dir.name) / "n.jpg"))

    def test_only_linked_bills_without_a_saved_copy_are_waiting_for_compression(self):
        linked = receipts.save_parse(self.conn, self.PARSE)
        receipts.set_link(self.conn, linked, transaction_id=self._account_and_txn())
        receipts.save_parse(self.conn, dict(self.PARSE, image_sha256="d" * 64, stored_path="r/d.jpg"))
        self.assertEqual([r["id"] for r in receipts.linked_without_saved_image(self.conn)], [linked])
        receipts.save_image(self.conn, linked, b"x")
        self.assertEqual(receipts.linked_without_saved_image(self.conn), [])

    def test_a_photo_is_never_deleted_by_any_command(self):
        photo = self.path.parent / self.PARSE["stored_path"]
        photo.parent.mkdir(parents=True, exist_ok=True)
        photo.write_bytes(b"original")
        rid = receipts.save_parse(self.conn, self.PARSE)
        receipts.set_link(self.conn, rid, transaction_id=self._account_and_txn())
        with db.write(self.conn):
            self.conn.execute("UPDATE receipt_links SET linked_at = '2000-01-01T00:00:00'")
        env = {**os.environ, "TXDB_DB": str(self.path)}
        bad = subprocess.run([sys.executable, str(ROOT / "bin/txdb"), "receipt-sweep-images"],
                             env=env, capture_output=True, text=True)
        self.assertTrue(photo.exists())
        self.assertEqual(photo.read_bytes(), b"original")
        self.assertFalse(hasattr(receipts, "expired_images"))

    def test_v11_lands_on_an_older_database(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "old.db"
            with unittest.mock.patch.object(db, "MIGRATIONS", db.MIGRATIONS[:10]):
                conn = db.connect(path)
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 10)
                conn.close()
            conn = db.connect(path)
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], len(db.MIGRATIONS))
            self.assertTrue(conn.execute(
                "SELECT 1 FROM sqlite_master WHERE name = 'receipts_view'").fetchone())
            conn.close()
