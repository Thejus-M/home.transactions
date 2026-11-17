"""txdb/cashew_rebuild.py: targets from the widget DB."""
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_rebuild  # noqa: E402


class Targets(unittest.TestCase):
    def test_savings_balance_and_card_outstanding(self):
        c = sqlite3.connect(":memory:")
        c.execute("CREATE TABLE balances (account_id, balance_paise, as_of)")
        c.execute("CREATE TABLE card_cycles (account_id, total_outstanding_paise, fetched_at)")
        c.execute("INSERT INTO balances VALUES ('H', 885673, '2026-11-16T14:25:23')")
        c.execute("INSERT INTO card_cycles VALUES ('C', 1075754, '2026-11-16T14:25:24')")
        c.execute("INSERT INTO card_cycles VALUES ('X', 5, '2026-11-16')")              # not a known account
        t = cashew_rebuild.targets(c, {"H": "HDFC", "C": "HDFC CC"})
        self.assertEqual(t, [{"account": "HDFC", "date": "2026-11-16", "paise": 885673},
                             {"account": "HDFC CC", "date": "2026-11-16", "paise": -1075754}])


if __name__ == "__main__":
    unittest.main()
