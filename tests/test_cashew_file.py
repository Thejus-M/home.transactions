"""txdb/cashew_file.py: the rows written straight into a copy of the Cashew database."""
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_file  # noqa: E402

COLS = ["transaction_pk", "paired_transaction_fk", "name", "amount", "note", "category_fk", "sub_category_fk", "wallet_fk",
        "date_created", "date_time_modified", "original_date_due", "income", "period_length", "reoccurrence", "end_date",
        "upcoming_transaction_notification", "type", "paid", "created_another_future_transaction", "skip_paid",
        "method_added", "transaction_owner_email", "transaction_original_owner_email", "shared_key", "shared_old_key",
        "shared_status", "shared_date_updated", "shared_reference_budget_pk", "objective_fk", "objective_loan_fk",
        "budget_fks_exclude"]


def ts(day):
    return int(datetime.strptime(day, "%Y-%m-%d").timestamp())


def fake_cashew(path):
    c = sqlite3.connect(path)
    # the real column layout of Cashew's categories table
    c.execute('CREATE TABLE categories (category_pk TEXT PRIMARY KEY, name TEXT, colour TEXT, icon_name TEXT, '
              'emoji_icon_name TEXT, date_created INTEGER, date_time_modified INTEGER, "order" INTEGER, income INTEGER, '
              'method_added INTEGER, main_category_pk TEXT, archived INTEGER)')
    c.executemany("INSERT INTO categories (category_pk, name, colour, icon_name, \"order\", income, main_category_pk, archived) "
                  "VALUES (?, ?, '0xff607d8b', 'charts.png', ?, ?, ?, 0)", [
        ("0", "Balance Correction", 0, 0, None), ("c-food", "Food Out", 1, 0, None), ("s-lunch", "Lunch", 90, 0, "c-food"),
        ("c-shop", "Shopping", 2, 0, None)])
    c.execute("CREATE TABLE wallets (wallet_pk TEXT PRIMARY KEY, name TEXT)")
    c.executemany("INSERT INTO wallets VALUES (?,?)", [("0", "HDFC"), ("w-sbi", "SBI")])
    c.execute(f"CREATE TABLE transactions ({', '.join(COLS)})")
    row = {k: None for k in COLS}
    row.update(transaction_pk="t0", name="old", amount=-10.0, note="", category_fk="c-food", wallet_fk="0",
               date_created=ts("2026-11-01"), date_time_modified=1, original_date_due=1, income=0,
               upcoming_transaction_notification=1, paid=1, created_another_future_transaction=0, skip_paid=0, method_added=4)
    c.execute(f"INSERT INTO transactions VALUES ({', '.join('?' * len(COLS))})", [row[k] for k in COLS])
    c.commit()
    c.close()


def d(id, amount, **kw):
    x = {"id": id, "include": True, "date": "2026-11-15", "title": "T " + id, "amount": amount, "category": "Food Out",
         "subcategory": "Lunch", "account": "HDFC", "notes": "n " + id, "kind": "spend", "pairId": ""}
    x.update(kw)
    return x


