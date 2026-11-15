"""The Cashew verify window's pure helpers in Model.js, run through node
(same vm harness as test_filter_js.py)."""
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

CATS = [
    {"name": "Balance Correction", "type": "balance", "subcategories": []},
    {"name": "Salary", "type": "income", "subcategories": ["Monthly"]},
    {"name": "Food Out", "type": "expense", "subcategories": ["Lunch"]},
    {"name": "Uncategorized", "type": "balance", "subcategories": ["Unknown"]},
]


def draft(id, amount="-100.00", group="g1", kind="spend", account_id="a1", **extra):
    d = {"id": id, "include": True, "date": "2026-11-01", "title": "T", "amount": amount,
         "category": "Uncategorized", "subcategory": "Unknown", "account": "", "notes": "",
         "kind": kind, "groupKey": group, "accountId": account_id}
    d.update(extra)
    return d


@unittest.skipUnless(NODE, "node is not installed")
class CashewJs(unittest.TestCase):
    def js(self, expression, **values):
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expression],
                             capture_output=True, text=True, check=True)
        return json.loads(out.stdout)

    def test_categories_follow_the_sign(self):
        names = lambda a: [c["name"] for c in self.js("cashewCategoriesFor(input.c, input.a)", c=CATS, a=a)]
        self.assertEqual(names("-5.00"), ["Balance Correction", "Food Out", "Uncategorized"])
        self.assertEqual(names("5.00"), ["Balance Correction", "Salary", "Uncategorized"])

    def test_a_stale_shown_index_does_not_throw(self):
        # While the window reloads, `shown` can still hold indexes of the old drafts.
        ds = [{"id": "a", "include": True}]
        self.assertEqual(self.js("cashewIncluded(input.d, input.s)", d=ds, s=[0, 5, 9]), [{"id": "a", "include": True}])

    def test_patch_returns_new_array_and_keeps_others(self):
        ds = [draft("a"), draft("b")]
        out = self.js("cashewPatch(input.d, 1, {title: 'X'})", d=ds)
        self.assertEqual([d["title"] for d in out], ["T", "X"])
        self.assertEqual(self.js("cashewPatch(input.d, 5, {title: 'X'})", d=ds), ds)

    def test_category_spreads_to_same_merchant_and_direction_only(self):
        ds = [draft("a"), draft("b"), draft("c", group="g2"), draft("d", amount="50.00", kind="income"),
              draft("e", kind="transfer")]
        out = self.js("cashewApplyCategory(input.d, 0, 'Food Out', 'Lunch', true)", d=ds)
        self.assertEqual([d["category"] for d in out],
                         ["Food Out", "Food Out", "Uncategorized", "Uncategorized", "Uncategorized"])
        one = self.js("cashewApplyCategory(input.d, 0, 'Food Out', '', false)", d=ds)
        self.assertEqual([d["category"] for d in one].count("Food Out"), 1)

    def test_account_spreads_by_account_id(self):
        ds = [draft("a"), draft("b", group="g2"), draft("c", account_id="a2")]
        out = self.js("cashewApplyAccount(input.d, 0, 'HDFC', true)", d=ds)
        self.assertEqual([d["account"] for d in out], ["HDFC", "HDFC", ""])

    def test_remember_does_not_mutate_input(self):
        st = {"version": 1, "categories": {}, "accounts": {}}
        out = self.js("(function(){var s=input.s;var r=cashewRememberCategory(s,'g1','Food Out','Lunch');"
                      "r=cashewRememberAccount(r,'a1','HDFC');return [s,r]})()", s=st)
        self.assertEqual(out[0], st)
        self.assertEqual(out[1]["categories"]["g1"], {"category": "Food Out", "subcategory": "Lunch"})
        self.assertEqual(out[1]["accounts"], {"a1": "HDFC"})

    def test_shown_indexes_and_payload_respect_the_filter(self):
        ds = [draft("a"), draft("b"), draft("c")]
        shown = self.js("cashewShownIndexes(input.d, true, {a: true, c: true})", d=ds)
        self.assertEqual(shown, [0, 2])
        self.assertEqual(self.js("cashewShownIndexes(input.d, false, {})", d=ds), [0, 1, 2])
        payload = json.loads(self.js("cashewPayload(input.d, input.s, 6000)", d=ds, s=shown))
        self.assertEqual([d["include"] for d in payload["drafts"]], [True, False, True])
        self.assertEqual(payload["maxChars"], 6000)
        ds[0]["include"] = False
        inc = self.js("cashewIncluded(input.d, input.s)", d=ds, s=shown)
        self.assertEqual([d["id"] for d in inc], ["c"])

    def test_validation(self):
        self.assertTrue(self.js("cashewValidDate('2026-11-08')"))
        self.assertFalse(self.js("cashewValidDate('08-11-2026')"))
        self.assertFalse(self.js("cashewValidDate('2026-13-01')"))
        self.assertEqual(self.js("cashewNormAmount('-250')"), "-250.00")
        self.assertEqual(self.js("cashewNormAmount('1,250.5')"), "1250.50")
        self.assertIsNone(self.js("cashewNormAmount('12abc')"))

    def test_labels(self):
        self.assertEqual(self.js("cashewLinkLabel(1, 5, 17, 5310)"),
                         "Link 2 of 5  ·  17 transactions  ·  5,310 characters")
        self.assertIn("1 transaction ", self.js("cashewLinkLabel(0, 1, 1, 90)"))
        self.assertEqual(self.js("cashewPrettyJson('{\"a\":1}')"), '{\n "a": 1\n}')
        self.assertEqual(self.js("cashewPrettyJson('nope')"), "nope")

    def test_grouped_list_helpers(self):
        self.assertEqual(self.js("cashewDayLabel('2026-11-08')"), "Sunday, 08-Nov" + _Y)
        self.assertEqual(self.js("cashewDayLabel('oops')"), "oops")
        self.assertEqual(self.js("cashewMoney('-1234567.5')"), "₹1,234,567.50")
        self.assertEqual(self.js("cashewMoney('9.78')"), "₹9.78")
        ds = [draft("a", date="2026-11-01"), draft("b", date="2026-11-03"), draft("c", date="2026-11-03"),
              draft("d", date="2026-11-02")]
        rows = lambda newest: [r["idx"] for r in self.js(
            "cashewRowOrder(input.d, input.s, input.n)", d=ds, s=[0, 1, 2, 3, 9], n=newest)]
        self.assertEqual(rows(True), [2, 1, 3, 0])
        self.assertEqual(rows(False), [0, 3, 1, 2])
        ds[1]["amount"], ds[2]["amount"] = "-9.78", "5.00"
        tot = self.js("cashewDayTotals(input.d, input.s)", d=ds, s=[0, 1, 2])
        self.assertEqual(tot["2026-11-03"], "-₹4.78")
        self.assertEqual(tot["2026-11-01"], "-₹100.00")

    def test_transfer_pair_is_one_row_under_the_out_day(self):
        ds = [draft("o", amount="-50.00", kind="transfer", pairId="p", date="2026-11-03"),
              draft("x", date="2026-11-03"),
              draft("i", amount="50.00", kind="transfer", pairId="p", date="2026-11-05"),
              draft("l", amount="-7.00", kind="transfer", pairId="")]
        rows = self.js("cashewRowOrder(input.d, input.s, true)", d=ds, s=[0, 1, 2, 3])
        self.assertEqual([(r["idx"], r["partner"], r["day"]) for r in rows],
                         [(1, -1, "2026-11-03"), (0, 2, "2026-11-03"), (3, -1, "2026-11-01")])
        self.assertEqual({r["idx"]: r["partner"] for r in rows}[0], 2)
        alone = self.js("cashewRowOrder(input.d, input.s, true)", d=ds, s=[0])
        self.assertEqual(alone[0]["partner"], -1)                                           # partner not shown
        tot = self.js("cashewDayTotals(input.d, input.s)", d=ds, s=[0, 2])
        self.assertEqual(tot, {"2026-11-03": "₹0.00"})
        both = self.js("cashewPatchMany(input.d, [0, 2], {title: 'X'})", d=ds)
        self.assertEqual([both[0]["title"], both[2]["title"], both[1]["title"]], ["X", "X", "T"])

    def test_transfer_links_and_labels(self):
        ds = [draft("o", amount="-1.00", kind="transfer", pairId="p", account="HDFC", title="Transfer to SBI",
                    date="2026-11-07", category="Balance Correction"),
              draft("i", amount="1.00", kind="transfer", pairId="p", account="SBI", date="2026-11-07",
                    category="Balance Correction"),
              draft("x", category="Food Out")]
        res = self.js("cashewBuildLinks(input.d, [0, 1, 2], 6000, input.c, 'web')", d=ds, c=CATS)
        self.assertEqual(res["links"][0]["ids"], ["x"])
        t = res["transfers"][0]
        self.assertEqual(t["url"], "https://budget-track.web.app/addTransferRoute?amountFrom=1.00&amountTo=1.00"
                                   "&accountFrom=HDFC&accountTo=SBI&title=Transfer%20to%20SBI&date=2026-11-07")
        self.assertEqual(self.js("cashewTransferLine(input.t)", t=t), "HDFC → SBI ₹1.00 · 07-Nov" + _Y)
        # leg "i" not shown: "o" becomes a lone leg with a warning
        one = self.js("cashewBuildLinks(input.d, [0, 2], 6000, input.c)", d=ds, c=CATS)
        self.assertEqual((one["transfers"], one["links"][0]["ids"]), ([], ["x", "o"]))
        self.assertTrue(one["warnings"][0].startswith("transfer leg without partner"))
        self.assertEqual(self.js("cashewMarkQuestion(81, 8)"), "Mark 81 as tracked (8 pages need a tap on Save in Cashew)?")
        self.assertEqual(self.js("cashewMarkQuestion(3, 1)"), "Mark 3 as tracked (1 page needs a tap on Save in Cashew)?")
        self.assertEqual(self.js("cashewMarkQuestion(3, 0)"), "Mark 3 as tracked?")

    def test_friend_settlement_split_paid_passes_the_sign_rule_both_ways(self):
        # parity with txdb/cashew.py _friend_fits: only the Split Paid default is relaxed
        ds = [draft("a", amount="-5.00", category="Friend Settlement", subcategory="Split Paid"),
              draft("b", amount="5.00", category="Friend Settlement", subcategory="Split Paid"),
              draft("c", amount="5.00", category="Friend Settlement", subcategory="Lent")]
        res = self.js("cashewBuildLinks(input.d, [0, 1, 2], 6000, input.c)", d=ds, c=CATS + [{"name": "Friend Settlement", "type": "expense", "subcategories": ["Split Paid", "Lent"]}])
        self.assertEqual(len(res["warnings"]), 1)
        self.assertIn("does not fit", res["warnings"][0])

    def test_category_map(self):
        out = self.js("cashewCategoryMap(input.c)", c=[{"name": "A", "icon": "x", "color": "#111111"}, {"name": "B"}])
        self.assertEqual(out["A"], {"icon": "x", "color": "#111111"})
        self.assertEqual(out["B"]["icon"], "❓")


if __name__ == "__main__":
    unittest.main()
