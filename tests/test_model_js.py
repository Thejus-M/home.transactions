"""Tests for Model.js's bill maths, run through node (Model.js is plain JS
with no QML imports, so it evaluates as-is):
  python3 -m unittest discover -s tests
Skipped when node isn't installed."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NODE = shutil.which("node")

# What the snapshot gives the widget: the Overview scrape's display strings.
CARDS = {
    # Bill generated and not paid, with this cycle's spend building up.
    "rupay": {"bank": "HDFC", "last4": "0220", "accountId": "HDFC|credit|0220", "name": "RUPAY BIZ UPI",
              "total_outstanding": "₹19,132.39", "upcoming_payment_due": "₹16,005.00",
              "unbilled_amount": "₹3,127.00", "payment_status": "AMOUNT DUE",
              "last_statement_amount": "₹16,005.00", "unbilled_credits": "₹0.00",
              "unbilled_purchases": "₹3,127.00", "unsettled_amount": "₹0.39",
              "credit_limit_total": "₹1,38,000.00", "available_limit": "₹1,18,272.23"},
    # Part of the bill already paid into the card.
    "millennia": {"bank": "HDFC", "last4": "7462", "accountId": "HDFC|credit|7462", "name": "MASTERCARD MILLENNIA",
                  "total_outstanding": "₹595.38", "upcoming_payment_due": "₹595.00",
                  "unbilled_amount": "₹0.00", "payment_status": "PARTIALLY PAID",
                  "last_statement_amount": "₹4,374.00", "unbilled_credits": "- ₹3,779.00",
                  "unbilled_purchases": "₹0.00", "unsettled_amount": "₹0.38",
                  "credit_limit_total": "₹1,38,000.00", "available_limit": "₹1,18,272.23"},
    # More paid in than the bill asked for: the bank owes the cardholder.
    "credit": {"last4": "9999", "accountId": "HDFC|credit|9999", "name": "VISA SOMETHING",
               "total_outstanding": "- ₹626.00", "upcoming_payment_due": "₹0.00",
               "unbilled_amount": "₹0.00", "payment_status": "FULLY PAID",
               "last_statement_amount": "₹4,374.00", "unbilled_credits": "- ₹5,000.00",
               "unbilled_purchases": "₹0.00", "unsettled_amount": "₹0.00"},
    # SBI's card. SBI prints only the two totals ("Current Outstanding"
    # and "Total Amount Due"); the fetcher works out the spend between them
    # so pay-now can come out at what SBI actually asks for.
    "sbi": {"bank": "SBI", "last4": "5896", "accountId": "SBI|credit|5896", "name": "Rupay Credit Card",
            "total_outstanding": "₹ 4081.82", "upcoming_payment_due": "₹ 589.00",
            "unbilled_amount": "₹ 3,492.82", "payment_status": "AMOUNT DUE",
            "last_statement_amount": "₹ 589.00", "unbilled_credits": "",
            "unbilled_purchases": "₹ 3,492.82", "unsettled_amount": "",
            "credit_limit_total": "", "available_limit": ""},
    # A row saved before the Outstanding Summary block was scraped.
    "legacy": {"total_outstanding": "₹595.38", "upcoming_payment_due": "₹595.00",
               "unbilled_amount": "₹0.00", "payment_status": "PARTIALLY PAID"},
    # Nothing scraped at all: only the status text is left to go on.
    "empty": {"total_outstanding": "", "upcoming_payment_due": "", "unbilled_amount": "",
              "payment_status": "FULLY PAID"},
}

SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.cards = JSON.parse(process.argv[2]);
const out = {};
for (const name of Object.keys(ctx.cards)) {
  ctx.entry = ctx.cards[name];
  out[name] = vm.runInContext("var p = billParts(entry); p.paid = isBillPaid(entry, null); p", ctx);
}
console.log(JSON.stringify(out));
"""