class CashewFile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.base = Path(self.dir.name) / "base.sqlite"
        fake_cashew(self.base)
        self.out = Path(self.dir.name) / "out.sqlite"

    def tearDown(self):
        self.dir.cleanup()

    def rows(self):
        c = sqlite3.connect(self.out)
        c.row_factory = sqlite3.Row
        return {r["name"]: dict(r) for r in c.execute("SELECT * FROM transactions")}

    def test_rows_pairs_dedupe_and_skips(self):
        drafts = [
            d("a", "-75.00", notes="BATMINTON"),
            d("old", "-10.00", date="2026-11-01", title="already there"),                       # Cashew has it
            d("o", "-160.00", kind="transfer", pairId="p", title="HDFC → SBI", category="Balance Correction", subcategory=""),
            d("i", "160.00", kind="transfer", pairId="p", title="HDFC → SBI", account="SBI", category="Balance Correction", subcategory=""),
            d("r", "3816.00", category="Shopping", subcategory="", title="refund", kind="refund"),   # income by the sign
            d("x", "-5.00", category="Nope", title="unknown cat"),
            d("y", "-6.00", account="Nowhere", title="unknown acct"),
            d("z", "-7.00", include=False, title="not ticked"),
        ]
        got = cashew_file.build(self.base, self.out, drafts)
        self.assertEqual((got["base"], got["added"], got["transfers"], got["already"]), (1, 4, 1, 1))
        self.assertEqual(sorted(s["title"] for s in got["skipped"]), ["unknown acct", "unknown cat"])
        self.assertEqual(sorted(got["ids"]), ["a", "i", "o", "r"])
        self.assertTrue(self.out.exists() and not Path(str(self.out) + ".tmp").exists())
        self.assertEqual(oct(os.stat(self.out).st_mode & 0o777), "0o600")
        c = sqlite3.connect(self.out)
        self.assertEqual(c.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(c.execute("SELECT count(*) FROM transactions").fetchone()[0], 1 + 4)
        c.close()
        rows = sqlite3.connect(self.out)
        rows.row_factory = sqlite3.Row
        pair = [dict(r) for r in rows.execute("SELECT * FROM transactions WHERE category_fk = '0' ORDER BY amount")]
        out_leg, in_leg = pair
        self.assertEqual((out_leg["amount"], out_leg["wallet_fk"], out_leg["income"]), (-160.0, "0", 0))
        self.assertEqual((in_leg["amount"], in_leg["wallet_fk"], in_leg["income"]), (160.0, "w-sbi", 1))
        self.assertEqual(out_leg["paired_transaction_fk"], in_leg["transaction_pk"])
        self.assertIsNone(in_leg["paired_transaction_fk"])
        self.assertEqual(in_leg["date_created"] - out_leg["date_created"], 1)
        self.assertEqual(out_leg["note"], "Transferred Balance\nHDFC → SBI")
        a = dict(rows.execute("SELECT * FROM transactions WHERE name = 'T a'").fetchone())
        self.assertEqual((a["category_fk"], a["sub_category_fk"], a["note"], a["income"], a["method_added"]),
                         ("c-food", "s-lunch", "BATMINTON", 0, 4))
        self.assertEqual(a["date_created"], ts("2026-11-15"))
        r = dict(rows.execute("SELECT * FROM transactions WHERE name = 'refund'").fetchone())
        self.assertEqual((r["income"], r["sub_category_fk"]), (1, None))

    def test_a_new_subcategory_is_added_to_cashew_not_skipped(self):
        got = cashew_file.build(self.base, self.out, [d("a", "-75.00", category="Fitness", subcategory="Sports"),
                                                      d("b", "-9.00", category="Groceries", subcategory="Dairy & Bakery"),
                                                      d("c", "-1.00", category="Not In The List", subcategory="")])
        self.assertEqual(got["added"], 2)
        self.assertEqual([s["title"] for s in got["skipped"]], ["T c"])
        self.assertEqual(sorted(got["addedCategories"]), ["Dairy & Bakery", "Fitness", "Groceries", "Sports"])
        c = sqlite3.connect(self.out)
        sub = c.execute("SELECT t.sub_category_fk, s.name, s.main_category_pk = t.category_fk FROM transactions t "
                        "JOIN categories s ON s.category_pk = t.sub_category_fk WHERE t.name = 'T a'").fetchone()
        self.assertEqual(sub[1:], ("Sports", 1))

    def test_notes_go_onto_existing_rows_and_the_balance_is_closed(self):
        c = sqlite3.connect(self.base)
        c.execute("UPDATE transactions SET note = 'my own' WHERE transaction_pk = 't0'")
        c.commit()
        c.close()
        old = d("old", "-10.00", date="2026-11-01", notes="BATMINTON")                 # Cashew has it (t0)
        got = cashew_file.build(self.base, self.out, [], note_drafts=[old, d("x", "-1.00", notes="")],
                                balances=[{"account": "HDFC", "date": "2026-11-15", "paise": 50000},
                                          {"account": "Nowhere", "date": "2026-11-15", "paise": 1}])
        self.assertEqual((got["added"], got["notesUpdated"], got["changes"]), (0, 1, 2))
        self.assertEqual(got["corrections"], [{"account": "HDFC", "date": "2026-11-15", "bank": 500.0, "cashew": -10.0,
                                               "diff": 510.0, "waiting": 0.0, "waitingRows": 0}])
        c = sqlite3.connect(self.out)
        self.assertEqual(c.execute("SELECT note FROM transactions WHERE transaction_pk = 't0'").fetchone()[0], "my own\nBATMINTON")
        fix = c.execute("SELECT amount, category_fk, income, date_created FROM transactions WHERE name = 'Balance correction'").fetchone()
        self.assertEqual(fix[:3], (510.0, "0", 1))
        self.assertEqual(fix[3], ts("2026-11-16") - 1)                                   # end of the bank's day
        self.assertEqual(c.execute("SELECT sum(amount) FROM transactions WHERE wallet_fk = '0' AND paid = 1").fetchone()[0], 500.0)
        again = cashew_file.build(self.out, Path(str(self.out) + "2"), [], note_drafts=[old],
                                  balances=[{"account": "HDFC", "date": "2026-11-15", "paise": 50000}])
        self.assertEqual(again["changes"], 0)                                           # nothing left to do

    def test_a_bill_already_in_the_note_is_not_added_twice_and_waiting_rows_get_room(self):
        c = sqlite3.connect(self.base)
        c.execute("UPDATE transactions SET note = ? WHERE transaction_pk = 't0'", ("• 1 × Tea — ₹10\nTotal ₹10",))
        c.commit()
        c.close()
        old = d("old", "-10.00", date="2026-11-01", notes="BATMINTON\n• 1 × Tea — ₹10\nTotal ₹10")
        got = cashew_file.build(self.base, self.out, [], note_drafts=[old],
                                balances=[{"account": "HDFC", "date": "2026-11-15", "paise": 50000, "waitingPaise": 2000, "waitingRows": 1}])
        c = sqlite3.connect(self.out)
        self.assertEqual(c.execute("SELECT note FROM transactions WHERE transaction_pk = 't0'").fetchone()[0],
                         "• 1 × Tea — ₹10\nTotal ₹10\nBATMINTON")
        self.assertEqual(got["corrections"][0]["diff"], 490.0)                 # 500 - (-10) - 20 waiting
        nothing = cashew_file.build(self.out, Path(str(self.out) + "2"), [], note_drafts=[old])
        self.assertEqual(nothing["notesUpdated"], 0)

    def test_dry_run_and_nothing_to_add_write_no_file(self):
        got = cashew_file.build(self.base, self.out, [d("a", "-75.00")], dry_run=True)
        self.assertEqual((got["added"], got["path"], got["dryRun"]), (1, "", True))
        self.assertFalse(self.out.exists())
        none = cashew_file.build(self.base, self.out, [d("old", "-10.00", date="2026-11-01")])
        self.assertEqual((none["added"], none["path"]), (0, ""))
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
