"""The check that runs after every bank fetch: a transfer whose other half is
fetched LATER pairs itself, in either order, and the history of it is kept."""
import os
import random
import sys
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, ingest, queries, transfers  # noqa: E402

HDFC_OUT = "UPI-THEJUS M MANOJ-8921768575@UPI-UTIB0000802-161703292778-RD AND FD"
AXIS_IN = "UPI/P2A/161703292778/THEJUS M /HDFC/RD AND FD/"
# a pair that teaches the app "THEJUS M ..." is the user
TEACH_H = "UPI-THEJUS M MANOJ-8921768575@UPI-SBIN0001000-124028795174-FOR CC BILLS"
TEACH_S = "UPI- TRANSFER FROM 4897734162099 UPI/CR/124028795174/THEJUS M/SBIN/8921768575/NA"


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)
        self.hdfc = ingest.ensure_account(self.conn, "HDFC", "checking", "7367")
        self.axis = ingest.ensure_account(self.conn, "AXIS", "checking", "2934")
        self.sbi = ingest.ensure_account(self.conn, "SBI", "checking", "9373")

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def add(self, account, rid, date, merchant, amount):
        ingest.upsert_rows(self.conn, account, [{"id": rid, "date": date, "merchant": merchant,
                                                 "amount": amount, "currency": "INR"}])

    def teach(self):
        self.add(self.hdfc, "t-teach-h", "2026-09-30", TEACH_H, -20000.0)
        self.add(self.sbi, "t-teach-s", "2026-09-30", TEACH_S, 20000.0)

    def pairs(self):
        return sorted((p["outId"], p["inId"], p["matchedBy"]) for p in queries.snapshot(self.conn)["transfers"]
                      if p["outId"] not in ("t-teach-h",))

    def marker(self):
        return (self.path.parent / ".changed").read_text()


