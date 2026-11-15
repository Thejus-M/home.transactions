"""txdb/cashew_fix.py: rows a Cashew link would get wrong are written into a COPY of Cashew's database with the right
income flag (Cashew takes the type from the category on a link, but a row has its own flag in the database)."""
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.environ.setdefault("TXDB_NO_BROWSER_COPY", "1")

from txdb import cashew_fix  # noqa: E402

COLS = ["transaction_pk", "paired_transaction_fk", "name", "amount", "note", "category_fk", "sub_category_fk", "wallet_fk",
        "date_created", "date_time_modified", "original_date_due", "income", "period_length", "reoccurrence", "end_date",
        "upcoming_transaction_notification", "type", "paid", "created_another_future_transaction", "skip_paid", "method_added",
        "transaction_owner_email", "transaction_original_owner_email", "shared_key", "shared_old_key", "shared_status",
        "shared_date_updated", "shared_reference_budget_pk", "objective_fk", "objective_loan_fk", "budget_fks_exclude"]


def day(iso):
    return int(datetime.strptime(iso, "%Y-%m-%d").timestamp())


def make_cashew(path):
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE categories (category_pk TEXT PRIMARY KEY, name TEXT, income INTEGER, main_category_pk TEXT)")
    c.execute("CREATE TABLE wallets (wallet_pk TEXT PRIMARY KEY, name TEXT)")
    c.execute(f"CREATE TABLE transactions ({', '.join(col + (' TEXT PRIMARY KEY' if col == 'transaction_pk' else '') for col in COLS)})")
    c.executemany("INSERT INTO categories VALUES (?,?,?,?)", [
        ("c-shop", "Shopping", 0, None), ("s-foot", "Footwear", 0, "c-shop"),
        ("c-friend", "Friend Settlements", 1, None), ("s-split", "Split Paid", 0, "c-friend"), ("s-settle", "Settle", 0, "c-friend"),
        ("c-food", "Food Out", 0, None)])
    c.executemany("INSERT INTO wallets VALUES (?,?)", [("w-card", "ICICI 🌳"), ("w-bank", "HDFC")])
    row = dict.fromkeys(COLS)
    row.update(transaction_pk="t-old", name="old link row", amount=-5.0, note="n", category_fk="c-food", wallet_fk="w-bank",
               date_created=day("2026-10-01"), date_time_modified=1, original_date_due=1, income=0, paid=1, method_added=4,
               upcoming_transaction_notification=1, created_another_future_transaction=0, skip_paid=0)
    c.execute(f"INSERT INTO transactions ({', '.join(COLS)}) VALUES ({', '.join('?' * len(COLS))})", [row[k] for k in COLS])
    c.commit()
    return c


def draft(**kw):
    d = {"id": "d", "include": True, "date": "2026-11-12", "title": "Refund: FLIPKART", "amount": "3816.00",
         "category": "Shopping", "subcategory": "Footwear", "account": "ICICI 🌳", "notes": "Refund of FLIPKART 02-Nov-26 ₹3816",
         "kind": "refund", "refundMode": "income", "viaFile": True}
    d.update(kw)
    return d


