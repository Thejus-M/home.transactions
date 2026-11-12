"""Each snapshot transaction carries the category the Cashew export would pick."""
import sqlite3
import unittest
from pathlib import Path

from txdb import queries

DB = Path(__file__).resolve().parent.parent / "data" / "transactions.db"


@unittest.skipUnless(DB.exists(), "no live database")
class SnapshotCategoryTests(unittest.TestCase):
    def test_every_row_has_category_fields(self):
        conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        snap = queries.snapshot(conn)
        self.assertTrue(snap["transactions"])
        for t in snap["transactions"]:
            self.assertIn("category", t)
            self.assertIn("subcategory", t)
            self.assertNotEqual(t["category"], "Uncategorized")


if __name__ == "__main__":
    unittest.main()


class CategoryIconDataTests(unittest.TestCase):
    def test_every_category_and_subcategory_has_a_symbol(self):
        from txdb import cashew
        for c in cashew.load_categories():
            self.assertTrue(c["icon"], c["name"])
            for s in c["subcategories"]:
                self.assertTrue(c["subIcons"].get(s), f"{c['name']} / {s}")
