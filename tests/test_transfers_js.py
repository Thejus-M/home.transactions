"""collapseTransfers / monthSummary in Model.js, through node (same harness as the receipt tests)."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NODE = shutil.which("node")
SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


def tx(i, date, amount, **extra):
    row = {"id": i, "date": date, "amount": amount, "currency": "INR", "merchant": "X", "tracked": False}
    row.update(extra)
    return row


@unittest.skipUnless(NODE, "node is not installed")
class Harness(unittest.TestCase):
    def js(self, expression, **values):
        r = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expression],
                           capture_output=True, text=True, check=True)
        return json.loads(r.stdout)


class Collapse(Harness):
    PAIR = [tx("h", "2026-09-30", -20000, transferId="h>s", transferRole="out"),
            tx("o", "2026-09-30", -50),
            tx("s", "2026-09-30", 20000, transferId="h>s", transferRole="in")]

    def test_the_two_sides_become_one_entry_at_the_first_sides_place(self):
        out = self.js("collapseTransfers(input.rows, input.xs)", rows=self.PAIR,
                      xs=[{"id": "h>s", "matchedBy": "ref", "ref": "124028795174"}])
        self.assertEqual([e.get("isTransfer", False) for e in out], [True, False])
        t = out[0]
        self.assertEqual((t["out"]["id"], t["in"]["id"], t["amount"], t["ref"]), ("h", "s", 0, "124028795174"))
        self.assertEqual(out[1]["id"], "o")

    def test_one_side_filtered_away_stays_an_ordinary_row(self):
        out = self.js("collapseTransfers(input.rows, [])", rows=[self.PAIR[0], self.PAIR[1]])
        self.assertEqual([e["id"] for e in out], ["h", "o"])
        self.assertFalse(any(e.get("isTransfer") for e in out))

    def test_tracked_means_both_sides_are_tracked(self):
        rows = [dict(self.PAIR[0], tracked=True), dict(self.PAIR[2], tracked=False)]
        self.assertFalse(self.js("collapseTransfers(input.rows, [])", rows=rows)[0]["tracked"])
        rows[1]["tracked"] = True
        self.assertTrue(self.js("collapseTransfers(input.rows, [])", rows=rows)[0]["tracked"])

    def test_a_transfer_leg_does_not_count_in_a_days_net_even_when_shown_alone(self):
        rows = [tx("a", "2026-09-30", 15000, transferId="h>a", transferRole="in"), tx("o", "2026-09-30", -50)]
        groups = self.js("groupByDate(input.rows)", rows=rows)       # no collapse: the other side is filtered out
        self.assertEqual(groups[0]["total"], -50)

    def test_an_own_name_transfer_with_no_other_side_is_a_one_sided_entry_with_a_placeholder(self):
        rows = [tx("a", "2026-08-31", 14000, bank="AXIS", transferSelf=True, transferOther="HDFC"),
                tx("o", "2026-08-31", -50)]
        out = self.js("collapseTransfers(input.rows, [])", rows=rows)
        self.assertEqual([e.get("isTransfer", False) for e in out], [True, False])
        t = out[0]
        self.assertTrue(t["oneSided"])
        self.assertTrue(t["out"]["ghost"])                       # the missing sender
        self.assertEqual((t["out"]["bank"], t["in"]["id"]), ("HDFC", "a"))
        self.assertEqual(t["real"]["id"], "a")
        # a debit makes the placeholder the receiver
        rows = [tx("d", "2026-07-19", -4000, bank="AXIS", transferSelf=True, transferOther="HDFC")]
        t = self.js("collapseTransfers(input.rows, [])", rows=rows)[0]
        self.assertEqual((t["out"]["id"], t["in"]["ghost"]), ("d", True))

    def test_own_name_transfers_are_not_spending_or_income(self):
        rows = [tx("a", "2026-09-30", 14000, transferSelf=True), tx("o", "2026-09-30", -50)]
        s = self.js("monthSummary(input.rows, '2026-09-30')", rows=rows)
        self.assertEqual((s["spent"], s["income"]), (50, 0))

    def test_a_transfer_adds_nothing_to_a_days_total_or_the_month_summary(self):
        groups = self.js("groupByDate(collapseTransfers(input.rows, []))", rows=self.PAIR)
        self.assertEqual(groups[0]["total"], -50)
        summary = self.js("monthSummary(input.rows, '2026-09-30')", rows=self.PAIR)
        self.assertEqual((summary["spent"], summary["income"]), (50, 0))


if __name__ == "__main__":
    unittest.main()
