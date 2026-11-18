"""Model.js date helpers: weekday always, a fixed today, missing dates, local month."""
import json
import os
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
console.log(JSON.stringify(vm.runInContext(process.argv[2], ctx)));
"""


@unittest.skipUnless(NODE, "node is not installed")
class Dates(unittest.TestCase):
    def js(self, expr, tz="Asia/Kolkata"):
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), expr], capture_output=True, text=True,
                             check=True, env=dict(os.environ, TZ=tz))
        return json.loads(out.stdout)

    def test_weekday_always(self):
        self.assertEqual(self.js("dateGroupLabel('2026-11-18', '2026-11-18')"), "Today · Wednesday, 18-Nov")
        self.assertEqual(self.js("dateGroupLabel('2026-11-17', '2026-11-18')"), "Yesterday · Tuesday, 17-Nov")
        self.assertEqual(self.js("dateGroupLabel('2026-10-03', '2026-11-18')"), "Saturday, 03-Oct")

    def test_missing_date_does_not_throw(self):
        self.assertEqual(self.js("dateGroupLabel(undefined, '2026-11-18')"), "No date")
        self.assertEqual(self.js("formatRelativeDate(null)"), "")
        self.assertEqual(self.js("groupByDate([{date: undefined, amount: -1, currency: 'INR'}], '2026-11-18')[0].label"), "No date")

    def test_month_summary_uses_the_given_day(self):
        rows = "[{date: '2026-12-01', amount: -100, currency: 'INR'}, {date: '2026-11-30', amount: -5, currency: 'INR'}]"
        self.assertEqual(self.js(f"monthSummary({rows}, '2026-12-01').spent"), 100)


class TransfersUnderFilters(unittest.TestCase):
    def test_one_leg_through_a_filter_still_folds(self):
        rows = ("[{id:'h',date:'2026-09-30',amount:-500,currency:'INR',merchant:'X',transferId:'h>s'},"
                "{id:'s',date:'2026-09-30',amount:500,currency:'INR',merchant:'X',transferId:'h>s'}]")
        got = Dates().js(f"(function(){{var all={rows}; return collapseTransfers(all.filter(function(t){{return t.amount>0}}), [], all)}})()")
        self.assertEqual((len(got), got[0].get("isTransfer")), (1, True))


if __name__ == "__main__":
    unittest.main()
