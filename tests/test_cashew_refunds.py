"""Linked refunds in the Cashew export: income in the purchase's category, skip both, lent, no-original."""
import json
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from txdb import cashew, db, ingest, refunds  # noqa: E402
import test_cashew_parity as P  # noqa: E402

d = P.d


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)
        self.card = ingest.ensure_account(self.conn, "ICICI", "credit", "4002")
        ingest.upsert_rows(self.conn, self.card, [
            {"id": "x1", "date": "2026-11-02", "merchant": "FLIPKART INTERNET PVT L -BANGALORE", "amount": -3816.0,
             "currency": "INR", "rawStatementRowId": "1"},
            {"id": "x2", "date": "2026-11-12", "merchant": "FLIPKART INTERNET PVT L", "amount": 3816.0,
             "currency": "INR", "rawStatementRowId": "2"},
            {"id": "x3", "date": "2026-11-13", "merchant": "SOMETHING ELSE", "amount": 100.0,
             "currency": "INR", "rawStatementRowId": "3"}])
        ids = [r[0] for r in self.conn.execute("SELECT id FROM transactions ORDER BY date")]
        self.out, self.back, self.other = ids
        group = self.conn.execute("SELECT group_key FROM transactions WHERE id = ?", (self.out,)).fetchone()[0]
        self.state = cashew.empty_state()
        self.state["categories"] = {group: {"category": "Shopping", "subcategory": "Footwear"}}

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def drafts(self):
        ro = cashew.open_readonly(self.path)
        try:
            return {x["id"]: x for x in cashew.drafts(ro, self.state, all_rows=True)}
        finally:
            ro.close()


