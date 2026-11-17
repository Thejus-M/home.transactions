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

    def test_status_with_seven_days(self):
        items = cashew_recurring.series(fake(), today="2026-11-08")
        bank = [{"date": "2026-11-26", "amount": -1000.0, "account": "Axis"},       # 6 days after the due date
                {"date": "2026-11-11", "amount": -3200.0, "account": "SBI"}]        # other account: not the rent
        st = {s["title"]: s for s in cashew_recurring.status(items, bank, today="2026-11-27")}
        self.assertEqual((st["SIP A Growth"]["state"], st["SIP A Growth"]["paidOn"]), ("paid", "2026-11-26"))
        self.assertEqual(st["Old SIP"]["state"], "ended")
        far = cashew_recurring.status(items, [{"date": "2026-11-28", "amount": -1000.0, "account": "Axis"}], today="2026-11-29")
        self.assertEqual({s["title"]: s["state"] for s in far}["SIP A Growth"], "late")   # 8 days off: not this payment
        due = {s["title"]: s for s in cashew_recurring.status(items, [], today="2026-11-14")}
        self.assertEqual((due["SIP A Growth"]["state"], due["SIP A Growth"]["inDays"]), ("due", 6))

    def test_late_needs_a_week_and_a_fresh_fetch(self):
        items = cashew_recurring.series(fake(), today="2026-11-08")
        rent = lambda today, fetched: {s["title"]: s for s in cashew_recurring.status(
            items, [], today=today, fetched=fetched)}["Housing › Rent"]       # due 2026-11-11
        six = rent("2026-11-17", {"HDFC": "2026-11-17T09:00:00"})
        self.assertEqual((six["state"], six.get("waiting")), ("due", True))   # 6 days: wait
        old = rent("2026-11-18", {"HDFC": "2026-11-10T09:00:00"})
        self.assertEqual((old["state"], old.get("waiting")), ("due", True))   # 7 days, but no fetch after the due date
        self.assertEqual(rent("2026-11-18", {})["state"], "due")              # never fetched: wait
        fresh = rent("2026-11-18", {"HDFC": "2026-11-12T09:00:00"})
        self.assertEqual((fresh["state"], fresh["lateDays"]), ("late", 7))


class Dedupe(unittest.TestCase):
    def test_a_recurring_payment_matches_up_to_seven_days(self):
        from txdb import cashew_dedupe
        db = fake()
        db.execute("CREATE TABLE t2 AS SELECT rowid AS transaction_pk, * , '' AS note FROM transactions")
        db.execute("DROP TABLE transactions"); db.execute("ALTER TABLE t2 RENAME TO transactions")
        d = lambda day, amt: [{"date": day, "amount": amt, "account": "Axis", "id": day}]
        hit = d("2026-11-23", -1000); cashew_dedupe.mark(hit, db)               # 6 days from 2026-11-17 (paid row)
        self.assertTrue(hit[0].get("inCashew"))
        miss = d("2026-11-04", -50); cashew_dedupe.mark(miss, db)               # Coffee is not recurring: 3 days ok,
        self.assertTrue(miss[0].get("inCashew"))
        far = d("2026-11-07", -50); cashew_dedupe.mark(far, db)                 # 6 days on a normal row: no
        self.assertFalse(far[0].get("inCashew", False))
        eight = d("2026-11-25", -1000)
        for r in db.execute("SELECT 1"): pass
        db.execute("DELETE FROM transactions WHERE date_created = ?", (ts("2026-11-20"),))  # leave only the paid rows
        cashew_dedupe.mark(eight, db)                                            # 8 days from 2026-11-17: no
        self.assertFalse(eight[0].get("inCashew", False))

    def test_the_sync_never_writes_recurring_rows(self):
        import re
        src = "".join(Path(__file__).resolve().parents[1].joinpath("txdb", f).read_text()
                      for f in ("cashew.py", "cashew_file.py", "cashew_direct.py"))
        self.assertIsNone(re.search(r"(UPDATE|DELETE FROM)\s+transactions[^;]*type\s+IN", src, re.I))


if __name__ == "__main__":
    unittest.main()
