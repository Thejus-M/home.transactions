"""txdb/cashew_direct.py: a Cashew database put straight into a (fake) Zen IndexedDB folder."""
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_direct  # noqa: E402
from test_cashew_file import d, fake_cashew  # noqa: E402

RECORD = bytes.fromhex("03000000" "0000f1ff" "00000000" "0180ffff") + (0).to_bytes(8, "little") + bytes(8)


def fake_storage(root: Path, blob_id=7) -> Path:
    """profile/storage/default/https+++budget-track.web.app with an IndexedDB like Zen's."""
    origin = root / "profile" / "storage" / "default" / "https+++budget-track.web.app"
    idb = origin / "idb"
    files = idb / "123moor.files"
    files.mkdir(parents=True)
    fake_cashew(files / str(blob_id))
    size = (files / str(blob_id)).stat().st_size
    record = bytearray(RECORD)
    record[16:24] = size.to_bytes(8, "little")
    c = sqlite3.connect(idb / "123moor.sqlite")
    c.execute("CREATE TABLE object_store (id INTEGER PRIMARY KEY, name TEXT)")
    c.execute("INSERT INTO object_store VALUES (1, 'moor_databases')")
    c.execute("CREATE TABLE object_data (object_store_id INTEGER, key BLOB, index_data_values BLOB, file_ids TEXT, data BLOB)")
    c.execute("CREATE TABLE file (id INTEGER PRIMARY KEY, refcount INTEGER NOT NULL)")
    c.execute("CREATE TRIGGER object_data_update_trigger AFTER UPDATE OF file_ids ON object_data FOR EACH ROW "
              "WHEN OLD.file_ids IS NOT NULL OR NEW.file_ids IS NOT NULL BEGIN SELECT update_refcount(OLD.file_ids, NEW.file_ids); END")
    c.execute("INSERT INTO object_data VALUES (1, x'306563', NULL, ?, ?)", (str(blob_id), cashew_direct.snappy_literal(bytes(record))))
    c.execute("INSERT INTO file VALUES (?, 1)", (blob_id,))
    c.commit()
    c.close()
    return origin


class Direct(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.storage = fake_storage(self.root)

    def tearDown(self):
        self.dir.cleanup()

    def test_snappy_round_trip(self):
        raw = bytes(range(32))
        self.assertEqual(cashew_direct.snappy_decompress(cashew_direct.snappy_literal(raw)), raw)
        real = bytes.fromhex("20040300010104F1FF01064C0180FFFF00D01B00000000000000000000000000")   # from Zen
        self.assertEqual(int.from_bytes(cashew_direct.snappy_decompress(real)[16:24], "little"), 1822720)

    def test_apply_writes_a_new_blob_points_the_record_at_it_and_backs_up(self):
        blob, size = cashew_direct.current(self.storage)
        self.assertEqual((blob.name, size), ("7", blob.stat().st_size))
        r = cashew_direct.apply(self.storage, [d("a", "-75.00", notes="x" * 20000)], self.root / "backup")
        self.assertEqual((r["written"], r["base"]), (1, 1))
        new_blob, new_size = cashew_direct.current(self.storage)
        self.assertEqual(new_blob.name, "8")
        self.assertEqual(new_size, new_blob.stat().st_size)
        self.assertNotEqual(new_size, size)                       # the record carries the new size
        self.assertFalse(blob.exists())                           # the old one lives in the backup only
        backups = list((self.root / "backup").iterdir())
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "db-7.sqlite").exists() and (backups[0] / "123moor.sqlite").exists())
        idx = sqlite3.connect(self.storage / "idb" / "123moor.sqlite")
        self.assertEqual(list(idx.execute("SELECT * FROM file")), [(8, 1)])
        db = sqlite3.connect(new_blob)
        self.assertEqual(db.execute("SELECT count(*) FROM transactions").fetchone()[0], 2)
        again = cashew_direct.apply(self.storage, [d("a", "-75.00")], self.root / "backup")
        self.assertEqual(again["written"], 0)                     # Cashew has it now: nothing written twice
        self.assertEqual(len(list((self.root / "backup").iterdir())), 1)   # and no backup for a run with nothing to do

    def test_nothing_to_write_leaves_no_backup(self):
        r = cashew_direct.apply(self.storage, [], self.root / "backup")
        self.assertEqual((r["written"], r["backup"]), (0, ""))
        self.assertFalse((self.root / "backup").exists())

    def test_a_running_zen_blocks_the_write(self):
        profile = self.storage.parent.parent.parent
        os.symlink(f"127.0.0.1:+{os.getpid()}", profile / "lock")       # a live pid: Zen "running"
        self.assertEqual(cashew_direct.in_use(self.storage), [os.getpid()])
        with self.assertRaises(ValueError):
            cashew_direct.apply(self.storage, [d("a", "-75.00")], self.root / "backup")
        (profile / "lock").unlink()
        os.symlink("127.0.0.1:+999999999", profile / "lock")              # stale lock after a crash
        self.assertEqual(cashew_direct.in_use(self.storage), [])

    def test_a_record_that_does_not_match_its_blob_is_not_touched(self):
        blob, _ = cashew_direct.current(self.storage)
        blob.write_bytes(blob.read_bytes() + b"\0" * 10)
        with self.assertRaises(ValueError):
            cashew_direct.apply(self.storage, [d("a", "-75.00")], self.root / "backup")


if __name__ == "__main__":
    unittest.main()
