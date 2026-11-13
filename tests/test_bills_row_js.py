"""Model.billRowView: the two-line BILLS row for the four real cards and the other states."""
import json
import shutil
import subprocess
import unittest
from datetime import date, timedelta
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


def view(overview, paid=False):
    out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps({"o": overview, "paid": paid}),
                          "billRowView(input.o, input.paid)"], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def iso(days):
    return (date.today() + timedelta(days=days)).isoformat()


@unittest.skipUnless(NODE, "node is not installed")
class BillRowViewTests(unittest.TestCase):
    def test_unpaid_card_leads_with_the_bill_and_keeps_so_far_small(self):
        v = view({"last4": "4002", "total_outstanding": "₹16,591.82", "last_statement_amount": "₹16,591.82",
                  "unbilled_purchases": "₹0", "minimum_due": "₹830", "dueDate": iso(17), "billingDay": 12})
        self.assertEqual((v["pill"], v["bill"]["text"], v["bill"]["primary"], v["soFar"]["text"]), ("NOT PAID", "₹16,592", True, "₹0"))
        self.assertFalse(v["soFar"]["primary"])
        self.assertIn("(17d)", v["line2"])
        self.assertIn("min ₹830", v["line2"])
        self.assertNotIn("so far", v["line2"])                 # nothing building: no noise

    def test_so_far_shows_small_on_line_two_while_unpaid(self):
        v = view({"last4": "1", "total_outstanding": "₹12,000", "last_statement_amount": "₹10,000",
                  "unbilled_purchases": "₹2,000", "dueDate": iso(10), "billingDay": 12})
        self.assertEqual((v["bill"]["text"], v["soFar"]["text"]), ("₹10,000", "₹2,000"))
        
    def test_overdue_and_soon_are_urgent(self):
        late = view({"last4": "1", "total_outstanding": "₹500", "last_statement_amount": "₹500", "unbilled_purchases": "₹0",
                     "dueDate": iso(-2)})
        self.assertEqual((late["pill"], late["rightUrgent"]), ("OVERDUE", True))
        soon = view({"last4": "1", "total_outstanding": "₹500", "last_statement_amount": "₹500", "unbilled_purchases": "₹0",
                     "dueDate": iso(2)})
        self.assertEqual((soon["pill"], soon["rightUrgent"]), ("NOT PAID", True))

    def test_paid_card_promotes_the_spend_so_far(self):
        v = view({"last4": "1", "total_outstanding": "₹3,000", "last_statement_amount": "₹0", "unbilled_purchases": "₹3,000",
                  "billingDay": 12})
        self.assertEqual((v["pill"], v["bill"]["text"], v["soFar"]["text"], v["soFar"]["primary"]), ("BILL PAID", "₹0", "₹3,000", True))
        self.assertEqual((v["pillTone"], v["bill"]["tone"]), ("credit", "credit"))               # paid is green

    def test_paid_card_without_spend(self):
        v = view({"last4": "1", "total_outstanding": "₹0", "last_statement_amount": "₹0", "unbilled_purchases": "₹0"})
        self.assertEqual((v["pill"], v["bill"]["text"], v["soFar"]["text"]), ("BILL PAID", "₹0", "₹0"))      # nothing: zeros, not words

    def test_sent_card_when_a_payment_covers_the_bill(self):
        v = view({"last4": "5896", "total_outstanding": "₹12,223.04", "last_statement_amount": "₹589.00",
                  "unbilled_purchases": "₹11,634.04", "paidSinceBill": 588.82, "paidSinceDate": iso(-7), "billingDay": 1})
        self.assertEqual((v["pill"], v["bill"]["text"], v["soFar"]["text"], v["soFar"]["primary"]), ("BILL SENT", "₹589", "₹11,634", True))
        self.assertEqual((v["pillTone"], v["bill"]["tone"], v["soFar"]["tone"]), ("pending", "credit", "pending"))   # word yellow, bill green, spend so far yellow
        self.assertIn("paid", v["line2"])

    def test_spend_that_rounds_to_zero_is_zero(self):
        v = view({"last4": "0220", "total_outstanding": "₹10,930.27", "last_statement_amount": "₹10,930.00",
                  "unbilled_purchases": "₹0", "unsettled_amount": "₹0.27", "dueDate": iso(19)})
        self.assertEqual((v["bill"]["text"], v["soFar"]["text"]), ("₹10,930", "₹0"))

    def test_card_in_credit(self):
        v = view({"last4": "1", "total_outstanding": "- ₹626.00", "last_statement_amount": "₹0", "unbilled_purchases": "₹0"})
        self.assertEqual((v["pill"], v["bill"]["text"], v["bill"]["tone"]), ("IN CREDIT", "₹626 credit", "credit"))


if __name__ == "__main__":
    unittest.main()
