"""The portfolio maths in Portfolio.js, run through node:
  python3 -m unittest discover -s tests

Portfolio.js has no QML imports, so node's `vm` can evaluate it and the
result round-trips as JSON — the same harness test_model_js.py uses."""
import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

NODE = shutil.which("node")

SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


def hold(name, kind="mf", value=10000.0, invested=9000.0, **extra):
    row = {"instrumentId": f"{kind}|{name}", "kind": kind, "name": name, "symbol": "",
           "category": "", "amc": "", "broker": "", "value": value, "invested": invested,
           "pnl": round(value - invested, 2),
           "pnlPct": round((value - invested) / invested * 100, 2) if invested else 0,
           "units": 100.0, "price": value / 100, "dayChange": 0.0, "weight": 0.0,
           "firstHeld": "2026-01-01", "asOf": "2026-10-23"}
    row.update(extra)
    return row


@unittest.skipUnless(NODE, "node is not installed")
class Base(unittest.TestCase):
    def js(self, expression, **values):
        result = subprocess.run(
            [NODE, "-e", SCRIPT, str(ROOT / "Portfolio.js"), json.dumps(values), expression],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)


class SummaryTests(Base):
    def test_totals_are_re_added_from_the_rows(self):
        out = self.js("summary(input.p, input.h)",
                      p={"asOf": "2026-10-23", "netWorth": 50000, "xirr": 14.2},
                      h=[hold("A", value=11000, invested=9000), hold("B", value=7000, invested=6000)])
        self.assertEqual(out["value"], 18000)
        self.assertEqual(out["invested"], 15000)
        self.assertEqual(out["pnl"], 3000)
        self.assertEqual(out["pnlPct"], 20.0)
        self.assertEqual(out["netWorth"], 50000)
        self.assertEqual(out["xirr"], 14.2)
        self.assertEqual(out["count"], 2)

    def test_a_server_total_that_contradicts_its_own_rows_is_flagged(self):
        out = self.js("summary(input.p, input.h)",
                      p={"value": 99999}, h=[hold("A", value=10000)])
        self.assertTrue(out["disagrees"])

    def test_rounding_alone_is_not_a_contradiction(self):
        out = self.js("summary(input.p, input.h)",
                      p={"value": 10000.4}, h=[hold("A", value=10000)])
        self.assertFalse(out["disagrees"])

    def test_an_empty_portfolio_answers_with_zeros_not_nan(self):
        out = self.js("summary({}, [])")
        self.assertEqual([out["value"], out["invested"], out["pnl"], out["pnlPct"]], [0, 0, 0, 0])

    def test_age_is_said_plainly(self):
        self.assertEqual(self.js("ageLabel('2026-10-23', '2026-10-23')"), "today")
        self.assertEqual(self.js("ageLabel('2026-10-22', '2026-10-23')"), "yesterday")
        self.assertEqual(self.js("ageLabel('2026-10-18', '2026-10-23')"), "5 days old")
        self.assertEqual(self.js("ageLabel('2026-08-23', '2026-10-23')"), "2 months old")
        self.assertEqual(self.js("ageLabel('', '2026-10-23')"), "")


class GroupingTests(Base):
    def test_sections_follow_a_fixed_order_not_the_data(self):
        out = self.js("groupByKind(input.h).map(function (g) { return g.kind })",
                      h=[hold("C", kind="gold"), hold("A", kind="equity"), hold("B", kind="mf")])
        self.assertEqual(out, ["mf", "equity", "gold"])

    def test_an_unknown_kind_sorts_last_rather_than_disappearing(self):
        out = self.js("groupByKind(input.h).map(function (g) { return g.kind })",
                      h=[hold("X", kind="widgets"), hold("B", kind="mf")])
        self.assertEqual(out, ["mf", "widgets"])

    def test_each_section_carries_its_own_totals(self):
        out = self.js("groupByKind(input.h)[0]",
                      h=[hold("A", value=11000, invested=9000), hold("B", value=7000, invested=6000)])
        self.assertEqual([out["value"], out["invested"], out["pnl"]], [18000, 15000, 3000])
        self.assertEqual([r["name"] for r in out["rows"]], ["A", "B"])  # biggest first

    def test_search_matches_name_symbol_category_and_house(self):
        rows = [hold("Parag Parikh Flexi Cap", category="Flexi Cap", amc="PPFAS"),
                hold("HDFC Bank", kind="equity", symbol="HDFCBANK")]
        for query in ("parikh", "flexi", "ppfas", "hdfcbank"):
            out = self.js("filterHoldings(input.h, [], [], input.q).length", h=rows, q=query)
            self.assertEqual(out, 1, query)

    def test_filters_are_derived_from_what_is_held(self):
        rows = [hold("A", kind="mf", broker="Zerodha"), hold("B", kind="equity")]
        self.assertEqual(self.js("kindOptions(input.h).map(function (o) { return o.key })", h=rows),
                         ["mf", "equity"])
        self.assertEqual(self.js("brokerOptions(input.h).map(function (o) { return o.key })", h=rows),
                         ["Zerodha"])


class AllocationTests(Base):
    def test_fractions_add_up_to_one(self):
        out = self.js("allocationSegments(input.a, [])",
                      a=[{"bucket": "Stocks", "value": 7000}, {"bucket": "MF", "value": 3000}])
        self.assertEqual(out["total"], 10000)
        self.assertEqual([s["percent"] for s in out["segments"]], [70.0, 30.0])
        self.assertAlmostEqual(sum(s["fraction"] for s in out["segments"]), 1.0)

    def test_it_falls_back_to_the_holdings_when_there_is_no_allocation(self):
        out = self.js("allocationSegments([], input.h)",
                      h=[hold("A", kind="mf", value=6000), hold("B", kind="equity", value=4000)])
        self.assertEqual([s["bucket"] for s in out["segments"]], ["Mutual funds", "Stocks"])

    def test_nothing_held_draws_no_bar(self):
        self.assertEqual(self.js("allocationSegments([], [])")["segments"], [])


