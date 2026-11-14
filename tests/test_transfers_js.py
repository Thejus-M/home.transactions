"""collapseTransfers / monthSummary in Model.js, through node (same harness as the receipt tests)."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

_Y = "" if __import__("datetime").date.today().year == 2026 else "-26"   # formatDate drops the current year

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


class Explain(Harness):
    def entry(self, **extra):
        out = tx("h", "2026-09-30", -20000, bank="HDFC")
        inn = tx("s", "2026-09-30", 20000, bank="SBI")
        e = {"isTransfer": True, "id": "h>s", "out": out, "in": inn, "matchedBy": "ref",
             "ref": "124028795174", "matchedAt": "2026-11-08T10:00:00"}
        e.update(extra)
        return e

    def explain(self, e, ctx=None):
        return self.js("transferExplain(input.e, input.ctx)", e=e, ctx=ctx or {})

    def test_kinds_and_meta(self):
        self.assertEqual(self.js("transferKind(input.e)", e=self.entry()), "ref")
        self.assertEqual(self.js("transferKind(input.e)", e=self.entry(matchedBy="card")), "card")
        self.assertEqual(self.js("transferKind(input.e)", e=self.entry(matchedBy="self")), "self")
        self.assertEqual(self.js("transferKind(input.e)", e=self.entry(oneSided=True)), "missing")
        self.assertEqual(self.js("transferKind(input.e)", e=tx("a", "2026-09-30", 5, transferId="h>a")), "lone")
        self.assertEqual(self.js("transferKind(input.e)", e=tx("a", "2026-09-30", 5)), "")
        m = self.js("transferMeta('missing')")
        self.assertEqual((m["tag"], m["pips"], m["tone"]), ("ONE SIDE MISSING", 1, "amber"))
        self.assertEqual(self.js("transferMeta('lone')")["pips"], 0)

    def test_same_reference(self):
        r = self.explain(self.entry())
        self.assertEqual((r["title"], r["certainty"]), ("SAME REFERENCE", "very sure"))
        rows = {x["k"]: x["v"] for x in r["rows"]}
        self.assertEqual(rows["Matched by"], "UPI reference 1240 2879 5174")
        self.assertEqual(rows["Matched on"], "08-Nov" + _Y)
        self.assertEqual(rows["OUT"], "30-Sep" + _Y + "  HDFC  -\u20b920,000")
        self.assertEqual(rows["IN"], "30-Sep" + _Y + "  SBI  +\u20b920,000")
        self.assertEqual(r["why"], "Both sides carry the same UPI reference.")

    def test_null_matched_at_omits_the_row(self):
        r = self.explain(self.entry(matchedAt=None))
        self.assertNotIn("Matched on", [x["k"] for x in r["rows"]])

    def test_card_bill(self):
        r = self.explain(self.entry(matchedBy="card", ref=None))
        self.assertEqual((r["title"], r["certainty"]), ("CARD BILL", "sure"))
        self.assertEqual(r["rows"][0]["v"], "amount, date and payment words")
        self.assertEqual(r["why"], "A bank account paid your credit card.")

    def test_own_name(self):
        r = self.explain(self.entry(matchedBy="self", ref=None))
        self.assertEqual((r["title"], r["certainty"]), ("OWN NAME", "fairly sure"))
        self.assertEqual(r["rows"][0]["v"], "your name, same amount, 1 day or less, banks agree")
        self.assertEqual(r["why"], "No shared reference exists. Your own name and the amount match.")

    def missing(self, other="HDFC"):
        rows = [tx("a", "2026-10-05", 14000, bank="AXIS", transferSelf=True, transferOther=other)]
        return self.js("collapseTransfers(input.rows, [])[0]", rows=rows)

    def test_missing_side_next_step_without_a_later_fetch(self):
        r = self.explain(self.missing(), {"lastFetched": {"HDFC": "2026-10-01T09:00:00"}})
        self.assertEqual((r["title"], r["certainty"]), ("ONE SIDE MISSING", "a guess"))
        rows = {x["k"]: x["v"] for x in r["rows"]}
        self.assertEqual(rows["Missing"], "HDFC side (-\u20b914,000 around 05-Oct" + _Y + ")")
        self.assertEqual(r["why"], "The other account is not in your data. HDFC was last fetched 01-Oct" + _Y + ".")
        self.assertEqual(r["next"], "Fetch HDFC again. This will pair by itself.")

    def test_missing_side_next_step_after_a_later_fetch(self):
        r = self.explain(self.missing(), {"lastFetched": {"HDFC": "2026-10-20T16:01:36"}})
        self.assertEqual(r["next"], "That fetch did not include this transfer. It may be older than the statement.")

    def test_missing_side_never_fetched_and_unknown_bank(self):
        self.assertIn("last fetched never.", self.explain(self.missing(), {"lastFetched": {}})["why"])
        r = self.explain(self.missing(None))
        self.assertTrue(r["rows"][1]["v"].startswith("Another account ("))
        self.assertEqual(r["next"], "Fetch the other account again. This will pair by itself.")

    def test_lone_leg(self):
        r = self.explain(tx("a", "2026-09-30", 5, transferId="h>a", transferPeerBank="HDFC"), {"accountTag": "SBI ••1234"})
        self.assertEqual(r["title"], "ONE LEG SHOWN")
        self.assertEqual(r["why"], "The other side is hidden by a filter. Clear the filter to see both sides.")
        self.assertEqual(r["rows"][0], {"k": "Other side", "v": "HDFC"})

    def test_ordinary_row_without_a_reference(self):
        t = tx("a", "2026-09-30", -50, merchant="UPI-SHOP-9988@ybl-HDFC-123456789012-Tea", accountType="checking",
               counterparty="Shop", tracked=True)
        r = self.js("txnExplain(input.t, input.ctx)", t=t, ctx={"accountTag": "••1234", "receiptMerchant": "Shop Ltd"})
        keys = [x["k"] for x in r["rows"]]
        self.assertNotIn("Reference", keys)
        self.assertEqual(r["title"], "Transaction")
        rows = {x["k"]: x["v"] for x in r["rows"]}
        self.assertEqual(rows["Counterparty"], "Shop")
        self.assertEqual(rows["Account"], "••1234  savings")
        self.assertEqual(rows["Status"], "Tracked  Receipt: Shop Ltd")
        t["reference"] = "124028795174"
        r = self.js("txnExplain(input.t, {})", t=t)
        self.assertIn({"k": "Reference", "v": "1240 2879 5174"}, r["rows"])

    def test_group_ref_and_matched_on(self):
        self.assertEqual(self.js("groupRef('124028795174')"), "1240 2879 5174")
        self.assertEqual(self.js("groupRef('12345')"), "1234 5")
        self.assertEqual(self.js("formatMatchedOn(null)"), "")

    def test_collapse_carries_the_new_fields(self):
        rows = [tx("h", "2026-09-30", -5, bank="HDFC", transferId="h>s"), tx("s", "2026-09-30", 5, bank="SBI", transferId="h>s")]
        xs = [{"id": "h>s", "matchedBy": "ref", "certainty": 3, "matchedAt": "2026-11-08T10:00:00",
               "isNew": True, "outBank": "HDFC", "inBank": "SBI"}]
        e = self.js("collapseTransfers(input.rows, input.xs)[0]", rows=rows, xs=xs)
        self.assertEqual((e["certainty"], e["isNew"], e["outBank"], e["matchedAt"]), (3, True, "HDFC", "2026-11-08T10:00:00"))


if __name__ == "__main__":
    unittest.main()
