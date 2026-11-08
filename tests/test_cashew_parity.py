"""Parity: Model.js cashewBuildLinks must give the same links and warnings as
txdb/cashew.py build_links (url, count, chars, ids, json, warnings)."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from txdb import cashew, db, ingest  # noqa: E402
from test_cashew import SBI_OUT, HDFC_IN, row  # noqa: E402

NODE = shutil.which("node")
SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
const i = JSON.parse(fs.readFileSync(0, "utf8"));
ctx.i = i;
console.log(JSON.stringify(vm.runInContext("cashewBuildLinks(i.drafts, i.shown, i.max, i.cats)", ctx)));
"""


def d(i, **kw):
    x = {"id": f"d{i:04d}", "include": True, "date": "2026-10-01", "title": f"T{i}", "amount": "-10.00",
         "category": "Food Out", "subcategory": "Others", "account": "HDFC", "notes": "n", "kind": "spend",
         "pairId": ""}
    x.update(kw)
    return x


@unittest.skipUnless(NODE, "node is not installed")
class Parity(unittest.TestCase):
    def both(self, drafts, max_chars=6000):
        cats = cashew.load_categories()
        py = cashew.build_links(drafts, max_chars)
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js")],
                             input=json.dumps({"drafts": drafts, "shown": None, "max": max_chars, "cats": cats}),
                             capture_output=True, text=True, check=True).stdout
        js = json.loads(out)
        self.assertEqual(len(js["links"]), len(py["links"]))
        for a, b in zip(js["links"], py["links"]):
            for k in ("url", "count", "chars", "ids", "json"):
                self.assertEqual(a[k], b[k], k)
        self.assertEqual(js["warnings"], py["warnings"])
        return py

    def test_special_characters_and_exclusion(self):
        drafts = [
            d(1, title="50% off & more + # 'x' (y) *z* ! ~ ~", notes="line1\nline2\t\"q\" \\ \u007f",
              account="HDFC ₹", subcategory="Sub%"),
            d(2, title="Tree \U0001F333 emoji ₹", date="2026-09-30", notes="•• 5%"),
            d(3, include=False, title="excluded"),
            d(4, title="x" * 300, notes="y" * 600),
            d(5, category="Uncategorized", subcategory="Unknown"),
            d(6, category="Salary", amount="-5.00"),
            d(7, title="Transfer to SBI", category="Balance Correction", subcategory="", kind="transfer", pairId="p1"),
            d(8, title="Transfer from HDFC", category="Balance Correction", subcategory="", kind="transfer",
              pairId="p1", amount="10.00"),
            d(9, title="lonely", category="Balance Correction", kind="transfer", pairId="p9"),
            d(10, title="nopair", category="Balance Correction", kind="transfer", pairId=""),
            d(11, title="a'b", category="Nope"),
            d(12, title="\U0001F333" * 260, notes="\U0001F333" * 510),
            d(13, notes="MF and RD\n\u2022 1 \u00d7 Tea \u2014 \u20b910\nTotal \u20b910.50 100%\n"),
            d(14, notes=""),
        ]
        py = self.both(drafts)
        self.assertTrue(py["warnings"])

    def test_chunking_keeps_pairs_together(self):
        drafts = [d(i, date=f"2026-10-{(i % 9) + 1:02d}") for i in range(30)]
        drafts += [d(100, kind="transfer", pairId="pp", category="Balance Correction", title="A"),
                   d(101, kind="transfer", pairId="pp", category="Balance Correction", title="B", amount="10.00")]
        for mx in (300, 800, 1500, 2500, 6000, 50):
            py = self.both(drafts, mx)
        small = cashew.build_links(drafts, 800)
        self.assertGreater(len(small["links"]), 3)
        for lk in small["links"]:
            self.assertEqual(("d0100" in lk["ids"]), ("d0101" in lk["ids"]))

    def test_shown_filter_equals_exclusion(self):
        drafts = [d(i) for i in range(6)]
        cats = cashew.load_categories()
        shown = [1, 3, 4]
        expect = cashew.build_links([x if i in shown else {**x, "include": False} for i, x in enumerate(drafts)])
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js")],
                             input=json.dumps({"drafts": drafts, "shown": shown, "max": 6000, "cats": cats}),
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(out)["links"][0]["url"], expect["links"][0]["url"])

    def test_empty(self):
        self.both([])
        self.both([d(1, include=False)])

    def test_live_shaped_drafts_from_a_temporary_db(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = db.connect(Path(tmp) / "t.db")
            hdfc = ingest.ensure_account(conn, "HDFC", "checking", "7367")
            sbi = ingest.ensure_account(conn, "SBI", "checking", "9373")
            ingest.upsert_rows(conn, sbi, [row(1, "2026-10-05", -50000, SBI_OUT)])
            ingest.upsert_rows(conn, hdfc, [row(2, "2026-10-05", 50000, HDFC_IN)] +
                               [row(10 + i, f"2026-10-{(i % 27) + 1:02d}", -(100 + i) * 100,
                                    f"UPI-SHOP {i} 100%&+#'(*") for i in range(120)])
            conn.commit()
            ro = cashew.open_readonly(Path(tmp) / "t.db")
            try:
                drafts = cashew.drafts(ro)
            finally:
                ro.close()
            conn.close()
        self.assertGreater(len(drafts), 100)
        for mx in (6000, 2000):
            self.both(drafts, mx)


if __name__ == "__main__":
    unittest.main()
