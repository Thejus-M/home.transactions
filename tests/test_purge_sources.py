"""receipts.purge_source_photos: the original photo in the KDE share goes 3 hours after linking, only when it is
safe (compressed copy in the database, the exact imported photo, inside the share)."""
import hashlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, receipts  # noqa: E402


def stamp(hours_ago):
    return (datetime.now() - timedelta(hours=hours_ago)).isoformat(timespec="seconds")


class Purge(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name)
        self.share = root / "KDE Share"
        self.share.mkdir()
        self.elsewhere = root / "Pictures"
        self.elsewhere.mkdir()
        self.conn = db.connect(root / "t.db")
        self.n = 0

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def bill(self, folder=None, linked_hours_ago=5, saved=True, state="linked", content=b"photo bytes", sha=None):
        """One bill with its photo file; returns (id, path)."""
        self.n += 1
        rid = f"rcpt-{self.n}"
        path = (folder or self.share) / f"RUID{self.n}.jpg"
        path.write_bytes(content)
        sha = sha or hashlib.sha256(content).hexdigest()
        self.conn.execute("INSERT INTO receipts (id, image_sha256, stored_path, source_path, parsed_at, imported_at) "
                          "VALUES (?,?,?,?,'now','now')", (rid, sha, f"receipts/{rid}.jpg", str(path)))
        if state:
            txn = f"t{self.n}" if state == "linked" else None
            self.conn.execute("INSERT INTO receipt_links (receipt_id, transaction_id, state, linked_at) VALUES (?,?,?,?)",
                              (rid, txn, state, stamp(linked_hours_ago)))
        if saved:
            self.conn.execute("INSERT INTO receipt_images (receipt_id, mime, bytes, data, saved_at) VALUES (?,?,?,?,'now')",
                              (rid, "image/jpeg", 5, b"small"))
        self.conn.commit()
        return rid, path

    def run_purge(self, **kw):
        return {x["id"]: x["action"] for x in receipts.purge_source_photos(self.conn, folder=self.share, **kw)}

    def test_a_safe_photo_is_deleted_after_three_hours(self):
        rid, path = self.bill(linked_hours_ago=3.5)
        self.assertEqual(self.run_purge(), {rid: "deleted"})
        self.assertFalse(path.exists())
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM receipt_images").fetchone()[0], 1)   # the copy stays

    def test_a_bill_linked_less_than_three_hours_ago_keeps_its_photo(self):
        rid, path = self.bill(linked_hours_ago=1)
        self.assertIn("less than 3 h", self.run_purge()[rid])
        self.assertTrue(path.exists())

    def test_the_hours_can_be_set(self):
        rid, path = self.bill(linked_hours_ago=1)
        self.assertEqual(self.run_purge(hours=0.5), {rid: "deleted"})

    def test_no_copy_in_the_database_means_the_photo_is_kept(self):
        rid, path = self.bill(saved=False)
        self.assertIn("no compressed copy", self.run_purge()[rid])
        self.assertTrue(path.exists())

    def test_an_unlinked_bill_is_never_touched(self):
        rid, path = self.bill(state=None)
        self.assertEqual(self.run_purge(), {})
        self.assertTrue(path.exists())

    def test_a_cash_or_ignored_bill_is_not_a_linked_bill(self):
        rid, path = self.bill(state="cash")
        self.assertEqual(self.run_purge(), {})
        self.assertTrue(path.exists())

    def test_a_file_outside_the_share_is_never_deleted(self):
        rid, path = self.bill(folder=self.elsewhere)
        self.assertIn("not in the photo folder", self.run_purge()[rid])
        self.assertTrue(path.exists())

    def test_a_file_that_is_not_the_imported_photo_is_kept(self):
        rid, path = self.bill(sha="0" * 64)
        self.assertIn("not the photo", self.run_purge()[rid])
        self.assertTrue(path.exists())

    def test_a_dry_run_deletes_nothing(self):
        rid, path = self.bill()
        self.assertEqual(self.run_purge(dry_run=True), {rid: "would delete"})
        self.assertTrue(path.exists())

    def test_other_files_in_the_share_are_left_alone_and_a_second_run_does_nothing(self):
        rid, path = self.bill()
        other = self.share / "holiday.jpg"
        other.write_bytes(b"not a bill")
        self.assertEqual(self.run_purge(), {rid: "deleted"})
        self.assertTrue(other.exists())
        self.assertEqual(self.run_purge(), {})


if __name__ == "__main__":
    unittest.main()