class AfterEveryFetch(Base):
    def test_the_other_half_arriving_later_pairs_in_either_order(self):
        # HDFC is fetched first, Axis later
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.assertEqual(transfers.verify(self.conn)["new"], 0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        self.assertEqual(transfers.verify(self.conn)["new"], 1)
        first = self.pairs()
        # now the reverse order in a fresh database
        self.conn.close()
        self.dir.cleanup()
        self.setUp()
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        self.assertEqual(transfers.verify(self.conn)["new"], 0)
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.assertEqual(transfers.verify(self.conn)["new"], 1)
        self.assertEqual(self.pairs(), first)
        self.assertEqual(first, [("h", "a", "ref")])

    def test_a_check_with_nothing_new_changes_nothing_and_does_not_wake_the_widget(self):
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        self.assertEqual(transfers.verify(self.conn)["new"], 1)
        marker = self.marker()
        again = transfers.verify(self.conn)
        self.assertEqual((again["new"], again["changed"], again["dissolved"]), (0, 0, 0))
        self.assertEqual(self.marker(), marker)                       # .changed untouched: no refresh loop
        queries.snapshot(self.conn)                                    # a snapshot never writes either
        self.assertEqual(self.marker(), marker)

    def test_a_half_with_no_partner_stays_one_sided_across_checks(self):
        self.teach()
        self.add(self.axis, "a-old", "2026-08-31", "UPI/P2A/121419291563/THEJUS M /HDFC/MF and R/", 14000.0)
        for _ in range(3):
            transfers.verify(self.conn)
        legs = {t["id"]: t for t in queries.snapshot(self.conn)["transactions"]}
        self.assertTrue(legs["a-old"]["transferSelf"])
        self.assertEqual(legs["a-old"]["transferOther"], "HDFC")

    def test_the_history_records_when_why_and_which_run_and_clears_when_seen(self):
        run = ingest.start_run(self.conn, "AXIS")
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        transfers.verify(self.conn, run)
        (p,) = [p for p in queries.snapshot(self.conn)["transfers"] if p["outId"] == "h"]
        self.assertEqual((p["matchedBy"], p["certainty"], p["isNew"], p["outBank"], p["inBank"]),
                         ("ref", 3, True, "HDFC", "AXIS"))
        self.assertTrue(p["matchedAt"])
        first_at = p["matchedAt"]
        self.assertEqual(self.conn.execute("SELECT first_run_id FROM transfer_matches").fetchone()[0], run)
        transfers.mark_seen(self.conn)
        (p,) = [p for p in queries.snapshot(self.conn)["transfers"] if p["outId"] == "h"]
        self.assertFalse(p["isNew"])
        self.assertEqual(p["matchedAt"], first_at)
        marker = self.marker()
        transfers.mark_seen(self.conn)                                # nothing to clear: no write
        self.assertEqual(self.marker(), marker)

    def test_a_pair_whose_row_is_replaced_dissolves_and_comes_back_with_its_first_date(self):
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        transfers.verify(self.conn)
        first_at = self.conn.execute("SELECT first_matched_at FROM transfer_matches").fetchone()[0]
        with db.write(self.conn):
            self.conn.execute("DELETE FROM transactions WHERE id = 'a'")       # a statement window replaced it
        self.assertEqual(transfers.verify(self.conn)["dissolved"], 1)
        self.assertEqual(self.conn.execute("SELECT status FROM transfer_matches").fetchone()[0], "dissolved")
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)                # fetched again
        again = transfers.verify(self.conn)
        self.assertEqual((again["new"], again["changed"]), (0, 1))
        row = self.conn.execute("SELECT status, first_matched_at FROM transfer_matches").fetchone()
        self.assertEqual((row[0], row[1]), ("active", first_at))

    def test_a_later_reference_match_supersedes_an_own_name_pair_and_is_recorded(self):
        self.teach()
        # first an own-name pair with different references ...
        self.add(self.hdfc, "h", "2026-10-30", "UPI-THEJUS M MANOJ-8921768575@UPI-UTIB0000802-111111111111-RD", -15000.0)
        self.add(self.axis, "a", "2026-10-30", "UPI/P2A/222222222222/THEJUS M /HDFC/rd/", 15000.0)
        transfers.verify(self.conn)
        self.assertEqual([r[0] for r in self.conn.execute(
            "SELECT rule FROM transfer_matches WHERE out_id = 'h'")], ["self"])
        # ... then the Axis row is corrected to carry the shared reference
        with db.write(self.conn):
            self.conn.execute("UPDATE transactions SET merchant = ? WHERE id = 'a'",
                              ("UPI/P2A/111111111111/THEJUS M /HDFC/rd/",))
        again = transfers.verify(self.conn)
        self.assertEqual(again["changed"], 1)
        self.assertEqual(self.conn.execute("SELECT rule, ref FROM transfer_matches WHERE out_id = 'h'").fetchone()[:],
                         ("ref", "111111111111"))
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM transfer_matches WHERE out_id = 'h'").fetchone()[0], 1)

    def test_a_split_pair_survives_a_re_fetch_and_is_never_recorded(self):
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        with db.write(self.conn):
            self.conn.execute("INSERT INTO transfer_splits (txn_id, split_at) VALUES ('h', ?)", (db.now(),))
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)                # the same row fetched again
        self.assertEqual(transfers.verify(self.conn)["new"], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM transfer_matches").fetchone()[0], 0)

    def test_two_possible_partners_are_not_guessed_between_and_stay_unrecorded(self):
        self.teach()
        self.add(self.hdfc, "h", "2026-10-30", "UPI-THEJUS M MANOJ-8921768575@UPI-UTIB0000802-111111111111-RD", -15000.0)
        self.add(self.axis, "a1", "2026-10-30", "UPI/P2A/222222222221/THEJUS M /HDFC/a/", 15000.0)
        self.add(self.axis, "a2", "2026-10-30", "UPI/P2A/222222222222/THEJUS M /HDFC/b/", 15000.0)
        transfers.verify(self.conn)
        # only the teaching pair is recorded; nothing is guessed for "h"
        self.assertEqual([r[0] for r in self.conn.execute("SELECT out_id FROM transfer_matches")], ["t-teach-h"])

    def test_lastfetched_and_the_reference_of_an_ordinary_row_reach_the_snapshot(self):
        run = ingest.start_run(self.conn, "AXIS")
        ingest.finish_run(self.conn, run, "done", "Axis: ok")
        self.add(self.axis, "x", "2026-10-30", "UPI/P2M/104266014334/ICCL GROW/HDFC BANK/Indian C//P2V/", -1000.0)
        snap = queries.snapshot(self.conn)
        self.assertIn("AXIS", snap["lastFetched"])
        self.assertEqual({t["id"]: t for t in snap["transactions"]}["x"]["reference"], "104266014334")


class FinishRun(Base):
    def test_every_fetch_end_runs_the_check_and_says_how_many_matched(self):
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        run = ingest.start_run(self.conn, "AXIS")
        ingest.finish_run(self.conn, run, "done", "Axis: 2 new")
        msg = self.conn.execute("SELECT message FROM fetch_runs WHERE id = ?", (run,)).fetchone()[0]
        self.assertIn("1 transfer newly matched", msg)
        run = ingest.start_run(self.conn, "HDFC")
        ingest.finish_run(self.conn, run, "done", "HDFC: 0 new")
        self.assertEqual(self.conn.execute("SELECT message FROM fetch_runs WHERE id = ?", (run,)).fetchone()[0],
                         "HDFC: 0 new")

    def test_a_failing_check_never_fails_the_fetch(self):
        run = ingest.start_run(self.conn, "AXIS")
        with unittest.mock.patch.object(transfers, "verify", side_effect=RuntimeError("boom")):
            ingest.finish_run(self.conn, run, "done", "Axis: ok")
        row = self.conn.execute("SELECT outcome, message FROM fetch_runs WHERE id = ?", (run,)).fetchone()
        self.assertEqual((row[0], row[1]), ("done", "Axis: ok"))

    def test_a_failed_fetch_still_checks_what_is_already_there(self):
        self.add(self.hdfc, "h", "2026-10-30", HDFC_OUT, -15000.0)
        self.add(self.axis, "a", "2026-10-30", AXIS_IN, 15000.0)
        run = ingest.start_run(self.conn, "AXIS")
        ingest.finish_run(self.conn, run, "error", "Axis: login failed")      # the fetch failed
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM transfer_matches").fetchone()[0], 1)


class Speed(Base):
    def test_a_few_thousand_rows_are_checked_in_about_a_second(self):
        rnd = random.Random(7)
        rows_h, rows_a = [], []
        for i in range(2500):
            amount = float(rnd.choice((100, 200, 500, 1000, 2000)))
            day = f"2026-{rnd.randint(1, 9):02d}-{rnd.randint(1, 28):02d}"
            rows_h.append({"id": f"h{i}", "date": day, "merchant": f"UPI-SHOP {i}-x@y-HDFC0001-{300000000000 + i}-N",
                           "amount": -amount, "currency": "INR"})
            rows_a.append({"id": f"a{i}", "date": day, "merchant": f"UPI/P2M/{400000000000 + i}/SHOP {i}/HDFC/x//",
                           "amount": amount, "currency": "INR"})
        ingest.upsert_rows(self.conn, self.hdfc, rows_h)
        ingest.upsert_rows(self.conn, self.axis, rows_a)
        started = time.monotonic()
        transfers.verify(self.conn)
        self.assertLess(time.monotonic() - started, 3.0)


if __name__ == "__main__":
    unittest.main()