@unittest.skipUnless(NODE, "node is not installed")
class BillPartsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(CARDS)],
                                capture_output=True, text=True, check=True)
        cls.parts = json.loads(result.stdout)

    def test_bill_paid_in_and_next_month_are_split_out(self):
        card = self.parts["millennia"]
        self.assertEqual(card["billThisMonth"], 4374)
        self.assertEqual(card["paidIn"], 3779)   # the page's "- ₹3,779.00", read as money in
        # Outstanding ₹595.38 less the ₹0.38 of unsettled spend, which belongs
        # to next month's bill — and which is exactly how HDFC arrives at the
        # ₹595.00 it asks for.
        self.assertEqual(card["payNow"], 595)
        self.assertEqual(card["nextBill"], 0.38)
        self.assertFalse(card["inCredit"])
        self.assertFalse(card["paid"])

    def test_the_sbi_card_asks_for_what_sbi_asks_for(self):
        card = self.parts["sbi"]
        self.assertEqual(card["billThisMonth"], 589)     # the statement raised on 1 Nov
        self.assertEqual(card["nextBill"], 3492.82)      # spend since, not billed yet
        self.assertEqual(card["payNow"], 589)            # exactly SBI's "Total Amount Due"
        self.assertEqual(card["paidIn"], 0)
        self.assertFalse(card["inCredit"])
        self.assertFalse(card["paid"])

    def test_this_cycles_spend_is_next_months_bill(self):
        card = self.parts["rupay"]
        self.assertEqual(card["nextBill"], 3127.39)   # ₹3,127.00 settled + ₹0.39 unsettled
        self.assertEqual(card["payNow"], 16005)       # the bank's own ask, to the rupee
        self.assertFalse(card["paid"])

    def test_unsettled_spend_is_not_billed_as_due_now(self):
        """A purchase the merchant has not settled sits in HDFC's "loans and
        unsettled" figure, not in its unbilled amount. Counting it as due was
        billing today's shopping as if the statement already covered it."""
        spent = dict(CARDS["millennia"], total_outstanding="₹1,241.38", unsettled_amount="₹646.38")
        result = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps({"c": spent})],
                                capture_output=True, text=True, check=True)
        card = json.loads(result.stdout)["c"]
        self.assertEqual(card["payNow"], 595)
        self.assertEqual(card["nextBill"], 646.38)

    def test_more_paid_in_than_billed_is_a_credit_not_a_debt(self):
        card = self.parts["credit"]
        self.assertTrue(card["inCredit"])
        self.assertEqual(card["payNow"], -626)
        self.assertTrue(card["paid"])  # nothing to pay -> no bar badge

    def test_a_row_without_the_breakdown_still_knows_what_to_pay(self):
        card = self.parts["legacy"]
        self.assertFalse(card["hasBreakdown"])
        self.assertEqual(card["payNow"], 595.38)  # no unsettled figure to take out
        self.assertEqual(card["nextBill"], 0)
        self.assertEqual([card["billThisMonth"], card["paidIn"]], [0, 0])

    def test_no_amounts_at_all_falls_back_to_the_status_text(self):
        self.assertTrue(self.parts["empty"]["paid"])


SECTION_SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


