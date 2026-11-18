"""The chip line of RECENT: the Recurring / Receipts tabs and the Cashew control (Model.js)."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")
SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


@unittest.skipUnless(NODE, "node is not installed")
class Chips(unittest.TestCase):
    def js(self, expression, **values):
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expression],
                             capture_output=True, text=True, check=True)
        return json.loads(out.stdout)

    def test_drawer_toggle_and_restore(self):
        t = lambda c, p: self.js("drawerToggle(input.c, input.p)", c=c, p=p)
        self.assertEqual(t("", "recurring"), "recurring")
        self.assertEqual(t("recurring", "receipts"), "receipts")
        self.assertEqual(t("receipts", "receipts"), "")
        self.assertEqual(t("receipts", "junk"), "")
        r = lambda j: self.js("drawerRestore(input.j)", j=j)
        self.assertEqual(r('{"drawer": "receipts"}'), "receipts")
        self.assertEqual(r('{"drawer": "bogus"}'), "")
        self.assertEqual(r('{}'), "")
        self.assertEqual(r("not json"), "")
        self.assertEqual(r("null"), "")

    def test_the_filter_file_keeps_the_open_tab(self):
        saved = self.js("serializeFilter(defaultFilter(), 'recurring')")
        self.assertEqual(json.loads(saved)["drawer"], "recurring")
        self.assertNotIn("drawer", json.loads(self.js("serializeFilter(defaultFilter(), '')")))
        self.assertEqual(self.js("drawerRestore(input.s)", s=saved), "recurring")
        self.assertEqual(self.js("JSON.stringify(restoreFilter(input.s, [])) === JSON.stringify(defaultFilter())", s=saved), True)

    def test_chips(self):
        rec = [{"active": True, "amount": "-1000.00", "every": 1, "unit": "month", "state": "late"},
               {"active": True, "amount": "-500.00", "every": 1, "unit": "month", "state": "due"},
               {"active": False, "amount": "-9.00", "every": 1, "unit": "month", "state": "late"}]
        c = self.js("recurringChip(input.l)", l=rec)
        self.assertEqual((c["count"], c["late"], c["lateCount"], c["dim"]), (2, True, 1, False))
        self.assertIn("1 not seen in bank", c["tooltip"])
        e = self.js("recurringChip([])")
        self.assertEqual((e["count"], e["dim"], e["late"]), (0, True, False))
        r = self.js("receiptsChip(input.r)", r=[{"state": "unmatched"}, {"state": "linked"}, {"state": "cash"}])
        self.assertEqual((r["count"], r["filed"], r["dim"], r["tooltip"]), (1, 2, False, "1 to link · 2 linked"))

    def test_cashew_control_states_and_the_old_tooltips(self):
        c = lambda s, run=False: self.js("cashewControl(input.s, input.r)", s=s, r=run)
        err = c({"error": "no copy"})
        self.assertEqual((err["glyph"], err["tone"], err["tooltip"]), ("!", "error", "Sync: no copy"))
        fix = c({"recatWaiting": "/x.sql", "pending": 0})
        self.assertEqual((fix["tone"], fix["badge"]), ("pending", "fix"))
        pend = c({"pending": 12, "rows": 10, "notes": 2, "transfers": 1, "corrections": [{}], "waitingCategory": 3})
        self.assertEqual((pend["tone"], pend["badge"]), ("pending", "12"))
        self.assertEqual(pend["tooltip"], "10 rows not in Cashew yet (1 transfers), 2 notes for rows Cashew has, "
                                          "1 balance corrections. Click: send them to Cashew and sync (no window).\n3 more need a category first.")
        ok = c({"pending": 0, "waitingCategory": 0})
        self.assertEqual((ok["tone"], ok["badge"], ok["tooltip"]), ("ok", "", "Cashew is up to date. Nothing to sync."))
        busy = c({"pending": -1}, True)
        self.assertEqual((busy["tone"], busy["spin"], busy["tooltip"]), ("busy", True, "Checking…"))
        self.assertEqual(self.js("cashewOpenTooltip(3)"), "Send 3 transactions to Cashew")

    def test_cashew_mark(self):
        m = lambda t, e: self.js("cashewMark(input.t, input.e)", t=t, e=e)
        self.assertEqual(m({"inCashew": False}, False)["glyph"], "")
        self.assertEqual((m({"inCashew": True}, False)["tone"], m({"inCashew": True}, False)["tooltip"]), ("ok", "In Cashew"))
        e = m({"inCashew": True}, True)
        self.assertEqual((e["tone"], e["glyph"]), ("pending", "\U000F04E6"))

    def test_empty_drawer_texts(self):
        e = lambda t, **k: self.js("drawerEmptyText(input.t, input.k)", t=t, k=k)
        self.assertEqual(e("receipts", toLink=0, filed=0), "No receipts to link")
        self.assertEqual(e("receipts", toLink=0, filed=40, showFiled=False), "No receipts to link · 40 linked hidden")
        self.assertEqual(e("receipts", toLink=0, filed=40, showFiled=True), "")
        self.assertEqual(e("receipts", toLink=2), "")
        self.assertEqual(e("recurring", series=0), "No recurring payments in Cashew")
        self.assertEqual(e("recurring", series=5, active=0, showEnded=False), "No active recurring payments")
        self.assertEqual(e("recurring", series=5, active=2), "")
        self.assertEqual(e("", series=0), "")


if __name__ == "__main__":
    unittest.main()
