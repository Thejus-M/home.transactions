"""txdb/cashew_recat.py: fixing the categories of rows already in Cashew."""
import csv
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_recat  # noqa: E402
from test_cashew_file import COLS  # noqa: E402

CAT_COLS = ["category_pk", "name", "colour", "icon_name", "emoji_icon_name", "date_created", "date_time_modified",
            "order", "income", "method_added", "main_category_pk", "archived"]
CATS = [  # pk, name, income, main
    ("0", "Balance Correction", 0, None), ("c-sal", "Salary", 1, None), ("s-bonus", "Bonus", 1, "c-sal"),
    ("c-shop", "Shopping", 0, None), ("s-lux", "Luxury", 0, "c-shop"), ("c-unc", "Uncategorized", 0, None),
    ("c-gro", "Groceries", 0, None), ("s-prov", "Provisions", 0, "c-gro"), ("c-tr", "Transport", 0, None),
    ("s-transit", "Transit", 0, "c-tr"), ("c-fr", "Friend Settlements", 1, None), ("s-rec", "Received", 1, "c-fr"),
    ("s-set", "Settle", 1, "c-fr")]


def ts(day):
    return int(datetime.strptime(day, "%Y-%m-%d").timestamp())


def fake(path):
    c = sqlite3.connect(path)
    c.execute(f"CREATE TABLE categories ({', '.join(chr(34) + k + chr(34) for k in CAT_COLS)})")
    for pk, name, inc, main in CATS:
        c.execute("INSERT INTO categories VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                  (pk, name, "0xff607d8b", "charts.png", None, 1, 1, 5, inc, None, main, 0))
    c.execute("CREATE TABLE wallets (wallet_pk TEXT PRIMARY KEY, name TEXT)")
    c.execute("INSERT INTO wallets VALUES ('0', 'HDFC')")
    c.execute(f"CREATE TABLE transactions ({', '.join(COLS)})")
    rows = [  # pk, name, note, amount, cat, sub, income
        ("bonus", "", "", 150.0, "c-sal", "s-bonus", 1),
        ("bigbonus", "", "", 50000.0, "c-sal", "s-bonus", 1),
        ("salout", "Settle", "", -300.0, "c-sal", "s-bonus", 0),
        ("emi", "Principle for emi", "", -9000.0, "c-shop", "s-lux", 0),
        ("gst", "IGST", "", -80.0, "c-shop", "s-lux", 0),
        ("phone", "Phone", "", -90000.0, "c-shop", "s-lux", 0),
        ("lux", "", "", -31000.0, "c-shop", "s-lux", 0),
        ("self", "Thejus M Manoj", "", -5000.0, "c-unc", None, 0),
        ("unk", "", "", -77.0, "c-unc", None, 0),
        ("milk", "Milk", "", -30.0, "c-gro", "s-prov", 0),
        ("basket", "Kunnil Marginfree Hypermarket", "• 1 × Milk", -900.0, "c-gro", "s-prov", 0),
        ("train", "Train Ticket", "", -120.0, "c-tr", "s-transit", 0),
        ("frbad", "ASHWIN", "BATMINTON", 75.0, "c-fr", "s-rec", 1),
    ]
    for pk, name, note, amount, cat, sub, inc in rows:
        r = {k: None for k in COLS}
        r.update(transaction_pk=pk, name=name, note=note, amount=amount, category_fk=cat, sub_category_fk=sub,
                 wallet_fk="0", date_created=ts("2026-11-01"), date_time_modified=1, income=inc, paid=1)
        c.execute(f"INSERT INTO transactions VALUES ({', '.join('?' * len(COLS))})", [r[k] for k in COLS])
    c.commit()
    c.close()


class Recat(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.base = self.root / "base.sqlite"
        fake(self.base)

    def tearDown(self):
        self.dir.cleanup()

    def moves(self):
        conn = sqlite3.connect(self.base)
        try:
            return {m["pk"]: m for m in cashew_recat.plan(conn)}
        finally:
            conn.close()

    def test_plan(self):
        m = self.moves()
        to = {pk: (x["to"], x["confidence"]) for pk, x in m.items()}
        self.assertEqual(to["bonus"], ("Friend Settlements > Received", "guess"))
        self.assertEqual(to["bigbonus"], ("", "ask"))                                 # a real bonus? ask
        self.assertEqual(to["salout"], ("Friend Settlements > Settle", "guess"))
        self.assertEqual(to["emi"], ("Loans & EMI > Principal", "rule"))
        self.assertEqual(to["gst"], ("Loans & EMI > Fees & GST", "rule"))
        self.assertEqual(to["phone"], ("Shopping > Electronics", "rule"))
        self.assertEqual(to["lux"], ("", "ask"))
        self.assertEqual(to["self"], ("Balance Correction", "rule"))
        self.assertEqual(to["unk"], ("", "ask"))
        self.assertEqual(to["milk"], ("Groceries > Dairy & Bakery", "rule"))
        self.assertEqual(to["train"], ("Transport > Bus/Metro/Train", "rule"))
        self.assertNotIn("basket", to)                     # a supermarket stays Provisions (its note lists milk)
        self.assertNotIn("frbad", to)                      # friend money stays Friend Settlements
        self.assertEqual(m["bigbonus"]["apply"], "no")

    def test_apply_moves_only_the_category_and_adds_what_is_missing(self):
        conn = sqlite3.connect(self.base)
        moves = cashew_recat.plan(conn)
        conn.close()
        plan_csv, plan_md = self.root / "p.csv", self.root / "p.md"
        cashew_recat.write_plan(moves, plan_csv, plan_md)
        self.assertIn("Needs your answer", plan_md.read_text())
        rows = list(csv.DictReader(open(plan_csv, encoding="utf-8")))
        for r in rows:
            if r["pk"] == "phone":
                r["apply"] = "no"                                             # the person strikes one out
        with open(plan_csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
        c = sqlite3.connect(self.base)                                         # changed in Cashew after the plan
        c.execute("UPDATE transactions SET category_fk = 'c-shop', sub_category_fk = NULL WHERE transaction_pk = 'train'")
        c.commit()
        c.close()
        out = self.root / "out.sql"
        r = cashew_recat.apply(self.base, plan_csv, out)
        self.assertEqual(r["moved"], 6)                      # bonus, salout, emi, gst, self, milk: not phone, not train
        self.assertEqual([s["pk"] for s in r["skipped"]], ["train"])
        self.assertEqual(sorted(r["addedCategories"]), ["Dairy & Bakery", "Fees & GST", "Loans & EMI", "Principal"])
        db = sqlite3.connect(out)
        db.row_factory = sqlite3.Row
        self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(db.execute("SELECT count(*) FROM transactions").fetchone()[0], 13)
        get = lambda pk: dict(db.execute("SELECT * FROM transactions WHERE transaction_pk = ?", (pk,)).fetchone())
        cat = lambda pk: db.execute("SELECT name FROM categories WHERE category_pk = ?", (pk,)).fetchone()[0]
        self.assertEqual((cat(get("emi")["category_fk"]), cat(get("emi")["sub_category_fk"])), ("Loans & EMI", "Principal"))
        self.assertEqual((get("self")["category_fk"], get("self")["sub_category_fk"]), ("0", None))
        self.assertEqual((get("bonus")["category_fk"], get("bonus")["income"], get("bonus")["amount"]), ("c-fr", 1, 150.0))
        self.assertEqual(get("phone")["sub_category_fk"], "s-lux")                       # struck out: unchanged
        loans = db.execute("SELECT * FROM categories WHERE name = 'Loans & EMI'").fetchone()
        self.assertEqual((loans["icon_name"], loans["colour"], loans["income"], loans["main_category_pk"]),
                         ("loan.png", "0xff6a4c93", 0, None))
        self.assertTrue(cashew_recat.imported(db, r["probe"]))
        self.assertFalse(cashew_recat.imported(sqlite3.connect(self.base), r["probe"]))


if __name__ == "__main__":
    unittest.main()
