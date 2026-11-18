"""txdb/cashew.py is_person_payee: an answer on a person's payment stays on that row."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb.cashew import is_person_payee  # noqa: E402


class Person(unittest.TestCase):
    def test_people_and_shops(self):
        self.assertTrue(is_person_payee("HDFC", "UPI-KIRAN KRISHNAN-*****AD-1@OKHDFCBANK-HDFC0001497-21200-UPI"))
        self.assertFalse(is_person_payee("HDFC", "UPI-TOBOX VENTURES PRIVATE LI-TOBOX@YBL-YESB0YBLUPI-1-UPI"))
        self.assertFalse(is_person_payee("HDFC", "UPI-CRED CLUB-CRED.CLUB@AXISB-UTIB0000114-1-UPI"))
        self.assertTrue(is_person_payee("SBI", "UPI- TRANSFER TO 4695 UPI/DR/630390210866/DIVYA MA"))
        self.assertFalse(is_person_payee("ICICI", "BIG POPPAS BISTRO"))
        self.assertFalse(is_person_payee("HDFC", "NEFT DR-UTIB0000114-THEJUS"))


if __name__ == "__main__":
    unittest.main()
