"""A card's minimum due is kept apart from its total due (ICICI prints both)."""
import tempfile
import unittest
from pathlib import Path

from txdb import db, ingest, queries


class MinimumDueTests(unittest.TestCase):
    def test_minimum_due_and_due_date_round_trip(self):
        conn = db.connect(Path(tempfile.mkdtemp()) / "t.db")
        aid = ingest.ensure_account(conn, "ICICI", "credit", "4002")
        ingest.set_card_cycle(conn, aid, {
            "name": "Amazon Pay", "total_outstanding": "₹16,591.82", "upcoming_payment_due": "₹16,591.82",
            "last_statement_amount": "₹16,591.82", "unbilled_purchases": "₹0", "unbilled_amount": "₹0",
            "minimum_due": "₹830", "billing_cycle": "12th of every month", "due_text": "Due on 30 Nov 2026"})
        card = queries.snapshot(conn)["cardOverviews"][0]
        self.assertEqual((card["minimum_due"], card["dueDate"]), ("₹830", "2026-11-30"))
        self.assertEqual(card["last_statement_amount"], "₹16,591.82")


if __name__ == "__main__":
    unittest.main()
