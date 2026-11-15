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
    def test_a_linked_refund_keeps_the_purchases_category_and_is_money_in(self):
        refunds.set_link(self.conn, self.back, self.out)
        got = self.drafts()
        credit, buy = got[self.back], got[self.out]
        self.assertEqual((credit["kind"], credit["refundMode"], credit["refundOf"]), ("refund", "income", self.out))
        self.assertEqual((credit["category"], credit["subcategory"]), ("Shopping", "Footwear"))     # the SAME category
        self.assertEqual((buy["category"], buy["subcategory"]), ("Shopping", "Footwear"))
        self.assertEqual(credit["amount"], "3816.00")                                                # money in: positive
        self.assertEqual(buy["amount"], "-3816.00")                                                  # money out: negative
        self.assertTrue(credit["title"].startswith("Refund: "))
        self.assertIn("02-Nov-26 ₹3816", credit["notes"])
        self.assertEqual(credit["warn"], "")
        self.assertTrue(credit["include"] and buy["include"])

    def test_the_refund_is_its_own_cashew_form_page_with_a_positive_amount_not_in_the_bulk_link(self):
        # The bulk addTransaction link takes income/expense from the category type in the deployed Cashew, so a
        # refund under "Shopping" showed as spend. The form link (addTransactionRoute) takes it from the sign.
        refunds.set_link(self.conn, self.back, self.out)
        out = cashew.build_links([x for x in self.drafts().values() if x["id"] in (self.out, self.back)], base="web")
        self.assertEqual(out["warnings"], [])
        bulk = json.loads(urllib.parse.unquote(out["links"][0]["url"].split("JSON=")[1]))["transactions"]
        self.assertEqual([e["amount"] for e in bulk], ["-3816.00"])                                  # only the purchase
        (page,) = out["refunds"]
        self.assertTrue(page["url"].startswith(cashew.WEB_BASE + "addTransactionRoute?"))
        q = urllib.parse.parse_qs(urllib.parse.urlparse(page["url"]).query)
        self.assertEqual(q["amount"], ["3816.00"])
        self.assertEqual((q["category"], q["subcategory"]), (["Shopping"], ["Footwear"]))
        self.assertEqual(q["account"], ["ICICI 🌳"])
        self.assertEqual(q["date"], ["2026-11-12"])
        self.assertTrue(q["title"][0].startswith("Refund: "))
        self.assertIn("Refund of", q["notes"][0])

    def test_an_expense_category_picked_on_the_credit_by_hand_still_warns_in_the_bulk_link(self):
        plain = [d(1, amount="10.00", category="Shopping", subcategory="Footwear", kind="income")]
        self.assertTrue([w for w in cashew.build_links(plain)["warnings"] if "does not fit" in w])

    def test_skip_both_drops_the_purchase_and_the_refund(self):
        refunds.set_link(self.conn, self.back, self.out, mode="skip")
        got = self.drafts()
        self.assertFalse(got[self.back]["include"])
        self.assertFalse(got[self.out]["include"])
        self.assertTrue(got[self.other]["include"])

    def test_skip_with_a_partial_refund_falls_back_to_income(self):
        ingest.upsert_rows(self.conn, self.card, [
            {"id": "x4", "date": "2026-11-14", "merchant": "FLIPKART INTERNET PVT L", "amount": 1000.0,
             "currency": "INR", "rawStatementRowId": "4"}])
        part = self.conn.execute("SELECT id FROM transactions WHERE amount_paise = 100000").fetchone()[0]
        refunds.set_link(self.conn, part, self.out, mode="skip")
        got = self.drafts()
        self.assertTrue(got[self.out]["include"])
        self.assertTrue(got[part]["include"])
        self.assertEqual(got[part]["refundMode"], "income")

    def test_lent_keeps_the_purchase_and_drops_the_refund(self):
        refunds.set_link(self.conn, self.back, self.out, mode="lent")
        got = self.drafts()
        self.assertFalse(got[self.back]["include"])
        self.assertTrue(got[self.out]["include"])
        self.assertEqual(got[self.out]["refundMode"], "lent")

    def test_a_refund_whose_purchase_is_not_in_the_data_is_also_income_and_keeps_the_note(self):
        refunds.set_link(self.conn, self.other, None, note="Razorpay order")
        got = self.drafts()[self.other]
        self.assertEqual((got["kind"], got["refundOf"]), ("refund", ""))
        self.assertIn("Refund of Razorpay order", got["notes"])
        self.assertEqual(got["category"], "Uncategorized")                      # nothing to copy a category from

    def test_nothing_changes_for_rows_with_no_link(self):
        got = self.drafts()
        self.assertEqual(got[self.back]["kind"], "income")
        self.assertNotIn("refundOf", got[self.back])


class RefundParity(P.Parity):
    """The JS builder must give the same warnings and links for refund drafts as the Python one."""

    def test_refund_pages(self):
        drafts = [
            d(1, kind="refund", amount="3816.00", category="Shopping", subcategory="Footwear", title="Refund: Flipkart",
              refundOf="x", refundMode="income", notes="Refund of Flipkart 02-Nov-26 ₹3816", account="ICICI \U0001F333"),
            d(2, kind="refund", amount="5.00", category="Uncategorized", subcategory="Unknown", refundOf=""),   # no category: warns
            d(3, kind="refund", amount="9.00", title="50% off & more", notes="line1\nline2", date="2026-09-30"),
            d(4, kind="refund", amount="7.00", title="x" * 300, notes="y" * 600),                                  # cut with warnings
            d(5, kind="spend", amount="-3816.00", category="Shopping", subcategory="Footwear"),                  # the purchase: bulk
        ]
        for base in ("app", "web"):
            py = self.both(drafts, base=base)
            self.assertEqual(len(py["refunds"]), 4)
            self.assertEqual(len(py["links"]), 1)
            self.assertEqual(py["links"][0]["count"], 1)                     # only the purchase is in the bulk link
            self.assertTrue([w for w in py["warnings"] if w.startswith("no category")])
            self.assertTrue([w for w in py["warnings"] if "cut to" in w])
            self.assertEqual([w for w in py["warnings"] if "does not fit" in w], [])


# the inherited parity cases already run in test_cashew_parity itself; do not run them twice
for _name in [n for n in dir(P.Parity) if n.startswith("test_")]:
    setattr(RefundParity, _name, None)


if __name__ == "__main__":
    unittest.main()
