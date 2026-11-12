import tempfile
import unittest
from pathlib import Path

from txdb import db, ingest, receipts


class NoteBillTests(unittest.TestCase):
    def setUp(self):
        self.conn = db.connect(Path(tempfile.mkdtemp()) / "t.db")
        aid = ingest.ensure_account(self.conn, "ICICI", "credit", "4002")
        ingest.replace_unsettled(self.conn, aid, [{"id": "icici-a", "date": "2026-11-10", "merchant": "CAFE",
            "amount": -150.0, "currency": "INR", "balance": None, "raw_row_id": None, "group_key": "CAFE"}])

    def test_note_is_saved_and_cleared(self):
        receipts.set_txn_note(self.conn, "icici-a", " hello ")
        self.assertEqual(self.conn.execute("SELECT note FROM txn_notes").fetchone()[0], "hello")
        receipts.set_txn_note(self.conn, "icici-a", "")
        self.assertIsNone(self.conn.execute("SELECT note FROM txn_notes").fetchone())

    def test_note_becomes_linked_bill(self):
        rid = receipts.note_bill(self.conn, "icici-a", "Coffee 100\nCake 50\nthanks")
        r = self.conn.execute("SELECT total_paise, state, transaction_id FROM receipts_view WHERE id=?", (rid,)).fetchone()
        self.assertEqual(tuple(r), (15000, "linked", "icici-a"))
        items = self.conn.execute("SELECT description, amount_paise FROM receipt_items ORDER BY line_no").fetchall()
        self.assertEqual([tuple(i) for i in items], [("Coffee", 10000), ("Cake", 5000), ("thanks", None)])
