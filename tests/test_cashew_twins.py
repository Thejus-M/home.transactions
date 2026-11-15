"""Income twins (txdb/cashew_twins.py): a refund is income in "the same category" by the id of an income category
that has the expense category's name. Cashew ignores the sign in a link and takes income/expense from the
category type, so the name alone ("Shopping") would find the expense category and show the refund as spend."""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from txdb import cashew, cashew_twins, refunds  # noqa: E402
import test_cashew_refunds as R  # noqa: E402
import test_cashew_parity as P  # noqa: E402


def fake_backup(path):
    """The part of a Cashew backup that matters: the categories table."""
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE categories (category_pk TEXT PRIMARY KEY, name TEXT, income INTEGER, main_category_pk TEXT)")
    c.executemany("INSERT INTO categories VALUES (?,?,?,?)", [
        ("e-shop", "Shopping", 0, None), ("e-foot", "Footwear", 0, "e-shop"),
        ("i-shop", "Shopping", 1, None), ("i-foot", "Footwear", 1, "i-shop"), ("i-cloth", "Clothing", 1, "i-shop"),
        ("i-sal", "Salary", 1, None),
    ])
    c.commit()
    c.close()


class Backup(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.backup = Path(self.dir.name) / "cashew.sql"
        fake_backup(self.backup)

    def tearDown(self):
        self.dir.cleanup()

    def test_only_the_income_categories_are_read_with_their_sub_categories(self):
        twins = cashew_twins.read_backup(self.backup)
        self.assertEqual(set(twins), {"Shopping", "Salary"})
        self.assertEqual(twins["Shopping"], {"pk": "i-shop", "subs": {"Footwear": "i-foot", "Clothing": "i-cloth"}})

    def test_lookup_gives_the_ids_and_none_for_a_missing_twin(self):
        twins = cashew_twins.read_backup(self.backup)
        self.assertEqual(cashew_twins.lookup(twins, "Shopping", "Footwear"), ("i-shop", "i-foot"))
        self.assertEqual(cashew_twins.lookup(twins, "Shopping", "Nope"), ("i-shop", ""))
        self.assertEqual(cashew_twins.lookup(twins, "Shopping", ""), ("i-shop", ""))
        self.assertIsNone(cashew_twins.lookup(twins, "Travel", "Stay"))

    def test_a_file_that_is_not_a_backup_is_refused(self):
        junk = Path(self.dir.name) / "junk.txt"
        junk.write_text("hello")
        with self.assertRaises(ValueError):
            cashew_twins.read_backup(junk)

    def test_save_and_load_round_trip_and_a_missing_file_is_empty(self):
        twins = cashew_twins.read_backup(self.backup)
        target = Path(self.dir.name) / "twins.json"
        cashew_twins.save(twins, target)
        self.assertEqual(cashew_twins.load(target), twins)
        self.assertEqual(cashew_twins.load(Path(self.dir.name) / "none.json"), {})


class Export(R.Base):
    def setUp(self):
        super().setUp()
        self.tw = Path(self.dir.name) / "twins.json"
        backup = Path(self.dir.name) / "cashew.sql"
        fake_backup(backup)
        cashew_twins.save(cashew_twins.read_backup(backup), self.tw)
        os.environ["TXDB_CASHEW_TWINS"] = str(self.tw)

    def tearDown(self):
        os.environ.pop("TXDB_CASHEW_TWINS", None)
        super().tearDown()

    def test_the_refund_goes_to_the_income_twin_by_id_and_keeps_the_category_name_for_display(self):
        refunds.set_link(self.conn, self.back, self.out, mode="income")
        credit = self.drafts()[self.back]
        self.assertEqual((credit["category"], credit["subcategory"]), ("Shopping", "Footwear"))     # the same category
        self.assertEqual((credit["categoryPk"], credit["subcategoryPk"]), ("i-shop", "i-foot"))
        self.assertEqual((credit["refundCategory"], credit["refundSubcategory"]), ("Shopping", "Footwear"))
        self.assertEqual(credit["amount"], "3816.00")

    def test_the_link_has_the_ids_not_the_names_and_no_warning(self):
        refunds.set_link(self.conn, self.back, self.out, mode="income")
        out = cashew.build_links([x for x in self.drafts().values() if x["id"] in (self.out, self.back)])
        self.assertEqual(out["warnings"], [])
        entries = {e["amount"]: e for e in json.loads(urllib.parse.unquote(out["links"][0]["url"].split("JSON=")[1]))["transactions"]}
        refund, purchase = entries["3816.00"], entries["-3816.00"]
        self.assertEqual((refund["categoryPk"], refund["subcategoryPk"]), ("i-shop", "i-foot"))
        self.assertNotIn("category", refund)                       # a name would find the EXPENSE Shopping
        self.assertEqual((purchase["category"], purchase["subcategory"]), ("Shopping", "Footwear"))
        self.assertNotIn("categoryPk", purchase)

    def test_without_a_twin_the_refund_falls_back_to_the_refund_category(self):
        cashew_twins.save({}, self.tw)
        refunds.set_link(self.conn, self.back, self.out, mode="income")
        credit = self.drafts()[self.back]
        self.assertEqual((credit["category"], credit["subcategory"]), cashew.REFUND_CATEGORY)
        self.assertNotIn("categoryPk", credit)
        self.assertEqual(credit["refundCategory"], "Shopping")     # still known, for `txdb cashew-twins`


class CommandLine(R.Base):
    def run_cli(self, *args):
        env = dict(os.environ, TXDB_DB=str(self.path), TXDB_CASHEW_TWINS=str(Path(self.dir.name) / "twins.json"),
                   TXDB_CASHEW_STATE=str(Path(self.dir.name) / "state.json"))
        return subprocess.run([sys.executable, str(ROOT / "bin/txdb"), *args], env=env, capture_output=True, text=True)

    def test_it_lists_the_missing_twin_then_reads_the_backup_then_says_ready_and_makes_a_test_link(self):
        refunds.set_link(self.conn, self.back, self.out, mode="income")
        self.conn.commit()
        cashew.save_state(self.state, Path(self.dir.name) / "state.json")      # the purchase is filed under Shopping
        first = self.run_cli("cashew-twins")
        self.assertIn("Shopping", first.stdout)
        self.assertIn("MISSING", first.stdout)
        backup = Path(self.dir.name) / "cashew.sql"
        fake_backup(backup)
        done = self.run_cli("cashew-twins", "--backup", str(backup), "--test-link")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("ready", done.stdout)
        link = [ln for ln in done.stdout.splitlines() if ln.startswith("https://")][0]
        entry = json.loads(urllib.parse.unquote(link.split("JSON=")[1]))["transactions"][0]
        self.assertEqual((entry["categoryPk"], entry["subcategoryPk"]), ("i-shop", "i-foot"))
        self.assertEqual(self.run_cli("cashew-twins", "--backup", str(Path(self.dir.name) / "nope")).returncode, 2)


class TwinParity(P.Parity):
    """The JS builder gives the same entry as the Python one for a refund sent by twin id."""

    def test_twin_entries(self):
        drafts = [
            P.d(1, kind="refund", amount="3816.00", category="Shopping", subcategory="Footwear", categoryPk="i-shop",
                subcategoryPk="i-foot", refundOf="x", refundMode="income", title="Refund: Flipkart"),
            P.d(2, kind="refund", amount="5.00", category="Shopping", subcategory="Clothing", categoryPk="i-shop",
                refundOf="x"),                                                  # twin without that sub-category
            P.d(3, kind="income", amount="10.00", category="Shopping", subcategory="Footwear"),   # no id: warns
        ]
        py = self.both(drafts)
        self.assertEqual(len([w for w in py["warnings"] if "does not fit" in w]), 1)


for _name in [n for n in dir(P.Parity) if n.startswith("test_")]:
    setattr(TwinParity, _name, None)
for _name in [n for n in dir(R.Base) if n.startswith("test_")]:
    pass


if __name__ == "__main__":
    unittest.main()