class Export(Base):
    def test_net_mode_drops_both_when_the_refund_covers_the_purchase(self):
        # Cashew (6.7.2) takes income/expense from the category TYPE and ignores the sign, so a refund cannot be
        # income under the purchase's expense category. Netted: Shopping stays right in Cashew.
        refunds.set_link(self.conn, self.back, self.out, mode="skip")
        got = self.drafts()
        self.assertEqual((got[self.back]["refundMode"], got[self.back]["include"]), ("skip", False))
        self.assertEqual((got[self.out]["refundMode"], got[self.out]["include"]), ("skip", False))
        self.assertTrue(got[self.other]["include"])
        out = cashew.build_links(list(got.values()))
        self.assertNotIn("3816.00", json.dumps(out["links"]))

    def test_a_partial_refund_is_netted_into_the_purchase_amount_in_the_same_category(self):
        ingest.upsert_rows(self.conn, self.card, [
            {"id": "x4", "date": "2026-11-14", "merchant": "FLIPKART INTERNET PVT L", "amount": 1000.0,
             "currency": "INR", "rawStatementRowId": "4"}])
        part = self.conn.execute("SELECT id FROM transactions WHERE amount_paise = 100000").fetchone()[0]
        refunds.set_link(self.conn, part, self.out, mode="skip")          # net mode
        got = self.drafts()
        buy = got[self.out]
        self.assertTrue(buy["include"])
        self.assertEqual(buy["amount"], "-2816.00")                       # 3816 less the 1000 refunded
        self.assertEqual((buy["category"], buy["subcategory"]), ("Shopping", "Footwear"))
        self.assertTrue(buy["notes"].startswith("Paid ₹3816, ₹1000 refunded 14-Nov-26: net ₹2816"))
        self.assertEqual(buy["refundMode"], "net")
        self.assertFalse(got[part]["include"])                            # the refund itself is not exported

    def test_a_linked_refund_is_income_under_an_income_category_and_the_note_names_the_purchase(self):
        # The deployed Cashew shows a credit under an EXPENSE category ("Shopping") as spend, whatever the
        # sign in the link (seen on screen), so a refund goes under an income-type category.
        refunds.set_link(self.conn, self.back, self.out, mode="income")
        got = self.drafts()
        credit, buy = got[self.back], got[self.out]
        self.assertEqual((credit["kind"], credit["refundMode"], credit["refundOf"]), ("refund", "income", self.out))
        self.assertEqual((credit["category"], credit["subcategory"]), cashew.REFUND_CATEGORY)
        self.assertEqual(dict((c["name"], c["type"]) for c in cashew.load_categories())[credit["category"]], "income")
        self.assertEqual((buy["category"], buy["subcategory"]), ("Shopping", "Footwear"))     # the purchase is untouched
        self.assertEqual(credit["amount"], "3816.00")                                          # money in: positive
        self.assertEqual(buy["amount"], "-3816.00")                                            # money out: negative
        self.assertTrue(credit["title"].startswith("Refund: "))
        self.assertTrue(credit["notes"].startswith("Refund of "))
        self.assertIn("02-Nov-26 ₹3816 · Shopping › Footwear", credit["notes"])
        self.assertEqual(credit["warn"], "")
        self.assertTrue(credit["include"] and buy["include"])

    def test_the_link_builder_sends_the_income_mode_refund_as_a_positive_amount_with_no_warning(self):
        refunds.set_link(self.conn, self.back, self.out, mode="income")
        out = cashew.build_links([x for x in self.drafts().values() if x["id"] in (self.out, self.back)])
        self.assertEqual(out["warnings"], [])
        text = urllib.parse.unquote(out["links"][0]["url"].split("JSON=")[1])
        entries = {e["amount"]: e for e in json.loads(text)["transactions"]}
        self.assertEqual(set(entries), {"-3816.00", "3816.00"})
        refund = entries["3816.00"]
        self.assertEqual((refund["category"], refund["subcategory"]), cashew.REFUND_CATEGORY)
        self.assertEqual(entries["-3816.00"]["category"], "Shopping")

    def test_an_expense_category_chosen_on_the_refund_itself_wins_but_warns(self):
        # The person's own pick is kept; the builder warns, because Cashew would show it as spend.
        refunds.set_link(self.conn, self.back, self.out)
        self.state["txn"] = {self.back: {"category": "Shopping", "subcategory": "Footwear"}}
        credit = self.drafts()[self.back]
        self.assertTrue(credit["warn"] or credit["category"] == "Uncategorized")

    def test_an_ordinary_credit_in_an_expense_category_still_warns(self):
        plain = [d(1, amount="10.00", category="Shopping", subcategory="Footwear", kind="income")]
        self.assertTrue([w for w in cashew.build_links(plain)["warnings"] if "does not fit" in w])

    def test_lent_keeps_the_purchase_and_drops_the_refund(self):
        refunds.set_link(self.conn, self.back, self.out, mode="lent")
        got = self.drafts()
        self.assertFalse(got[self.back]["include"])
        self.assertTrue(got[self.out]["include"])
        self.assertEqual(got[self.out]["refundMode"], "lent")

    def test_a_refund_whose_purchase_is_not_in_the_data_is_also_income_and_keeps_the_note(self):
        refunds.set_link(self.conn, self.other, None, note="Razorpay order")      # nothing to net against: income
        got = self.drafts()[self.other]
        self.assertEqual((got["kind"], got["refundOf"]), ("refund", ""))
        self.assertIn("Refund of Razorpay order", got["notes"])
        self.assertEqual((got["category"], got["subcategory"]), cashew.REFUND_CATEGORY)

    def test_nothing_changes_for_rows_with_no_link(self):
        got = self.drafts()
        self.assertEqual(got[self.back]["kind"], "income")
        self.assertNotIn("refundOf", got[self.back])


class RefundParity(P.Parity):
    """The JS builder must give the same warnings and links for refund drafts as the Python one."""

    def test_refund_drafts(self):
        drafts = [
            d(1, kind="refund", amount="3816.00", category="Cashback & Rewards", subcategory="Refund", title="Refund: Flipkart",
              refundOf="x", refundMode="income", notes="Refund of Flipkart 02-Nov-26 ₹3816 · Shopping › Footwear"),
            d(2, kind="refund", amount="10.00", category="Shopping", subcategory="Footwear", refundOf="x"),   # expense category: warns
            d(3, kind="refund", amount="5.00", category="Uncategorized", subcategory="Unknown", refundOf=""),
        ]
        py = self.both(drafts)
        self.assertEqual(len([w for w in py["warnings"] if "does not fit" in w]), 1)


# the inherited parity cases already run in test_cashew_parity itself; do not run them twice
for _name in [n for n in dir(P.Parity) if n.startswith("test_")]:
    setattr(RefundParity, _name, None)


if __name__ == "__main__":
    unittest.main()
