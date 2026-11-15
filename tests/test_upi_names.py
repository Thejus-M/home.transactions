"""What a row SHOWS for an HDFC UPI payment: the name, never the whole UPI id (keys.display_counterparty and
its twin Model.displayCounterparty). The group key must not change: renames and taught categories hang on it."""
import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import cashew, keys  # noqa: E402

CASES = [
    # (merchant as the bank prints it, name shown, remark)
    ("UPI-BINU M K-BINUMK42-1@OKAXIS-CNRB0000033-627488487791-UPI", "BINU M K", "UPI"),
    ("UPI-ANU K-******42-1@OKAXIS-CNRB0000033-630531406277-UPI", "ANU K", "UPI"),
    ("UPI-KIRAN KRISHNAN-KIRANKRISHNANALANAD-1@OKHDFCBANK-HDFC0001497-130474532431-UPI", "KIRAN KRISHNAN", "UPI"),
    ("UPI-LAKSHMI MOHAN-LMLAKSHMIMOHAN2002@OKSBI-SBIN0070528-627923409528-UPI", "LAKSHMI MOHAN", "UPI"),
    ("UPI-TIMBER FUELS-PAYTMQR5D4E1X@PTYS-YESB0PTMUPI-221805950920-NO REMARK", "TIMBER FUELS", "NO REMARK"),
    ("UPI-MF PAYEE-MFPAYEE-1@OKAXIS-UTIB0000001-123456789012-MF and RD", "MF PAYEE", "MF and RD"),
    ("Upi-tobox Ventures Private Li", "Tobox Ventures Private Li", ""),
]


class Python(unittest.TestCase):
    def test_the_name_is_shown_not_the_id(self):
        for merchant, name, remark in CASES:
            got = keys.display_counterparty("HDFC", merchant)
            self.assertEqual((got["name"], got["remark"]), (name, remark), merchant)

    def test_the_cashew_title_and_remark_use_it(self):
        merchant = CASES[0][0]
        self.assertEqual(cashew.display_title("HDFC", merchant, "k", None, {}), "BINU M K")
        self.assertEqual(cashew.display_title("HDFC", merchant, "k", None, {"k": "Binu"}), "Binu")    # a rename still wins
        self.assertEqual(cashew.upi_remark(CASES[5][0], "HDFC"), "MF and RD")

    def test_the_group_key_is_untouched(self):
        # Saved renames and taught categories are keyed by this; it must not move.
        before = keys.group_key("HDFC", CASES[0][0])
        self.assertTrue(before.startswith("HDFC|"))
        self.assertEqual(keys.group_key("HDFC", CASES[0][0]), before)

    def test_other_banks_and_unrelated_text_are_left_alone(self):
        self.assertIsNone(keys.display_counterparty("HDFC", "AMAZON PAY INDIA"))
        self.assertIsNone(keys.display_counterparty("ICICI", CASES[0][0]))
        self.assertEqual(keys.display_counterparty("HDFC", "UPI-NO-NAME-X@OKAXIS"), keys.display_counterparty("HDFC", "UPI-NO-NAME-X@OKAXIS"))


NODE = shutil.which("node")
SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


@unittest.skipUnless(NODE, "node is not installed")
class Js(unittest.TestCase):
    def js(self, expr, **values):
        out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expr],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out)

    def test_javascript_shows_the_same_names_as_python(self):
        for merchant, name, remark in CASES:
            got = self.js("displayCounterparty(input.t)", t={"bank": "HDFC", "merchant": merchant})
            self.assertEqual((got["name"], got["remark"]), (name, remark), merchant)
            self.assertEqual(self.js("transactionDisplayName(input.t, {})", t={"bank": "HDFC", "merchant": merchant}), name)

    def test_a_rename_and_the_stored_counterparty_still_win(self):
        t = {"bank": "HDFC", "merchant": CASES[0][0], "groupKey": "K"}
        self.assertEqual(self.js("transactionDisplayName(input.t, input.o)", t=t, o={"K": "Binu"}), "Binu")
        self.assertEqual(self.js("transactionDisplayName(input.t, {})", t=dict(t, counterparty="Stored")), "Stored")

    def test_other_banks_are_unchanged(self):
        self.assertIsNone(self.js("displayCounterparty(input.t)", t={"bank": "ICICI", "merchant": CASES[0][0]}))
        self.assertEqual(self.js("transactionDisplayName(input.t, {})", t={"bank": "ICICI", "merchant": "AMAZON"}), "AMAZON")


if __name__ == "__main__":
    unittest.main()