@unittest.skipUnless(NODE, "node is not installed")
class SectionTotalsTests(unittest.TestCase):
    def run_js(self, expression, **input_values):
        result = subprocess.run(
            [NODE, "-e", SECTION_SCRIPT, str(ROOT / "Model.js"), json.dumps(input_values), expression],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    @property
    def both(self):
        return [CARDS["rupay"], CARDS["millennia"]]

    def test_due_total_adds_up_what_every_card_wants(self):
        self.assertEqual(self.run_js("billsDueTotal(input.cards, {})", cards=self.both), 16600)

    def test_a_card_marked_paid_by_hand_drops_out_of_the_total(self):
        self.assertEqual(
            self.run_js("billsDueTotal(input.cards, input.overrides)",
                        cards=self.both, overrides={"7462": {"markedPaid": True}}), 16005)
        self.assertEqual(
            self.run_js("billsDueTotal(input.cards, input.overrides)", cards=self.both,
                        overrides={"7462": {"markedPaid": True}, "0220": {"markedPaid": True}}), 0)

    def test_a_card_in_credit_never_cancels_another_cards_debt(self):
        cards = [CARDS["credit"], CARDS["millennia"]]
        self.assertEqual(self.run_js("billsDueTotal(input.cards, {})", cards=cards), 595)

    def test_next_total_is_this_cycles_spend_and_ignores_the_paid_override(self):
        self.assertEqual(self.run_js("billsNextTotal(input.cards)", cards=self.both), 3127.77)

    def test_empty_input_totals_zero(self):
        self.assertEqual(self.run_js("billsDueTotal(input.cards, {})", cards=[]), 0)
        self.assertEqual(self.run_js("billsNextTotal(null)", cards=[]), 0)

    def test_one_pool_for_the_two_cards_that_share_a_limit(self):
        pools = self.run_js("creditLimitPools(input.cards)", cards=self.both)
        self.assertEqual(len(pools), 1)
        pool = pools[0]
        self.assertEqual((pool["label"], pool["bank"], pool["cards"]), ("HDFC", "HDFC", 2))
        self.assertEqual(pool["limit"], 138000)
        self.assertEqual(pool["available"], 118272.23)
        # The used figure is both cards' outstanding added together, which is
        # what proves the limit is one pool rather than one limit per card.
        self.assertEqual(pool["used"], 19727.77)
        self.assertAlmostEqual(pool["percent"], 14.3, places=1)
        segments = pool["segments"]
        self.assertEqual([s["last4"] for s in segments], ["0220", "7462"])
        self.assertAlmostEqual(sum(s["amount"] for s in segments), pool["used"], places=2)
        self.assertAlmostEqual(sum(s["fraction"] for s in segments) * 100, pool["percent"], places=2)

    def test_a_second_bank_gets_its_own_pool(self):
        """ICICI's card carries its own limit; folding it into HDFC's pool
        would describe neither."""
        icici = {"bank": "ICICI", "last4": "2004", "accountId": "ICICI|credit|2004",
                 "name": "Coral RuPay", "total_outstanding": "₹0",
                 "credit_limit_total": "₹1,30,000", "available_limit": "₹1,30,040"}
        pools = self.run_js("creditLimitPools(input.cards)", cards=self.both + [icici])
        self.assertEqual([p["label"] for p in pools], ["HDFC", "ICICI"])
        self.assertEqual(pools[1]["limit"], 130000)

    def test_more_available_than_the_limit_is_credit_not_negative_use(self):
        icici = {"bank": "ICICI", "last4": "2004", "accountId": "ICICI|credit|2004",
                 "name": "Coral RuPay", "total_outstanding": "₹0",
                 "credit_limit_total": "₹1,30,000", "available_limit": "₹1,30,040"}
        pool = self.run_js("creditLimitPools(input.cards)", cards=[icici])[0]
        self.assertEqual((pool["used"], pool["credit"], pool["percent"]), (0, 40, 0))

    def test_a_card_with_nothing_outstanding_draws_no_segment(self):
        settled = dict(CARDS["millennia"], total_outstanding="₹0.00")
        pool = self.run_js("creditLimitPools(input.cards)", cards=[CARDS["rupay"], settled])[0]
        self.assertEqual([s["last4"] for s in pool["segments"]], ["0220"])

    def test_segments_never_overfill_the_bar(self):
        """A card whose outstanding is larger than the pool's used figure (a
        stale scrape, say) is clamped rather than drawn past the limit."""
        stale = dict(CARDS["rupay"], total_outstanding="₹1,00,000.00")
        pool = self.run_js("creditLimitPools(input.cards)", cards=[stale, CARDS["millennia"]])[0]
        self.assertAlmostEqual(sum(s["amount"] for s in pool["segments"]), pool["used"], places=2)

    def test_one_bank_whose_cards_disagree_splits_into_a_pool_each(self):
        other = dict(CARDS["millennia"], credit_limit_total="₹50,000.00", available_limit="₹49,404.62")
        pools = self.run_js("creditLimitPools(input.cards)", cards=[CARDS["rupay"], other])
        self.assertEqual([p["label"] for p in pools], ["HDFC ••0220", "HDFC ••7462"])
        self.assertEqual([p["limit"] for p in pools], [138000, 50000])

    def test_the_pools_add_up_into_one_bar(self):
        """The section leads with one figure across every card; two
        headlines answered a question nobody asks first."""
        icici = {"bank": "ICICI", "last4": "2004", "accountId": "ICICI|credit|2004",
                 "name": "Coral RuPay", "total_outstanding": "₹0",
                 "credit_limit_total": "₹1,30,000", "available_limit": "₹1,30,040"}
        total = self.run_js("creditLimitTotal(creditLimitPools(input.cards))",
                            cards=self.both + [icici])
        self.assertEqual(total["limit"], 268000)
        self.assertEqual(total["used"], 19727.77)
        self.assertAlmostEqual(total["percent"], 7.4, places=1)
        # The ₹40 sitting in the ICICI card is reported, not subtracted
        # from HDFC's usage.
        self.assertEqual(total["credit"], 40)
        self.assertEqual(len(total["pools"]), 2)

    def test_one_pool_totals_to_itself(self):
        total = self.run_js("creditLimitTotal(creditLimitPools(input.cards))", cards=self.both)
        pool = self.run_js("creditLimitPools(input.cards)", cards=self.both)[0]
        self.assertEqual((total["limit"], total["used"]), (pool["limit"], pool["used"]))

    def test_no_pools_totals_to_zero_without_dividing_by_it(self):
        self.assertEqual(self.run_js("creditLimitTotal([])"),
                         {"limit": 0, "used": 0, "available": 0, "credit": 0, "percent": 0, "pools": []})

    def test_no_limit_scraped_yet_means_no_pool(self):
        self.assertEqual(self.run_js("creditLimitPools(input.cards)", cards=[CARDS["legacy"]]), [])


@unittest.skipUnless(NODE, "node is not installed")
class CardLabelTests(unittest.TestCase):
    def run_js(self, expression, **input_values):
        result = subprocess.run(
            [NODE, "-e", SECTION_SCRIPT, str(ROOT / "Model.js"), json.dumps(input_values), expression],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_a_rename_keeps_its_network_word(self):
        """"HDFC Rupay" used to render as "HDFC ••0220": the rename went
        through the network-stripping used for scraped names."""
        self.assertEqual(self.run_js('cardLabelParts("RUPAY BIZ UPI", "HDFC Rupay")'),
                         {"label": "HDFC Rupay", "network": "RUPAY"})

    def test_without_a_rename_the_bank_name_loses_the_network_word(self):
        self.assertEqual(self.run_js('cardLabelParts("RUPAY BIZ UPI", null)'),
                         {"label": "BIZ UPI", "network": "RUPAY"})
        self.assertEqual(self.run_js('cardLabelParts("MASTERCARD MILLENNIA", "")'),
                         {"label": "MILLENNIA", "network": "MASTERCARD"})

    def test_a_network_free_rename_keeps_the_mark(self):
        self.assertEqual(self.run_js('cardLabelParts("RUPAY BIZ UPI", "Business card")'),
                         {"label": "Business card", "network": "RUPAY"})

    def test_account_bank(self):
        self.assertEqual(self.run_js('accountBank("HDFC|credit|0220")'), "HDFC")
        self.assertEqual(self.run_js('accountBank("axis|checking|2934")'), "AXIS")
        self.assertEqual(self.run_js('accountBank("")'), "")
        self.assertEqual(self.run_js('accountBank(null)'), "")


ACCOUNT_OPTIONS_SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(
  "accountOptions(input.transactions, input.overviews, {})", ctx)));
