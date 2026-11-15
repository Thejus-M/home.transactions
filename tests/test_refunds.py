"""Refund links (txdb/refunds.py): detection, the database, the snapshot, the CLI."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, ingest, queries, refunds  # noqa: E402


def r(i, date, paise, merchant, account="ICICI|credit|4002", kind="credit", bank="ICICI"):
    return {"id": i, "date": date, "merchant": merchant, "amount_paise": paise, "account_id": account,
            "account_type": kind, "bank": bank}


FLIP_OUT = r("o1", "2026-11-02", -381600, "FLIPKART INTERNET PVT L -BANGALORE")
FLIP_IN = r("c1", "2026-11-12", 381600, "FLIPKART INTERNET PVT L")


class Matching(unittest.TestCase):
    def test_the_city_a_bank_appends_and_legal_words_do_not_count(self):
        self.assertEqual(refunds.tokens("FLIPKART INTERNET PVT L -BANGALORE"), {"FLIPKART"})
        self.assertEqual(refunds.tokens("UPI- TRANSFER FROM 48977351620"), set())

    def test_a_flipkart_style_refund_matches_although_the_row_text_differs(self):
        m = refunds.match(FLIP_IN, FLIP_OUT)
        self.assertTrue(m["exact"] and m["full"] and m["sameAccount"])
        self.assertEqual(m["score"], 100)

    def test_an_amount_alone_is_never_evidence(self):
        other = r("c2", "2026-11-12", 381600, "SWIGGY")
        self.assertIsNone(refunds.match(other, FLIP_OUT))

    def test_a_refund_is_never_more_than_the_purchase_nor_before_it(self):
        self.assertIsNone(refunds.match(r("c", "2026-11-12", 400000, "FLIPKART"), FLIP_OUT))
        self.assertIsNone(refunds.match(r("c", "2026-11-01", 381600, "FLIPKART"), FLIP_OUT))
        self.assertIsNone(refunds.match(r("c", "2027-03-01", 381600, "FLIPKART"), FLIP_OUT))   # past the window

    def test_a_partial_refund_matches_but_scores_below_a_full_one(self):
        part = refunds.match(r("c", "2026-11-12", 100000, "FLIPKART INTERNET"), FLIP_OUT)
        self.assertFalse(part["exact"])
        self.assertLess(part["score"], refunds.match(FLIP_IN, FLIP_OUT)["score"])

    def test_the_same_upi_reference_is_certain_even_with_a_different_name(self):
        out = r("o", "2025-08-24", -100, "UPI- TRANSFER TO 4897690162095 UPI/DR/523638826363/Setu Bro/kkbk/x",
                account="SBI|checking|9373", kind="checking", bank="SBI")
        back = r("c", "2025-09-14", 100, "UPI- UPI/REVERSAL/523638826363/24082025/21028",
                 account="SBI|checking|9373", kind="checking", bank="SBI")
        m = refunds.match(back, out)
        self.assertTrue(m["ref"])
        self.assertGreaterEqual(m["score"], 100)


class Detecting(unittest.TestCase):
    def detect(self, rows, linked=(), refunded=None, nots=()):
        return refunds.detect(rows, set(linked), refunded or {}, set(nots))

    def test_a_card_refund_with_one_candidate_links_by_itself(self):
        out = self.detect([FLIP_OUT, FLIP_IN])
        self.assertEqual([(m["refundId"], m["originalId"], m["matchedBy"]) for m in out], [("c1", "o1", "auto")])

    def test_two_equal_purchases_are_a_suggestion_not_a_link(self):
        twin = dict(FLIP_OUT, id="o0", date="2026-11-03")
        self.assertEqual(self.detect([twin, FLIP_OUT, FLIP_IN]), [])

    def test_a_bank_account_credit_is_only_a_suggestion(self):
        out = r("o", "2026-11-02", -50000, "ZOMATO", account="HDFC|checking|7367", kind="checking", bank="HDFC")
        back = r("c", "2026-11-05", 50000, "ZOMATO", account="HDFC|checking|7367", kind="checking", bank="HDFC")
        self.assertEqual(self.detect([out, back]), [])
        self.assertEqual(refunds.candidates(back, [out])[0]["id"], "o")      # still offered in the picker

    def test_fee_credits_and_card_bill_payments_are_not_refunds(self):
        fee = r("c", "2026-11-05", 500, "Petro Surcharge Waiver")
        pay = r("p", "2026-11-05", 381600, "PAYMENT RECEIVED FLIPKART")
        self.assertEqual(self.detect([FLIP_OUT, fee, pay]), [])

    def test_a_credit_said_not_to_be_a_refund_is_left_alone(self):
        self.assertEqual(self.detect([FLIP_OUT, FLIP_IN], nots={"c1"}), [])

    def test_a_purchase_is_not_refunded_for_more_than_it_cost(self):
        second = r("c2", "2026-11-14", 381600, "FLIPKART INTERNET PVT L")
        out = self.detect([FLIP_OUT, FLIP_IN, second], linked={"c1"}, refunded={"o1": 381600})
        self.assertEqual(out, [])

    def test_a_row_inside_a_transfer_pair_is_never_a_refund(self):
        a = r("a", "2026-11-02", -100000, "UPI-ME-X-1-525555555555", account="HDFC|checking|7367", kind="checking", bank="HDFC")
        b = r("b", "2026-11-02", 100000, "UPI-ME-X-1-525555555555", account="SBI|checking|9373", kind="checking", bank="SBI")
        self.assertEqual(self.detect([a, b]), [])


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)
        self.card = ingest.ensure_account(self.conn, "ICICI", "credit", "4002")
        ingest.upsert_rows(self.conn, self.card, [
            {"id": "x1", "date": "2026-11-02", "merchant": "FLIPKART INTERNET PVT L -BANGALORE", "amount": -3816.0,
             "currency": "INR", "rawStatementRowId": "1"},
            {"id": "x2", "date": "2026-11-12", "merchant": "FLIPKART INTERNET PVT L", "amount": 3816.0,
             "currency": "INR", "rawStatementRowId": "2"},
            {"id": "x3", "date": "2026-11-13", "merchant": "SOMETHING ELSE", "amount": 100.0,
             "currency": "INR", "rawStatementRowId": "3"}])
        ids = [r[0] for r in self.conn.execute("SELECT id FROM transactions ORDER BY date")]
        self.out, self.back, self.other = ids

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def cli(self, *args):
        env = dict(os.environ, TXDB_DB=str(self.path))
        return subprocess.run([sys.executable, str(ROOT / "bin/txdb"), *args], env=env, capture_output=True, text=True)


class InTheDatabase(Base):
    def test_verify_links_the_card_refund_and_writes_nothing_the_second_time(self):
        self.assertEqual(refunds.verify(self.conn), {"new": 1})
        row = self.conn.execute("SELECT * FROM refund_links").fetchone()
        self.assertEqual((row["refund_id"], row["original_id"], row["matched_by"], row["cashew_mode"]),
                         (self.back, self.out, "auto", "skip"))     # new links net against the purchase
        self.assertEqual(refunds.verify(self.conn), {"new": 0})

    def test_a_manual_link_rejects_wrong_directions(self):
        with self.assertRaises(ValueError):
            refunds.set_link(self.conn, self.out, self.back)          # the purchase as the refund
        with self.assertRaises(ValueError):
            refunds.set_link(self.conn, self.back, self.other)        # a credit as the purchase
        with self.assertRaises(ValueError):
            refunds.set_link(self.conn, "nope", self.out)

    def test_unlinking_means_not_a_refund_until_restored(self):
        refunds.verify(self.conn)
        refunds.clear_link(self.conn, self.back)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM refund_links").fetchone()[0], 0)
        self.assertEqual(refunds.verify(self.conn), {"new": 0})
        refunds.restore(self.conn, self.back)
        self.assertEqual(refunds.verify(self.conn), {"new": 1})

    def test_a_refund_whose_purchase_is_not_in_the_data_keeps_a_note(self):
        refunds.set_link(self.conn, self.other, None, note="Razorpay order from September")
        row = self.conn.execute("SELECT * FROM refund_links").fetchone()
        self.assertIsNone(row["original_id"])
        self.assertEqual(row["original_note"], "Razorpay order from September")

    def test_the_mode_is_kept_when_the_link_is_made_again_and_rejects_nonsense(self):
        refunds.set_link(self.conn, self.back, self.out)
        refunds.set_mode(self.conn, self.back, "skip")
        refunds.set_link(self.conn, self.back, self.out)
        self.assertEqual(self.conn.execute("SELECT cashew_mode FROM refund_links").fetchone()[0], "skip")
        with self.assertRaises(ValueError):
            refunds.set_mode(self.conn, self.back, "banana")
        with self.assertRaises(ValueError):
            refunds.set_mode(self.conn, self.other, "lent")           # no link there

    def test_a_return_that_has_not_arrived_is_cleared_when_the_credit_is_linked(self):
        refunds.expect(self.conn, self.out, 381600, "returned the shoes")
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM refund_expect").fetchone()[0], 1)
        refunds.set_link(self.conn, self.back, self.out)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM refund_expect").fetchone()[0], 0)
        with self.assertRaises(ValueError):
            refunds.expect(self.conn, self.back)                        # only a purchase can wait

    def test_heal_follows_a_row_whose_id_changed(self):
        refunds.set_link(self.conn, self.back, self.out)
        self.conn.execute("UPDATE transactions SET id = 'new-id' WHERE id = ?", (self.back,))
        self.conn.commit()
        self.assertEqual(len(refunds.orphans(self.conn)), 1)
        result = refunds.heal(self.conn)
        self.assertEqual([(h["side"], h["to"]) for h in result["healed"]], [("refund", "new-id")])
        self.assertEqual(refunds.orphans(self.conn), [])


class InTheSnapshot(Base):
    def test_the_credit_and_the_purchase_are_tagged(self):
        refunds.set_link(self.conn, self.back, self.out)
        rows = {t["id"]: t for t in queries.snapshot(self.conn)["transactions"]}
        self.assertEqual(rows[self.back]["refundOf"], self.out)
        self.assertEqual(rows[self.back]["refundMode"], "skip")
        self.assertEqual(rows[self.out]["refundedBy"], [self.back])
        self.assertEqual((rows[self.out]["refundedAmount"], rows[self.out]["refundState"]), (3816.0, "full"))
        self.assertNotIn("refundOf", rows[self.other])

    def test_a_smaller_refund_is_partial_and_a_waiting_one_is_pending(self):
        ingest.upsert_rows(self.conn, self.card, [
            {"id": "x4", "date": "2026-11-14", "merchant": "FLIPKART INTERNET PVT L", "amount": 1000.0,
             "currency": "INR", "rawStatementRowId": "4"}])
        part = [r[0] for r in self.conn.execute("SELECT id FROM transactions WHERE amount_paise = 100000 ORDER BY id")][0]
        refunds.set_link(self.conn, part, self.out)
        snap = queries.snapshot(self.conn)
        rows = {t["id"]: t for t in snap["transactions"]}
        self.assertEqual(rows[self.out]["refundState"], "partial")
        self.assertTrue([x for x in snap["refunds"] if x["partial"]])
        refunds.clear_link(self.conn, part)
        refunds.expect(self.conn, self.out, 381600)
        snap = queries.snapshot(self.conn)
        rows = {t["id"]: t for t in snap["transactions"]}
        self.assertEqual(rows[self.out]["refundState"], "pending")
        self.assertEqual(snap["refundExpect"][0]["originalId"], self.out)
        self.assertIn(part, snap["refundNot"])

    def test_the_one_sided_refund_has_no_original_but_keeps_its_note(self):
        refunds.set_link(self.conn, self.other, None, note="old order")
        snap = queries.snapshot(self.conn)
        rows = {t["id"]: t for t in snap["transactions"]}
        self.assertEqual((rows[self.other]["refundOf"], rows[self.other]["refundNote"]), ("", "old order"))
        self.assertIsNone(snap["refunds"][0]["originalAmount"])


class FromTheCommandLine(Base):
    def test_link_mode_expect_and_unlink(self):
        self.assertEqual(self.cli("refund-link", self.back, self.out).returncode, 0)
        self.assertEqual(self.cli("refund-mode", self.back, "lent").returncode, 0)
        self.assertEqual(self.cli("refund-expect", self.out, "100").returncode, 0)
        bad = self.cli("refund-link", self.out, self.back)
        self.assertEqual(bad.returncode, 2)
        self.assertIn("money in", bad.stderr)
        self.assertEqual(self.cli("refund-unlink", self.back).returncode, 0)
        self.assertEqual(json.loads(self.cli("refund-verify").stdout), {"new": 0})
        self.assertEqual(self.cli("refund-restore", self.back).returncode, 0)
        self.assertEqual(json.loads(self.cli("refund-verify").stdout), {"new": 1})
        self.assertIn("refund links: 1 linked, 0 orphaned", self.cli("check").stdout)


if __name__ == "__main__":
    unittest.main()


class PaidSinceTheBill(Base):
    """queries counts only card PAYMENTS as paid: a refund is money in, not the bill being paid."""

    def test_a_refund_is_not_a_payment_but_a_payment_received_is(self):
        ingest.set_card_cycle(self.conn, self.card, {"name": "Amazon", "total_outstanding": "₹5,000.00",
                                                     "upcoming_payment_due": "₹4,000.00", "payment_status": "AMOUNT DUE",
                                                     "billing_cycle": "1st of every month", "due_text": "Due on 21 Nov 2026"})
        ingest.upsert_rows(self.conn, self.card, [
            {"id": "p1", "date": "2026-11-15", "merchant": "PAYMENT RECEIVED 000AX99", "amount": 4000.0,
             "currency": "INR", "rawStatementRowId": "9"}])
        card = queries.snapshot(self.conn)["cardOverviews"][0]
        self.assertEqual(card["paidSinceBill"], 4000.0)          # not 4000 + the 3,816 refund + the 100 credit
        self.assertEqual(card["paidSinceDate"], "2026-11-15")
