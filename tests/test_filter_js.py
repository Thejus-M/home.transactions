"""The RECENT filter functions in Model.js, run through node:
    python3 -m unittest discover -s tests

Same vm harness as test_receipts_js.py. Amounts are RUPEES (formatAmount
prints t.amount as-is, with no division by 100), so the fixtures use
rupee values and the bounds test checks 57,614 -> 58,000."""
import json
import shutil
import subprocess
import pathlib
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

TODAY = "2026-11-07"


def row(id, amount=-100.0, date="2026-11-05", bank="SBI", accountType="checking", last4="9373",
        merchant="SHOP", **extra):
    r = {"id": id, "amount": amount, "date": date, "bank": bank, "accountType": accountType,
         "last4": last4, "merchant": merchant, "currency": "INR", "tracked": False}
    r.update(extra)
    return r


SBI = "SBI|checking|9373"
AXIS = "AXIS|checking|2934"
OPTIONS = [{"key": SBI, "label": "SBI ••9373"}, {"key": AXIS, "label": "AXIS ••2934"}]


@unittest.skipUnless(NODE, "node is not installed")
class Harness(unittest.TestCase):
    def js(self, expression, **values):
        result = subprocess.run(
            [NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expression],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def run_filter(self, rows, **parts):
        ctx = parts.pop("ctx", {})
        ctx.setdefault("today", TODAY)
        out = self.js("(function(){ var f = defaultFilter(); Object.assign(f, input.parts);"
                      " return filterTransactions(input.rows, f, input.ctx).map(function(t){return t.id}) })()",
                      rows=rows, parts=parts, ctx=ctx)
        return out


class Defaults(Harness):
    def test_default_filter_is_empty_and_passes_everything(self):
        f = self.js("defaultFilter()")
        self.assertEqual(f["accounts"], [])
        self.assertEqual(self.js("countActive(defaultFilter())"), 0)
        self.assertEqual(self.js("activeFilterChips(defaultFilter(), [])"), [])
        self.assertEqual(self.run_filter([row("a"), row("b")]), ["a", "b"])


class Predicates(Harness):
    def test_transfer_passes_when_its_peer_account_is_selected(self):
        axis_leg = row("x1", amount=-500, bank="AXIS", last4="2934", transferId="x1>s1")
        sbi_leg = row("s1", amount=500, transferId="x1>s1")
        other = row("o1", bank="AXIS", last4="2934")
        out = self.run_filter([axis_leg, sbi_leg, other], accounts=[SBI])
        self.assertEqual(out, ["x1", "s1"])   # the Axis leg stays: its peer is SBI
        self.assertNotIn("o1", out)

    def test_a_transfer_with_a_missing_peer_does_not_pass(self):
        lone = row("x1", bank="AXIS", last4="2934", transferId="x1>gone")
        self.assertEqual(self.run_filter([lone], accounts=[SBI]), [])

    def test_in_and_out(self):
        rows = [row("in", amount=50), row("out", amount=-50)]
        self.assertEqual(self.run_filter(rows, dir="in"), ["in"])
        self.assertEqual(self.run_filter(rows, dir="out"), ["out"])
        self.assertEqual(self.run_filter(rows, dir="any"), ["in", "out"])

    def test_amount_bounds_are_inclusive_and_use_the_absolute_value_in_rupees(self):
        rows = [row("a", amount=-499), row("b", amount=-500), row("c", amount=1000), row("d", amount=-1001)]
        self.assertEqual(self.run_filter(rows, min=500), ["b", "c", "d"])
        self.assertEqual(self.run_filter(rows, max=1000), ["a", "b", "c"])
        self.assertEqual(self.run_filter(rows, min=500, max=1000), ["b", "c"])

    def test_zero_min_is_a_real_bound_not_unset(self):
        self.assertEqual(self.run_filter([row("a", amount=0)], min=0, max=0), ["a"])

    def test_tracked(self):
        rows = [row("t", tracked=True), row("u", tracked=False)]
        self.assertEqual(self.run_filter(rows, tracked="tracked"), ["t"])
        self.assertEqual(self.run_filter(rows, tracked="untracked"), ["u"])

    def test_transfers(self):
        rows = [row("p", transferId="p>q"), row("s", transferSelf=True), row("n")]
        self.assertEqual(self.run_filter(rows, transfers="only"), ["p", "s"])
        self.assertEqual(self.run_filter(rows, transfers="hide"), ["n"])

    def test_bill(self):
        rows = [row("a"), row("b")]
        ctx = {"linkedIds": {"a": True}}
        self.assertEqual(self.run_filter(rows, bill="has", ctx=dict(ctx)), ["a"])
        self.assertEqual(self.run_filter(rows, bill="none", ctx=dict(ctx)), ["b"])

    def test_month_and_last_30_days(self):
        rows = [row("nov", date="2026-11-01"), row("oct", date="2026-10-20"), row("old", date="2026-09-30")]
        self.assertEqual(self.run_filter(rows, month="2026-10"), ["oct"])
        # 30 days ending 2026-11-07 start on 2026-10-09.
        self.assertEqual(self.run_filter(rows, month="30d"), ["nov", "oct"])
        edge = [row("in", date="2026-10-09"), row("out", date="2026-10-08")]
        self.assertEqual(self.run_filter(edge, month="30d"), ["in"])

    def test_text_matches_name_merchant_counterparty_and_note(self):
        rows = [row("n", merchant="ZOMATO"),
                row("c", merchant="NEFT-XYZ", counterparty="Lakshmi Stores"),
                row("o", merchant="AAA", note="rent for flat"),
                row("miss", merchant="OTHER")]
        self.assertEqual(self.run_filter(rows, q="zomato"), ["n"])
        self.assertEqual(self.run_filter(rows, q="LAKSHMI"), ["c"])
        self.assertEqual(self.run_filter(rows, q="rent"), ["o"])
        self.assertEqual(self.run_filter(rows, q="neft"), ["c"])

    def test_text_matches_a_user_rename(self):
        rows = [row("r", merchant="UPI-FOO-1@X-IFSC-123456789012-UPI")]
        out = self.run_filter(rows, q="groceries",
                              ctx={"nameOverrides": {"UPI|HDFC|FOO": "Groceries"}})
        self.assertEqual(out, [])   # key is per bank/counterparty; no match here
        out = self.run_filter([row("r", merchant="PLAIN SHOP", groupKey="g1")], q="groceries",
                              ctx={"nameOverrides": {"g1": "Groceries"}})
        self.assertEqual(out, ["r"])

    def test_all_parts_are_anded(self):
        rows = [row("hit", amount=-900, tracked=True, merchant="CAFE"),
                row("small", amount=-50, tracked=True, merchant="CAFE"),
                row("untracked", amount=-900, merchant="CAFE"),
                row("axis", amount=-900, tracked=True, merchant="CAFE", bank="AXIS", last4="2934")]
        out = self.run_filter(rows, accounts=[SBI], dir="out", tracked="tracked", min=100, q="cafe")
        self.assertEqual(out, ["hit"])


class Bounds(Harness):
    def test_max_rounds_up_to_the_next_thousand(self):
        b = self.js("filterBounds(input.rows)",
                    rows=[row("a", amount=-57614, date="2024-11-02"), row("b", amount=20, date="2026-11-05")])
        self.assertEqual(b["max"], 58000)
        self.assertEqual(b["min"], 0)
        self.assertEqual(b["firstMonth"], "2024-11")
        self.assertEqual(b["lastMonth"], "2026-11")

    def test_empty_input(self):
        b = self.js("filterBounds([])")
        self.assertEqual((b["min"], b["max"], b["firstMonth"], b["lastMonth"]), (0, 0, "", ""))


class Months(Harness):
    def test_shift_month_crosses_years(self):
        self.assertEqual(self.js("shiftMonth('2026-01', -1)"), "2025-12")
        self.assertEqual(self.js("shiftMonth('2026-12', 1)"), "2027-01")
        self.assertEqual(self.js("shiftMonth('2026-11', -12)"), "2025-11")

    def test_month_label(self):
        self.assertEqual(self.js("monthLabel('2026-11')"), "Nov 2026")


class Chips(Harness):
    def test_chips_in_order_with_account_labels(self):
        chips = self.js("(function(){ var f = defaultFilter(); f.accounts = [input.k]; f.dir = 'out';"
                        " f.min = 500; f.month = '2026-11'; return activeFilterChips(f, input.o) })()",
                        k=SBI, o=OPTIONS)
        self.assertEqual([c["id"] for c in chips], ["acct:" + SBI, "dir", "min", "month"])
        self.assertEqual(chips[0]["label"], "SBI ••9373")
        self.assertEqual(chips[2]["label"], "≥ 500")
        self.assertEqual(chips[3]["label"], "Nov 2026")

    def test_a_bank_account_chip_names_the_bank(self):
        chips = self.js("(function(){ var f = defaultFilter(); f.accounts = ['k']; return activeFilterChips(f, input.o) })()",
                        o=[{"key": "k", "label": "••9373", "bank": "SBI", "accountType": "checking"}])
        self.assertEqual(chips[0]["label"], "SBI ••9373")

    def test_count_ignores_the_search_text(self):
        self.assertEqual(self.js("(function(){ var f = defaultFilter(); f.q = 'x'; f.dir = 'in'; return countActive(f) })()"), 1)

    def test_removing_every_chip_returns_to_the_default(self):
        out = self.js("""(function(){
            var f = defaultFilter(); f.q = 'a'; f.accounts = [input.k, 'B|checking|1']; f.dir = 'in'; f.tracked = 'tracked';
            f.transfers = 'hide'; f.bill = 'has'; f.min = 1; f.max = 2; f.month = '30d';
            activeFilterChips(f, input.o).forEach(function (c) { f = removeFilterPart(f, c.id) });
            return f })()""", k=SBI, o=OPTIONS)
        self.assertEqual(out, self.js("defaultFilter()"))

    def test_remove_one_account_keeps_the_other(self):
        out = self.js("removeFilterPart({q:'',accounts:['a','b'],dir:'any',tracked:'any',transfers:'any',bill:'any',min:null,max:null,month:''}, 'acct:a').accounts")
        self.assertEqual(out, ["b"])

    def test_remove_does_not_change_the_original(self):
        out = self.js("(function(){ var f = defaultFilter(); f.dir = 'in'; removeFilterPart(f, 'dir'); return f.dir })()")
        self.assertEqual(out, "in")


class Parsing(Harness):
    def test_amount_text(self):
        cases = {"5k": 5000, "1.2L": 120000, "1,200": 1200, "2cr": 20000000, "750": 750,
                 "₹ 1,00,000": 100000, " 3K ": 3000, "0": 0, "1.5m": 1500000, "2M": 2000000}
        for text, want in cases.items():
            self.assertEqual(self.js("parseAmountInput(input.s)", s=text), want, text)

    def test_empty_and_bad_amount_text_is_null(self):
        for text in ["", "   ", "abc", "-5", "1.2.3", "k", "5x"]:
            self.assertIsNone(self.js("parseAmountInput(input.s)", s=text), text)
        self.assertIsNone(self.js("parseAmountInput(undefined)"))


class Saving(Harness):
    def test_round_trip_keeps_saved_parts_and_drops_text_and_month(self):
        out = self.js("""(function(){
            var f = defaultFilter(); f.q = 'secret'; f.month = '2026-11'; f.accounts = [input.k]; f.dir = 'out';
            f.tracked = 'untracked'; f.transfers = 'hide'; f.bill = 'none'; f.min = 500; f.max = 9000;
            var json = serializeFilter(f);
            return { json: json, back: restoreFilter(json, input.o) } })()""", k=SBI, o=OPTIONS)
        self.assertNotIn("secret", out["json"])
        self.assertNotIn("2026-11", out["json"])
        back = out["back"]
        self.assertEqual((back["q"], back["month"]), ("", ""))
        self.assertEqual(back["accounts"], [SBI])
        self.assertEqual((back["dir"], back["tracked"], back["transfers"], back["bill"], back["min"], back["max"]),
                         ("out", "untracked", "hide", "none", 500, 9000))

    def test_serialize_is_stable_for_account_order(self):
        a = self.js("(function(){ var f = defaultFilter(); f.accounts = ['b','a']; return serializeFilter(f) })()")
        b = self.js("(function(){ var f = defaultFilter(); f.accounts = ['a','b']; return serializeFilter(f) })()")
        self.assertEqual(a, b)

    def test_unknown_accounts_are_dropped(self):
        out = self.js("restoreFilter(JSON.stringify({accounts: [input.k, 'GONE|credit|1']}), input.o).accounts",
                      k=AXIS, o=OPTIONS)
        self.assertEqual(out, [AXIS])

    def test_bad_json_and_bad_values_give_the_default(self):
        default = self.js("defaultFilter()")
        for raw in ["", "{not json", "null", "[1,2]", "42"]:
            self.assertEqual(self.js("restoreFilter(input.s, input.o)", s=raw, o=OPTIONS), default, raw)
        junk = json.dumps({"accounts": "x", "dir": "sideways", "tracked": 3, "transfers": None,
                           "bill": [], "min": "5", "max": -1})
        self.assertEqual(self.js("restoreFilter(input.s, input.o)", s=junk, o=OPTIONS), default)


class BugHunt(Harness):
    """Regressions found in the 2026-11-08 bug hunt (see Docs/Notes/filter-bugs-2026-11-08.md)."""

    def test_search_ignores_accents_and_extra_spaces(self):
        rows = [row("a", merchant="Café Du Monde"), row("b", merchant="Other")]
        self.assertEqual(self.run_filter(rows, q="cafe"), ["a"])
        self.assertEqual(self.run_filter(rows, q="CAFÉ"), ["a"])
        self.assertEqual(self.run_filter(rows, q="  du   monde "), ["a"])
        self.assertEqual(self.run_filter(rows, q="monde cafe"), ["a"])   # every word, any order

    def test_search_treats_regex_characters_as_text(self):
        rows = [row("a", merchant="A+B (x) [y] .*"), row("b", merchant="AAB")]
        for q in ["a+b", "(x)", "[y]", ".*"]:
            self.assertEqual(self.run_filter(rows, q=q), ["a"], q)

    def test_search_does_not_throw_on_a_row_without_merchant(self):
        self.assertEqual(self.run_filter([{"id": "z", "amount": 1, "bank": "SBI", "accountType": "checking",
                                           "last4": "1"}], q="x"), [])

    def test_search_cache_follows_a_changed_row_and_a_new_rename_map(self):
        out = self.js("(function(){ var f = defaultFilter(); f.q = 'old'; var r = [input.r];"
                      " var a = filterTransactions(r, f, {}).length;"
                      " r[0].merchant = 'NEW'; var b = filterTransactions(r, f, {}).length;"
                      " f.q = 'zzz'; var c = filterTransactions(r, f, {nameOverrides: {}}).length;"
                      " return [a, b, c] })()", r=row("a", merchant="old"))
        self.assertEqual(out, [1, 0, 0])

    def test_range_bounds_reject_unreadable_amounts(self):
        rows = [row("ok", amount=-200), row("nan", amount=None)]
        rows[1]["amount"] = "n/a"
        self.assertEqual(self.run_filter(rows, min=1), ["ok"])
        self.assertEqual(self.run_filter(rows, max=500), ["ok"])

    def test_min_equal_to_max_and_inclusive_zero_bounds(self):
        rows = [row("a", amount=-500), row("b", amount=500), row("c", amount=-501)]
        self.assertEqual(self.run_filter(rows, min=500, max=500), ["a", "b"])

    def test_min_zero_is_not_an_active_filter(self):
        f = "(function(){ var f = defaultFilter(); f.min = 0; return %s })()"
        self.assertEqual(self.js(f % "activeFilterChips(f, [])"), [])
        self.assertEqual(self.js(f % "countActive(f)"), 0)
        self.assertIsNone(self.js("restoreFilter(JSON.stringify({min: 0}), []).min"))

    def test_restore_rejects_absurd_amounts(self):
        self.assertIsNone(self.js("restoreFilter(JSON.stringify({max: 1e30}), []).max"))
        self.assertIsNone(self.js("parseAmountInput('99999999999999999999')"))

    def test_parse_accepts_a_trailing_dot(self):
        self.assertEqual(self.js("parseAmountInput('5.')"), 5)

    def test_shift_month_and_label_reject_non_months(self):
        for bad in ["", "30d", "garbage", "2026-13", "2026-00"]:
            self.assertEqual(self.js("shiftMonth(input.s, 1)", s=bad), "", bad)
            self.assertEqual(self.js("monthLabel(input.s)", s=bad), "", bad)
        self.assertEqual(self.js("shiftMonth('2026-01', -1)"), "2025-12")
        self.assertEqual(self.js("shiftMonth('2026-12', 1)"), "2027-01")

    def test_bounds_ignore_malformed_dates(self):
        out = self.js("filterBounds(input.r)", r=[row("a", date="x"), row("b", date="2026-03-04"),
                                                   row("c", date="2025-12-31")])
        self.assertEqual((out["firstMonth"], out["lastMonth"]), ("2025-12", "2026-03"))

    def test_last_30_days_is_30_calendar_days_including_today(self):
        rows = [row("edge", date="2026-10-09"), row("out", date="2026-10-08"), row("today", date=TODAY)]
        self.assertEqual(self.run_filter(rows, month="30d"), ["edge", "today"])

    def test_30_days_across_a_leap_day(self):
        rows = [row("in", date="2028-02-01"), row("out", date="2028-01-31")]
        out = self.run_filter(rows, month="30d", ctx={"today": "2028-03-01"})
        self.assertEqual(out, ["in"])   # 2028-03-01 minus 29 days = 2028-02-01 (leap year)

    def test_peer_rule_for_a_transfer_whose_second_leg_is_listed_first(self):
        a = row("s1", amount=500, transferId="x1>s1")
        b = row("x1", amount=-500, bank="AXIS", last4="2934", transferId="x1>s1")
        self.assertEqual(self.run_filter([a, b], accounts=[AXIS]), ["s1", "x1"])

    def test_peer_rule_does_not_leak_to_a_third_account(self):
        third = row("h1", bank="HDFC", accountType="credit", last4="0220", transferId="h1>gone")
        self.assertEqual(self.run_filter([third], accounts=[AXIS]), [])

    def test_all_tri_states_combine(self):
        rows = [row("a", tracked=True, transferId="a>b"), row("b", tracked=True, transferId="a>b"),
                row("c", tracked=True), row("d")]
        self.assertEqual(self.run_filter(rows, tracked="tracked", transfers="hide"), ["c"])
        self.assertEqual(self.run_filter(rows, tracked="untracked", transfers="hide"), ["d"])
        self.assertEqual(self.run_filter(rows, transfers="only"), ["a", "b"])
        self.assertEqual(self.run_filter(rows, ctx={"linkedIds": {"c": True}}, bill="has"), ["c"])
        self.assertEqual(self.run_filter(rows, ctx={"linkedIds": {"c": True}}, bill="none"), ["a", "b", "d"])

    def test_id_map_cache_follows_a_new_rows_array(self):
        out = self.js("(function(){ var f = defaultFilter(); f.accounts = [input.k];"
                      " var a = filterTransactions([input.x, input.s], f, {}).map(function(t){return t.id});"
                      " var b = filterTransactions([input.x], f, {}).map(function(t){return t.id});"
                      " return [a, b] })()", k=SBI,
                      x=row("x1", bank="AXIS", last4="2934", transferId="x1>s1"), s=row("s1", transferId="x1>s1"))
        self.assertEqual(out, [["x1", "s1"], []])   # peer gone from the second array: no stale match

    def test_filter_does_not_change_the_input_rows(self):
        out = self.js("(function(){ var before = JSON.stringify(input.r);"
                      " var f = defaultFilter(); f.q = 'shop'; f.dir = 'out'; f.accounts = [input.k];"
                      " filterTransactions(input.r, f, {}); return before === JSON.stringify(input.r) })()",
                      r=[row("a"), row("b", amount=5)], k=SBI)
        self.assertTrue(out)


class PanelSource(unittest.TestCase):
    """Guards for Panel.qml rules that cannot run in node."""
    src = (pathlib.Path(__file__).resolve().parent.parent / "Panel.qml").read_text()

    def test_amount_validator_matches_parser_letters(self):
        import re
        m = re.search(r"RegularExpressionValidator \{ regularExpression: /\^\[(.*?)\]\*\$/i", self.src)
        self.assertTrue(m)
        cls = re.compile("[" + m.group(1).replace("\\u20b9", "\u20b9") + "]", re.I)
        for ch in "0123456789.,  \u20b9klLKcrCRmM":
            self.assertTrue(cls.match(ch), ch)
        for ch in "/-x+*":
            self.assertFalse(cls.match(ch), ch)
        for word in ["lac", "lakh", "crore", "cr", "k", "l", "m"]:
            self.assertTrue(all(cls.match(c) for c in word), word)

    def test_one_opened_handler_and_save_flush(self):
        self.assertEqual(self.src.count("onOpenedChanged"), 1)
        self.assertIn("Component.onDestruction: { root.flushFilterSave(); root.flushCashewSave() }", self.src)
        self.assertIn("interval: 120", self.src)

    def test_escape_collapses_panel_before_closing(self):
        i = self.src.index("An open filter panel collapses first")
        self.assertIn("root.filterOpen = false", self.src[i:i + 300])
        self.assertIn("root.close()", self.src[i:i + 300])


if __name__ == "__main__":
    unittest.main()