"""


@unittest.skipUnless(NODE, "node is not installed")
class AccountTagTests(unittest.TestCase):
    """The short tag beside the bank / network logo: the logo already says the
    bank, so a bank account is just its number, and a card is its own name with
    the bank kept in front (a card mark alone does not say whose it is)."""

    def tag(self, account, overviews=None, names=None):
        script = "accountChipText(input.a, input.ov, input.names)"
        result = subprocess.run(
            [NODE, "-e", SECTION_SCRIPT, str(ROOT / "Model.js"),
             json.dumps({"a": account, "ov": overviews or {}, "names": names or {}}), script],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_a_bank_account_is_only_its_number_whatever_it_was_named(self):
        for bank in ("HDFC", "AXIS", "SBI"):
            self.assertEqual(self.tag({"bank": bank, "accountType": "checking", "last4": "7367"}), "••7367")
        # a stored "HDFC" / "Savings" name is just the bank again
        self.assertEqual(self.tag({"bank": "HDFC", "accountType": "checking", "last4": "7367"}, names={"7367": "HDFC"}), "••7367")
        self.assertEqual(self.tag({"bank": "SBI", "accountType": "checking", "last4": "9373"}, names={"9373": "SBI Savings"}), "••9373")
        # ...but a name that says more survives
        self.assertEqual(self.tag({"bank": "SBI", "accountType": "checking", "last4": "9373"}, names={"9373": "Salary"}), "Salary ••9373")

    def test_a_card_is_its_bank_and_own_name_without_the_repeated_words(self):
        ov = {"7462": {"name": "MASTERCARD MILLENNIA", "bank": "HDFC"}, "0220": {"name": "RUPAY BIZ UPI", "bank": "HDFC"},
              "2004": {"name": "Coral RuPay", "bank": "ICICI"}, "5896": {"name": "", "bank": "SBI"}}
        t = lambda bank, last4: self.tag({"bank": bank, "accountType": "credit", "last4": last4}, ov)
        self.assertEqual(t("HDFC", "7462"), "HDFC Millennia ••7462")
        self.assertEqual(t("HDFC", "0220"), "HDFC Biz UPI ••0220")        # UPI stays an acronym
        self.assertEqual(t("ICICI", "2004"), "ICICI Coral ••2004")
        self.assertEqual(t("SBI", "5896"), "SBI ••5896")                  # a card the bank never named

    def test_the_bank_is_not_said_twice_and_filler_words_go(self):
        ov = {"1111": {"name": "HDFC Bank Regalia Credit Card", "bank": "HDFC"}}
        self.assertEqual(self.tag({"bank": "HDFC", "accountType": "credit", "last4": "1111"}, ov), "HDFC Regalia ••1111")

    def test_a_renamed_card_is_tidied_the_same_way(self):
        ov = {"2004": {"name": "Coral RuPay", "bank": "ICICI"}}
        self.assertEqual(self.tag({"bank": "ICICI", "accountType": "credit", "last4": "2004"}, ov, {"2004": "My Visa Gold Card"}),
                         "ICICI My Gold ••2004")


class AccountOptionTests(unittest.TestCase):
    """The filter chips, one per account. A card with no settled rows yet
    only exists in the billing overview, and its chip has to carry that
    card's own bank."""

    def options(self, transactions, overviews):
        result = subprocess.run(
            [NODE, "-e", ACCOUNT_OPTIONS_SCRIPT, str(ROOT / "Model.js"),
             json.dumps({"transactions": transactions, "overviews": overviews})],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_a_card_with_no_transactions_keeps_its_own_bank(self):
        options = self.options([], {"4821": {"bank": "SBI", "last4": "4821", "name": "SimplyCLICK SBI Card"}})
        self.assertEqual([(o["bank"], o["key"]) for o in options], [("SBI", "SBI|credit|4821")])

    def test_hdfc_is_still_the_fallback_for_an_overview_without_a_bank(self):
        options = self.options([], {"0220": {"last4": "0220", "name": "RUPAY BIZ UPI"}})
        self.assertEqual(options[0]["key"], "HDFC|credit|0220")

    def test_a_card_that_has_transactions_is_listed_once(self):
        transactions = [{"bank": "SBI", "accountType": "credit", "last4": "4821"}]
        overviews = {"4821": {"bank": "SBI", "last4": "4821", "name": "SimplyCLICK SBI Card"}}
        self.assertEqual(len(self.options(transactions, overviews)), 1)