class Fix(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.base = Path(self.dir.name) / "base.sql"
        self.conn = make_cashew(self.base)
        self.idx = cashew_fix.Index(self.conn)

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def test_names_are_found_with_or_without_the_trailing_s_and_unknown_ones_are_none(self):
        self.assertEqual(self.idx.category("Shopping", "Footwear"), ("c-shop", "s-foot", False))
        self.assertEqual(self.idx.category("Friend Settlement", "Split Paid"), ("c-friend", "s-split", True))   # Cashew: ...Settlements
        self.assertEqual(self.idx.category("friend settlements", "")[0], "c-friend")
        self.assertIsNone(self.idx.category("Nope", ""))

    def test_a_sign_that_disagrees_with_the_cashew_category_type_is_marked(self):
        rows = [draft(viaFile=False, kind="spend", category="Friend Settlement", subcategory="Split Paid", amount="-14000.00"),   # debit, income category
                draft(viaFile=False, kind="income", category="Friend Settlement", subcategory="Settle", amount="245.12"),        # credit, income category: fine
                draft(viaFile=False, kind="spend", category="Food Out", subcategory="", amount="-20.00"),                      # fine
                draft(viaFile=False, kind="spend", category="Uncategorized", subcategory="Unknown", amount="-3.00")]
        marked = cashew_fix.flag(rows, self.idx)
        self.assertEqual(marked, 1)
        self.assertTrue(rows[0]["viaFile"])
        self.assertFalse(any(r.get("viaFile") for r in rows[1:]))

    def test_plan_flags_problems_and_duplicates(self):
        known = draft(viaFile=True, title="old link row", amount="-5.00", date="2026-10-01", kind="spend", category="Food Out")
        items = cashew_fix.plan([draft(), known, draft(account="Nowhere"), draft(category="Nope")], self.idx, self.conn)
        self.assertEqual([(bool(i["problem"]), i["duplicate"]) for i in items], [(False, False), (False, True), (True, False), (True, False)])
        self.assertTrue(items[0]["income"])

    def test_a_row_added_by_hand_with_a_time_of_day_counts_as_already_there(self):
        self.conn.execute("UPDATE transactions SET date_created = ? WHERE transaction_pk = 't-old'",
                          (day("2026-10-01") + 16 * 3600 + 14 * 60 + 5,))
        self.conn.commit()
        known = draft(viaFile=True, title="OLD LINK ROW", amount="-5.00", date="2026-10-01", kind="spend", category="Food Out")
        self.assertTrue(cashew_fix.plan([known], self.idx, self.conn)[0]["duplicate"])
        renamed = dict(known, title="whatever the bank called it")          # the name is not compared
        self.assertTrue(cashew_fix.plan([renamed], self.idx, self.conn)[0]["duplicate"])
        other_day = dict(known, date="2026-10-02")
        self.assertFalse(cashew_fix.plan([other_day], self.idx, self.conn)[0]["duplicate"])

    def test_apply_adds_an_income_row_in_the_expense_category_and_an_expense_row_in_the_income_category(self):
        refund = draft()
        friend = draft(id="f", viaFile=True, kind="spend", title="MIDHUN JAMES", amount="-14000.00", category="Friend Settlement",
                       subcategory="Split Paid", account="HDFC", date="2026-10-30", notes="")
        out = Path(self.dir.name) / "out.sql"
        added = cashew_fix.apply(self.base, out, cashew_fix.plan([refund, friend], self.idx, self.conn))
        self.assertEqual(added, 2)
        c = sqlite3.connect(out)
        c.row_factory = sqlite3.Row
        r = c.execute("SELECT * FROM transactions WHERE name = 'Refund: FLIPKART'").fetchone()
        self.assertEqual((r["amount"], r["income"], r["category_fk"], r["sub_category_fk"], r["wallet_fk"], r["paid"]),
                         (3816.0, 1, "c-shop", "s-foot", "w-card", 1))                     # income, in Shopping
        self.assertEqual(r["date_created"], day("2026-11-12"))
        self.assertEqual(r["method_added"], 4)                                              # copied from an existing link row
        f = c.execute("SELECT * FROM transactions WHERE name = 'MIDHUN JAMES'").fetchone()
        self.assertEqual((f["amount"], f["income"], f["category_fk"], f["sub_category_fk"]), (-14000.0, 0, "c-friend", "s-split"))
        self.assertEqual(c.execute("SELECT COUNT(*) FROM transactions").fetchone()[0], 3)   # the old row is still there
        c.close()

    def test_the_base_is_never_changed_and_a_second_run_adds_nothing(self):
        before = self.base.read_bytes()
        out = Path(self.dir.name) / "out.sql"
        cashew_fix.apply(self.base, out, cashew_fix.plan([draft()], self.idx, self.conn))
        self.assertEqual(self.base.read_bytes(), before)
        again = cashew_fix.plan([draft()], cashew_fix.Index(sqlite3.connect(out)), sqlite3.connect(out))
        self.assertTrue(again[0]["duplicate"])
        out2 = Path(self.dir.name) / "out2.sql"
        self.assertEqual(cashew_fix.apply(out, out2, again), 0)

    def test_rows_with_a_problem_or_a_duplicate_are_skipped(self):
        out = Path(self.dir.name) / "out.sql"
        items = cashew_fix.plan([draft(account="Nowhere")], self.idx, self.conn)
        self.assertEqual(cashew_fix.apply(self.base, out, items), 0)


if __name__ == "__main__":
    unittest.main()
