"""txdb/cashew_recurring.py: Cashew's recurring series and their state this cycle."""
import sqlite3
import sys
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_recurring  # noqa: E402


def ts(day):
    return int(datetime.strptime(day, "%Y-%m-%d").timestamp())


def fake():
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE categories (category_pk TEXT, name TEXT)")
    db.executemany("INSERT INTO categories VALUES (?,?)", [("c-inv", "Investments"), ("s-mf", "Mutual Funds"),
                                                           ("c-h", "Housing"), ("s-rent", "Rent")])
    db.execute("CREATE TABLE wallets (wallet_pk TEXT, name TEXT)")
    db.executemany("INSERT INTO wallets VALUES (?,?)", [("w-ax", "Axis"), ("w-h", "HDFC")])
    db.execute("CREATE TABLE transactions (name TEXT, amount REAL, category_fk TEXT, sub_category_fk TEXT, wallet_fk TEXT, "
               "date_created INTEGER, period_length INTEGER, reoccurrence INTEGER, paid INTEGER, type INTEGER)")
    rows = [("SIP  A\\nGrowth", -1000, "c-inv", "s-mf", "w-ax", "2026-09-17", 1, 3, 1, 1),
            ("SIP  A\\nGrowth", -1000, "c-inv", "s-mf", "w-ax", "2026-10-17", 1, 3, 1, 1),
            ("SIP  A\\nGrowth", -1000, "c-inv", "s-mf", "w-ax", "2026-11-20", 1, 3, 0, 1),     # next, unpaid
            ("", -3200, "c-h", "s-rent", "w-h", "2026-10-01", 1, 3, 1, 1),
            ("", -3200, "c-h", "s-rent", "w-h", "2026-11-11", 1, 3, 0, 1),                    # next (6 days ago)
            ("Old SIP", -1500, "c-inv", "s-mf", "w-ax", "2025-03-01", 1, 3, 1, 1),           # ended
            ("Coffee", -50, "c-inv", None, "w-ax", "2026-11-01", 1, 3, 1, None)]             # not recurring
    for name, a, c, s, w, d, e, u, p, t in rows:
        db.execute("INSERT INTO transactions VALUES (?,?,?,?,?,?,?,?,?,?)", (name.replace("\\n", "\n"), a, c, s, w, ts(d), e, u, p, t))
    return db


class Recurring(unittest.TestCase):
    def test_series(self):
        got = cashew_recurring.series(fake(), today="2026-11-08")
        titles = [(s["title"], s["active"], s["next"], s["paidCount"]) for s in got]
        self.assertEqual(titles, [("Housing › Rent", True, "2026-11-11", 1), ("SIP A Growth", True, "2026-11-20", 2),
                                  ("Old SIP", False, "", 1)])
        sip = got[1]
        self.assertEqual((sip["account"], sip["category"], sip["subcategory"], sip["every"], sip["unit"], sip["kind"]),
                         ("Axis", "Investments", "Mutual Funds", 1, "month", "subscription"))

    def test_status_paid_due_late_with_four_days(self):
        items = cashew_recurring.series(fake(), today="2026-11-08")
        bank = [{"date": "2026-11-23", "amount": -1000.0, "account": "Axis"},       # 3 days after the due date
                {"date": "2026-11-11", "amount": -3200.0, "account": "SBI"}]        # other account: not the rent
        st = {s["title"]: s for s in cashew_recurring.status(items, bank, today="2026-11-17")}
        self.assertEqual((st["SIP A Growth"]["state"], st["SIP A Growth"]["paidOn"]), ("paid", "2026-11-23"))
        self.assertEqual((st["Housing › Rent"]["state"], st["Housing › Rent"]["lateDays"]), ("late", 6))
        self.assertEqual(st["Old SIP"]["state"], "ended")
        due = {s["title"]: s for s in cashew_recurring.status(items, [], today="2026-11-14")}
        self.assertEqual((due["SIP A Growth"]["state"], due["SIP A Growth"]["inDays"]), ("due", 6))
        self.assertEqual(due["Housing › Rent"]["state"], "due")                     # 3 days late: still inside 4 days
        far = cashew_recurring.status(items, [{"date": "2026-11-26", "amount": -1000.0, "account": "Axis"}], today="2026-11-27")
        self.assertEqual({s["title"]: s["state"] for s in far}["SIP A Growth"], "late")   # 6 days off: not this payment


if __name__ == "__main__":
    unittest.main()
