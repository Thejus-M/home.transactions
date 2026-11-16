"""The select-all checkbox, the totals line and "Look" (what Cashew receives) of the Cashew window: Model.js helpers."""
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

CATS = [
    {"name": "Balance Correction", "type": "balance", "subcategories": []},
    {"name": "Shopping", "type": "expense", "subcategories": ["Footwear"]},
    {"name": "Food Out", "type": "expense", "subcategories": ["Lunch"]},
    {"name": "Uncategorized", "type": "balance", "subcategories": ["Unknown"]},
]


def draft(id, amount="-100.00", kind="spend", **extra):
    d = {"id": id, "include": True, "date": "2026-11-01", "title": "T " + id, "amount": amount,
         "category": "Food Out", "subcategory": "Lunch", "account": "HDFC", "notes": "", "kind": kind, "pairId": ""}
    d.update(extra)
    return d


def rows():
    return [
        draft("a"),                                                                   # 0 plain expense
        draft("b", "250.50", "income", category="Uncategorized", subcategory="Unknown"),   # 1 needs a category
        draft("o", "-500.00", "transfer", pairId="p", category="Balance Correction", subcategory="", date="2026-11-02"),  # 2
        draft("i", "500.00", "transfer", pairId="p", category="Balance Correction", subcategory="", account="SBI",
              date="2026-11-02"),                                                     # 3
        draft("r", "40.00", "refund", refundMode="skip", include=False),              # 4 netted refund: off on purpose
        draft("t", "-9.00", "transfer", partnerTracked=True, include=False),          # 5 partner tracked: off on purpose
        draft("g", "-20.00", guessed=True, date="2026-11-03"),                        # 6
        draft("x", "-1.00"),                                                          # 7 not shown
    ]


SHOWN = [0, 1, 2, 3, 4, 5, 6]