class AnalysisTests(Base):
    def test_concentration_answers_how_much_the_top_few_hold(self):
        rows = [hold(str(i), value=v) for i, v in enumerate([5000, 3000, 1000, 500, 300, 200])]
        out = self.js("concentration(input.h, 3)", h=rows)
        self.assertEqual(out["percent"], 90.0)
        self.assertEqual(out["largestPercent"], 50.0)

    def test_overlap_only_reports_a_category_held_more_than_once_and_large(self):
        rows = [hold("A", category="Flexi Cap", value=4000), hold("B", category="Flexi Cap", value=4000),
                hold("C", category="Small Cap", value=2000)]
        out = self.js("categoryOverlap(input.h)", h=rows)
        self.assertEqual([(o["category"], o["count"], o["percent"]) for o in out],
                         [("Flexi Cap", 2, 80.0)])

    def test_one_fund_in_a_category_is_not_an_overlap(self):
        self.assertEqual(self.js("categoryOverlap(input.h)",
                                 h=[hold("A", category="Flexi Cap")]), [])

    def test_cash_drag_counts_cash_and_deposits(self):
        out = self.js("cashDrag(input.h)",
                      h=[hold("A", kind="cash", value=2000), hold("B", kind="fd", value=1000),
                         hold("C", kind="mf", value=7000)])
        self.assertEqual([out["value"], out["percent"]], [3000, 30.0])

    def test_net_invested_is_what_went_in_less_what_came_back(self):
        out = self.js("netInvested(input.a, '2026-10')", a=[
            {"date": "2026-10-05", "kind": "sip", "amount": 5000},
            {"date": "2026-10-05", "kind": "sip", "amount": 10000},
            {"date": "2026-10-19", "kind": "sell", "amount": 8420},
            {"date": "2026-09-05", "kind": "sip", "amount": 5000},
        ])
        self.assertEqual([out["invested"], out["withdrawn"], out["net"], out["sip"]],
                         [15000, 8420, 6580, 15000])

    def test_opening_positions_are_not_this_month_s_buying(self):
        """Every holding produces a "new" row on the first fetch. Counting
        those as purchases would say the whole portfolio was bought that
        day."""
        out = self.js("netInvested(input.a, '2026-10')", a=[
            {"date": "2026-10-18", "kind": "new", "amount": 155340},
            {"date": "2026-10-22", "kind": "buy", "amount": 5000},
        ])
        self.assertEqual([out["invested"], out["opening"], out["net"]], [5000, 155340, 5000])

    def test_a_bonus_moves_no_money_either(self):
        out = self.js("netInvested(input.a, '2026-10')", a=[
            {"date": "2026-10-10", "kind": "corporate", "amount": 0},
            {"date": "2026-10-11", "kind": "sip", "amount": 2000}])
        self.assertEqual(out["invested"], 2000)

    def test_movers_ignore_positions_too_small_to_matter(self):
        out = self.js("movers(input.h, 1000)",
                      h=[hold("Tiny", value=100, invested=10), hold("Big", value=12000, invested=10000),
                         hold("Down", value=8000, invested=10000)])
        self.assertEqual(out["best"]["name"], "Big")
        self.assertEqual(out["worst"]["name"], "Down")


class SparklineTests(Base):
    def test_points_are_normalised_with_the_top_at_zero(self):
        out = self.js("sparkline(input.h)", h=[
            {"asOf": "2026-10-21", "value": 100}, {"asOf": "2026-10-22", "value": 300},
            {"asOf": "2026-10-23", "value": 200}])
        self.assertEqual([round(p["x"], 2) for p in out["points"]], [0.0, 0.5, 1.0])
        self.assertEqual([round(p["y"], 2) for p in out["points"]], [1.0, 0.0, 0.5])
        self.assertEqual([out["change"], out["changePct"]], [100, 100.0])

    def test_one_point_is_not_a_line(self):
        self.assertIsNone(self.js("sparkline(input.h)", h=[{"asOf": "2026-10-23", "value": 100}]))

    def test_a_flat_line_sits_in_the_middle_rather_than_dividing_by_zero(self):
        out = self.js("sparkline(input.h)", h=[{"asOf": "a", "value": 100}, {"asOf": "b", "value": 100}])
        self.assertEqual([p["y"] for p in out["points"]], [0.5, 0.5])

    def test_drawdown_only_speaks_while_the_portfolio_is_down(self):
        down = self.js("drawdown(input.h)", h=[{"value": 100}, {"value": 200}, {"value": 150}])
        self.assertEqual([down["peak"], down["now"], down["percent"]], [200, 150, 25.0])
        self.assertIsNone(self.js("drawdown(input.h)", h=[{"value": 100}, {"value": 200}]))

    def test_days_held_counts_from_the_first_snapshot_that_saw_it(self):
        self.assertEqual(self.js("daysHeld(input.h, '2026-10-23')",
                                 h=hold("A", firstHeld="2026-10-01")), 22)


class LabelTests(Base):
    def test_a_kind_reads_the_same_everywhere(self):
        self.assertEqual(self.js("kindLabel('us_equity')"), "US stocks")
        self.assertEqual(self.js("kindLabel('widgets')"), "widgets")

    def test_money_in_and_money_back_keep_the_bank_tab_s_sign_convention(self):
        self.assertEqual(self.js("[activityIsOutflow('sip'), activityIsOutflow('sell')]"), [True, False])
        self.assertEqual(self.js("activityLabel('corporate')"), "BONUS")


if __name__ == "__main__":
    unittest.main()
