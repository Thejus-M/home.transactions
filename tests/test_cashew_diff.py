"""txdb/cashew_diff.py: the change between two Cashew databases as SQL."""
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_diff  # noqa: E402


def db(rows):
    c = sqlite3.connect(":memory:")
    c.execute("CREATE TABLE transactions (transaction_pk TEXT PRIMARY KEY, name TEXT, note TEXT, amount REAL, type INTEGER)")
    c.executemany("INSERT INTO transactions VALUES (?,?,?,?,?)", rows)
    return c


class Diff(unittest.TestCase):
    def test_insert_update_no_delete_no_recurring(self):
        base = db([("a", "Rent", "", -3200.0, 1), ("b", "Tea's", "", -10.0, None), ("gone", "x", "", 1.0, None)])
        new = db([("a", "Rent", "edited", -3200.0, 1), ("b", "Tea's", "UPI 123", -10.0, None),
                  ("c", "New", None, -1.5, None)])
        st = cashew_diff.statements(base, new)
        self.assertEqual(st, ['UPDATE "transactions" SET "note" = \'UPI 123\' WHERE "transaction_pk" = \'b\'',
                              'INSERT INTO "transactions" ("transaction_pk", "name", "note", "amount", "type") '
                              "VALUES ('c', 'New', NULL, -1.5, NULL)"])
        for s in st:
            base.execute(s)
        self.assertEqual(base.execute("SELECT count(*) FROM transactions").fetchone()[0], 4)   # nothing deleted

    def test_schema_change_stops(self):
        base = db([])
        new = db([])
        new.execute("CREATE TABLE extra (k TEXT PRIMARY KEY)")
        with self.assertRaises(ValueError):
            cashew_diff.statements(base, new)


if __name__ == "__main__":
    unittest.main()
