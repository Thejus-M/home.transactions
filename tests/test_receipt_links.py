"""A bill's link survives a transaction changing its id (settling, a replaced card)."""
import sqlite3
import tempfile
import unittest
from pathlib import Path

from txdb import db, ingest, receipts


def make():
    tmp = Path(tempfile.mkdtemp()) / "t.db"
    conn = db.connect(tmp)
    aid = ingest.ensure_account(conn, "ICICI", "credit", "4002")
    return conn, aid


def add_receipt(conn, rid="rcpt-1"):
    with db.write(conn):
        conn.execute("INSERT INTO receipts (id, image_sha256, stored_path, parsed_at, imported_at) VALUES (?,?,?,?,?)",
                     (rid, rid, "x", "2026-11-01T00:00:00", "2026-11-01T00:00:00"))


def row(id, date="2026-11-10", amount=-15000, merchant="CAFE"):
    return {"id": id, "date": date, "merchant": merchant, "amount": amount / 100, "currency": "INR",
            "balance": None, "raw_row_id": None, "group_key": merchant}


class LinkTests(unittest.TestCase):
    def test_link_saves_a_fingerprint(self):
        conn, aid = make()
        ingest.replace_unsettled(conn, aid, [row("icici-a")])
        add_receipt(conn)
        receipts.set_link(conn, "rcpt-1", "icici-a")
        r = conn.execute("SELECT fp_date, fp_amount_paise, fp_account_id FROM receipt_links").fetchone()
        self.assertEqual(tuple(r), ("2026-11-10", -15000, aid))

    def test_unsettled_row_settles_with_a_new_id(self):
        conn, aid = make()
        ingest.replace_unsettled(conn, aid, [row("icici-a")])
        add_receipt(conn)
        receipts.set_link(conn, "rcpt-1", "icici-a")
        ingest.replace_unsettled(conn, aid, [])          # the pending row is gone
        self.assertEqual(len(ingest.heal_links(conn)["orphans"]), 1)
        ingest.upsert_rows(conn, aid, [{**row("icici-b"), "status": "settled"}])
        out = ingest.heal_links(conn)
        self.assertEqual([h["to"] for h in out["healed"]], ["icici-b"])
        self.assertEqual(conn.execute("SELECT transaction_id FROM receipt_links").fetchone()[0], "icici-b")

    def test_two_candidates_are_left_alone(self):
        conn, aid = make()
        ingest.replace_unsettled(conn, aid, [row("icici-a")])
        add_receipt(conn)
        receipts.set_link(conn, "rcpt-1", "icici-a")
        ingest.replace_unsettled(conn, aid, [])
        ingest.upsert_rows(conn, aid, [{**row("icici-b"), "status": "settled"}, {**row("icici-c"), "status": "settled"}])
        out = ingest.heal_links(conn)
        self.assertEqual(out["healed"], [])
        self.assertIn("2 transactions", out["orphans"][0]["reason"])

    def test_card_replaced_same_bank(self):
        conn, aid = make()
        ingest.upsert_rows(conn, aid, [{**row("icici-a"), "status": "settled"}])
        add_receipt(conn)
        receipts.set_link(conn, "rcpt-1", "icici-a")
        new = ingest.ensure_account(conn, "ICICI", "credit", "9999")
        with db.write(conn):
            conn.execute("DELETE FROM transactions WHERE id = 'icici-a'")
        ingest.upsert_rows(conn, new, [{**row("icici-z"), "status": "settled"}])
        self.assertEqual([h["to"] for h in ingest.heal_links(conn)["healed"]], ["icici-z"])


if __name__ == "__main__":
    unittest.main()