@unittest.skipUnless(NODE, "node is not installed")
class SelectLook(unittest.TestCase):
    def js(self, expression, **values):
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expression],
                             capture_output=True, text=True, check=True)
        return json.loads(out.stdout)

    def test_visible_rows_are_the_row_order_narrowed_by_the_window_filters(self):
        base = self.js("cashewRowOrder(input.d, input.s, true)", d=rows(), s=SHOWN)
        self.assertEqual(self.js("cashewVisibleRows(input.d, input.s, {newestFirst: true})", d=rows(), s=SHOWN), base)
        self.assertEqual(self.js("cashewVisibleRows(input.d, input.s)", d=rows(), s=SHOWN), base)
        need = self.js("cashewVisibleRows(input.d, input.s, {needOnly: true})", d=rows(), s=SHOWN)
        self.assertEqual([r["idx"] for r in need], [1])
        guessed = self.js("cashewVisibleRows(input.d, input.s, {guessedOnly: true})", d=rows(), s=SHOWN)
        self.assertEqual([r["idx"] for r in guessed], [6])
        self.assertEqual(self.js("cashewVisibleRows(input.d, input.s, {needOnly: true, guessedOnly: true})", d=rows(), s=SHOWN), [])

    def test_row_idxs_include_the_in_leg_of_a_pair(self):
        got = self.js("cashewRowIdxs(cashewVisibleRows(input.d, input.s, {newestFirst: false}))", d=rows(), s=SHOWN)
        self.assertEqual(sorted(got), SHOWN)
        self.assertEqual(self.js("cashewRowIdxs([])"), [])

    def test_auto_off_rows(self):
        got = self.js("input.d.map(cashewAutoOff)", d=rows())
        self.assertEqual(got, [False, False, False, False, True, True, False, False])
        self.assertTrue(self.js("cashewAutoOff({kind: 'refund', refundMode: 'lent'})"))
        self.assertFalse(self.js("cashewAutoOff({kind: 'spend', refundMode: 'lent'})"))    # the purchase stays
        self.assertFalse(self.js("cashewAutoOff({kind: 'refund', refundMode: 'income'})"))
        self.assertFalse(self.js("cashewAutoOff(null)"))

    def test_unselect_all_touches_only_the_given_rows_and_does_not_mutate(self):
        got = self.js("(function(){ var before = JSON.stringify(input.d); var out = cashewSetInclude(input.d, [0, 1], false);"
                      " return {out: out.map(function(d){return d.include}), same: JSON.stringify(input.d) === before,"
                      " kept: out[6] === input.d[6], fresh: out[0] !== input.d[0]} })()", d=rows())
        self.assertEqual(got["out"], [False, False, True, True, False, False, True, True])
        self.assertTrue(got["same"] and got["kept"] and got["fresh"])

    def test_select_all_leaves_the_rows_the_drafter_turned_off(self):
        off = self.js("cashewSetInclude(input.d, input.s, false)", d=rows(), s=SHOWN)
        self.assertEqual([d["include"] for d in off], [False] * 7 + [True])
        on = self.js("cashewSetInclude(input.d, input.s, true)", d=off, s=SHOWN)
        self.assertEqual([d["include"] for d in on], [True, True, True, True, False, False, True, True])
        built = self.js("cashewBuildLinks(input.d, input.s, 6000, input.c, 'app', 'silent')", d=on, s=SHOWN, c=CATS)
        self.assertNotIn("r", [i for l in built["links"] for i in l["ids"]])             # the netted refund is not sent

    def test_select_state(self):
        self.assertEqual(self.js("cashewSelectState(input.d, input.s)", d=rows(), s=SHOWN), "all")    # auto-off rows do not count
        self.assertEqual(self.js("cashewSelectState(cashewSetInclude(input.d, [0], false), input.s)", d=rows(), s=SHOWN), "some")
        self.assertEqual(self.js("cashewSelectState(cashewSetInclude(input.d, input.s, false), input.s)", d=rows(), s=SHOWN), "none")
        self.assertEqual(self.js("cashewSelectState(input.d, [])", d=rows()), "none")

    def test_selection_summary(self):
        got = self.js("cashewSelectionSummary(input.d, input.s)", d=rows(), s=SHOWN)
        self.assertEqual((got["total"], got["on"], got["transfers"]), (7, 5, 1))
        self.assertEqual((got["income"], got["expense"]), ("₹250.50", "₹120.00"))          # the pair is neither
        self.assertEqual(got["text"], "5 of 7 selected · income ₹250.50 · expense ₹120.00 · 1 transfer")
        none = self.js("cashewSelectionSummary(cashewSetInclude(input.d, input.s, false), input.s)", d=rows(), s=SHOWN)
        self.assertEqual(none["text"], "0 of 7 selected")
        self.assertEqual(self.js("cashewSelectionSummary([], []).text"), "0 of 0 selected")

    def test_look_entries_decode_what_the_builder_wrote(self):
        ds = [draft("a", "-10.00", title="50% off"),
              draft("r", "3816.00", "refund", category="Shopping", subcategory="Footwear", title="Refund: F", notes="line one\nline two")]
        built = self.js("cashewBuildLinks(input.d, null, 6000, input.c)", d=ds, c=CATS)
        got = self.js("cashewLookEntries(input.j)", j=built["links"][0]["json"])
        self.assertEqual([(e["title"], e["type"], e["amount"]) for e in got],
                         [("50% off", "expense", "₹10.00"), ("Refund: F", "income", "₹3,816.00")])
        self.assertEqual((got[1]["category"], got[1]["subcategory"], got[1]["account"], got[1]["note"], got[1]["byId"]),
                         ("Shopping", "Footwear", "HDFC", "line one", False))
        self.assertEqual(got[1]["line"], "2026-11-01  ·  income  ·  ₹3,816.00  ·  Shopping › Footwear  ·  HDFC  ·  Refund: F")
        self.assertEqual(len(got), built["links"][0]["count"])
        by_id = self.js("cashewLookEntries(input.j)", j='{"transactions":[{"amount":"5.00","categoryPk":"i-shop"}]}')
        self.assertTrue(by_id[0]["byId"])
        self.assertEqual(self.js("cashewLookEntries('not json')"), [])
        self.assertEqual(self.js("cashewLookEntries('{}')"), [])

    def test_row_fates_cover_every_shown_row_once(self):
        for mode, pair_fate in (("page", "transfer"), ("silent", "link")):
            got = self.js("(function(){ var b = cashewBuildLinks(input.d, input.s, 6000, input.c, 'app', input.m);"
                          " return {f: cashewRowFates(input.d, input.s, b), n: b.links.length} })()",
                          d=rows(), s=SHOWN, c=CATS, m=mode)
            f = got["f"]
            self.assertEqual(set(f), {"a", "b", "o", "i", "r", "t", "g"})                 # "x" is not shown
            self.assertEqual((f["a"]["how"], f["b"]["how"], f["g"]["how"]), ("link", "link", "link"))
            self.assertEqual((f["o"]["how"], f["i"]["how"]), (pair_fate, pair_fate))
            self.assertEqual((f["r"]["how"], f["t"]["how"]), ("netted", "partner"))
            self.assertTrue(all(1 <= v["link"] <= got["n"] for v in f.values() if v["how"] == "link"))
        off = self.js("cashewRowFates(input.d, [0], {links: [], transfers: []})", d=[draft("a", include=False)])
        self.assertEqual(off["a"]["how"], "off")
        filed = self.js("cashewRowFates(input.d, null, null)", d=[draft("a", viaFile=True)])
        self.assertEqual(filed["a"]["how"], "file")

    def test_look_line(self):
        d = rows()
        self.assertEqual(self.js("cashewLookLine(input.d, {how: 'link', link: 2}, 5)", d=d[0]),
                         "Goes in as expense ₹100.00 · Food Out › Lunch · HDFC · link 2 of 5")
        refund = draft("r", "3816.00", "refund", category="Shopping", subcategory="Footwear")
        self.assertTrue(self.js("cashewLookLine(input.d, {how: 'link', link: 1}, 1)", d=refund).startswith("Goes in as income ₹3,816.00 · Shopping › Footwear"))
        self.assertIn("transfer out", self.js("cashewLookLine(input.d, {how: 'link', link: 1}, 1)", d=d[2]))
        self.assertIn("transfer in", self.js("cashewLookLine(input.d, {how: 'link', link: 1}, 1)", d=d[3]))
        self.assertIn("transfer page", self.js("cashewLookLine(input.d, {how: 'transfer'}, 1)", d=d[2]))
        self.assertIn("netted against its purchase", self.js("cashewLookLine(input.d, {how: 'netted'}, 1)", d=d[4]))
        self.assertIn("already tracked", self.js("cashewLookLine(input.d, {how: 'partner'}, 1)", d=d[5]))
        self.assertIn("by file", self.js("cashewLookLine(input.d, {how: 'file'}, 1)", d=d[0]))
        self.assertEqual(self.js("cashewLookLine(input.d, null, 1)", d=d[0]), "Not sent: not selected.")
        self.assertEqual(self.js("cashewLookLine(null, null, 1)"), "")

    def test_llm_status_lines_for_the_minimised_windows(self):
        self.assertEqual(self.js("llmStatusLines({})"), [])
        self.assertEqual(self.js("llmStatusLines(null)"), [])
        got = self.js("llmStatusLines(input.s)", s={"guessing": True, "guessText": "12 of 40", "importing": True,
                                                    "importText": "photo 1\n  model   says hi \n\n", "reparsing": True,
                                                    "reparseTitle": "GRILL BAY", "reparseText": ""})
        self.assertEqual(got, [{"label": "AI categories", "detail": "12 of 40"},
                               {"label": "Reading new bills", "detail": "model says hi"},
                               {"label": "Reparsing GRILL BAY", "detail": "running"}])
        long = self.js("llmStatusLines({reparsing: true, reparseText: input.t})", t="x" * 200)
        self.assertEqual((long[0]["label"], len(long[0]["detail"])), ("Reparsing a bill", 90))


if __name__ == "__main__":
    unittest.main()
