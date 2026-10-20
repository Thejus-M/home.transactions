"""Tests for the transactions database (stdlib unittest):
  python3 -m unittest discover -s tests"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, ingest, keys, queries  # noqa: E402

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
        """Each bank writes the transfer its own way; all three come out as
        the same counterparty, so one rename covers every row."""
        self.assertEqual(keys.describe("SBI", SBI_UPI), ("UPI|THEJUS M", "THEJUS M", ""))
        self.assertEqual(keys.describe("AXIS", AXIS_UPI), ("UPI|THEJUS M", "THEJUS M", "MF and F"))
        self.assertEqual(keys.describe("HDFC", HDFC_UPI), ("UPI|GREESHA RAJ", "GREESHA RAJ", ""))

    def test_one_person_one_key_whatever_the_bank_or_the_vpa(self):
        masked = "UPI-LAKSHMI MOHAN-**************2002@OKSBI-SBIN0070528-627610349848-NO REMARK"
        unmasked = "UPI-LAKSHMI MOHAN-LMLAKSHMIMOHAN2002@OKAXIS-SBIN0070528-182323626-FOR CC BILLS"
        axis = "UPI/P2A/174619831194/LAKSHMI MOHAN /NO REM/SBIN"
        self.assertEqual({keys.group_key("HDFC", masked), keys.group_key("HDFC", unmasked),
                          keys.group_key("AXIS", axis)}, {"UPI|LAKSHMI MOHAN"})

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
        self.assertEqual(self.conn.execute("SELECT group_key FROM sbi_view").fetchone()[0], "UPI|THEJUS M")
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
            self.assertEqual({r[0] for r in conn.execute("SELECT group_key FROM transactions")},
                             {"UPI|LAKSHMI MOHAN"})
            self.assertEqual([r[0] for r in conn.execute("SELECT counterparty FROM transactions")],
                             ["LAKSHMI MOHAN", "LAKSHMI MOHAN"])
            # The rename now covers both rows instead of one.
            self.assertEqual(conn.execute("SELECT group_key, name FROM merchant_names").fetchall()[0][:],
                             ("UPI|LAKSHMI MOHAN", "Lakshmi"))


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
