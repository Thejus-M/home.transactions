"""txdb/cashew_edits.py: widget edits of rows Cashew already has."""
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_edits  # noqa: E402


def live():
    c = sqlite3.connect(":memory:")
    c.execute("CREATE TABLE categories (category_pk TEXT, name TEXT, main_category_pk TEXT)")
    c.executemany("INSERT INTO categories VALUES (?,?,?)", [("h", "Housing", None), ("r", "Rent", "h"), ("f", "Food Out", None)])
    c.execute("CREATE TABLE transactions (transaction_pk TEXT, type INTEGER)")
    c.executemany("INSERT INTO transactions VALUES (?,?)", [("p1", None), ("p2", 1)])
    return c


def draft(i, pk, **v):
    return dict({"id": i, "cashewPk": pk, "inCashew": True, "title": "KIRAN", "notes": "", "category": "Food Out", "subcategory": ""}, **v)


class Edits(unittest.TestCase):
    def test_first_sight_only_fills_the_memo(self):
        st, memo, ch = cashew_edits.plan([draft("a", "p1")], live(), {})
        self.assertEqual((st, ch), ([], []))
        self.assertEqual(memo["a"]["title"], "KIRAN")

    def test_an_edit_updates_only_the_changed_fields(self):
        _, memo, _ = cashew_edits.plan([draft("a", "p1")], live(), {})
        st, _, ch = cashew_edits.plan([draft("a", "p1", notes="rent", category="Housing", subcategory="Rent")], live(), memo, now=5)
        self.assertEqual(ch, ["a"])
        self.assertEqual(st, ["UPDATE transactions SET note = 'rent', category_fk = 'h', sub_category_fk = 'r', "
                              "date_time_modified = 5 WHERE transaction_pk = 'p1'"])

    def test_recurring_and_rows_not_in_cashew_are_left(self):
        memo = {"b": {"title": "x", "notes": "", "category": "Food Out", "subcategory": ""}}
        st, _, _ = cashew_edits.plan([draft("b", "p2", title="y"), dict(draft("c", None), inCashew=False)], live(), memo)
        self.assertEqual(st, [])


class Vanished(unittest.TestCase):
    def test_a_settled_pending_row_leaves_cashew(self):
        memo = {"p1": {"title": "x", "pk": "c1", "pending": True}, "s1": {"title": "y", "pk": "c2", "pending": False},
                "p2": {"title": "z", "pk": "c3", "pending": True}}
        st, keep = cashew_edits.vanished(memo, {"p2", "s1"})
        self.assertEqual(sorted(keep), ["p2", "s1"])
        self.assertEqual(len(st), 2)
        self.assertIn("DELETE FROM transactions WHERE transaction_pk = 'c1'", st[1])


if __name__ == "__main__":
    unittest.main()
