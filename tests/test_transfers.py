"""Pairing the two sides of a transfer between your own accounts. The statement
texts are the real shapes of each bank's rows."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, ingest, queries, transfers  # noqa: E402

SBI_CR = "UPI- TRANSFER FROM 4897734162099 UPI/CR/124028795174/THEJUS M/SBIN/8921768575/NA"
HDFC_DR = "UPI-THEJUS M MANOJ-8921768575@UPI-SBIN0001000-124028795174-NO REMARK"
AXIS_CR = "UPI/P2A/125226240762/THEJUS M /HDFC/MF and F/"
HDFC_DR2 = "UPI-THEJUS M MANOJ-8921768575@UPI-UTIB0000802-125226240762-MF AND FD"
SBI_DR = "UPI- TRANSFER TO 4897692162094 UPI/DR/125045259403/THEJUS M/"


def r(i, date, amount, merchant, account="HDFC|checking|7367", kind="checking"):
    return {"id": i, "date": date, "merchant": merchant, "amount_paise": round(amount * 100),
            "account_id": account, "account_type": kind}


class Pairing(unittest.TestCase):
    def test_the_reference_number_pairs_a_debit_with_the_credit_in_another_bank(self):
        rows = [r("h1", "2026-09-30", -20000, HDFC_DR), r("s1", "2026-09-30", 20000, SBI_CR, "SBI|checking|9373")]
        (p,) = transfers.detect(rows)
        self.assertEqual((p["outId"], p["inId"], p["matchedBy"], p["ref"]), ("h1", "s1", "ref", "124028795174"))
        self.assertEqual(p["amountPaise"], 2000000)

    def test_it_works_whichever_bank_is_the_sender(self):
        rows = [r("a1", "2026-09-30", 15000, AXIS_CR, "AXIS|checking|2934"), r("h2", "2026-09-30", -15000, HDFC_DR2)]
        (p,) = transfers.detect(rows)
        self.assertEqual((p["outId"], p["inId"]), ("h2", "a1"))
        rows = [r("h3", "2026-09-30", 8000, "UPI-THEJUS M MANOJ-8921768575@UPI-SBIN0001000-125045259403-NO REMARK"),
                r("s2", "2026-09-30", -8000, SBI_DR, "SBI|checking|9373")]
        self.assertEqual(transfers.detect(rows)[0]["outId"], "s2")

    def test_the_same_reference_in_one_account_is_a_reversal_not_a_transfer(self):
        rows = [r("s1", "2025-08-24", -1, "UPI- TRANSFER TO 489 UPI/DR/523638826363/Setu Bro/", "SBI|checking|9373"),
                r("s2", "2025-09-14", 1, "UPI- UPI/REVERSAL/523638826363/24082025/21028", "SBI|checking|9373")]
        self.assertEqual(transfers.detect(rows), [])

    def test_equal_amounts_alone_are_not_a_transfer(self):
        # A Rs 1,000 SIP debit and an unrelated Rs 1,000 NEFT credit the same day.
        rows = [r("a1", "2026-05-17", -1000, "UPI/P2M/103308287875/ICCL GROW/HDFC BANK/Indian C//P2V/", "AXIS|checking|2934"),
                r("s1", "2026-05-17", 1000, "NEFT- TRANSFER FROM 99509044300 NEFT*HDFC0000240*X*Y", "SBI|checking|9373")]
        self.assertEqual(transfers.detect(rows), [])

    def test_different_amounts_with_one_reference_are_left_alone(self):
        rows = [r("h1", "2026-09-30", -100, HDFC_DR), r("s1", "2026-09-30", 99, SBI_CR, "SBI|checking|9373")]
        self.assertEqual(transfers.detect(rows), [])

    def test_a_card_bill_payment_pairs_the_bank_debit_with_the_cards_credit(self):
        rows = [r("s1", "2026-10-30", -16005, "UPI- TRANSFER TO 4897694162092 UPI/DR/161813978812/HDFC CARD/", "SBI|checking|9373"),
                r("c1", "2026-10-30", 16005, "Bppy Pymt Ax99630 2b98cd1fbf85b", "HDFC|credit|0220", "credit")]
        (p,) = transfers.detect(rows)
        self.assertEqual((p["outId"], p["inId"], p["matchedBy"]), ("s1", "c1", "card"))

    def test_a_card_payment_that_could_be_either_of_two_is_not_guessed(self):
        rows = [r("s1", "2026-10-30", -595, "UPI- TRANSFER TO 489 UPI/DR/161847673612/X/", "SBI|checking|9373"),
                r("s2", "2026-10-30", -595, "UPI- TRANSFER TO 489 UPI/DR/161847673613/Y/", "SBI|checking|9373"),
                r("c1", "2026-10-30", 595, "Bppy Pymt Ax9963", "HDFC|credit|0220", "credit")]
        self.assertEqual(transfers.detect(rows), [])

    def test_an_ordinary_purchase_matching_a_card_credit_amount_without_payment_wording_is_ignored(self):
        rows = [r("s1", "2026-10-30", -500, "UPI- TRANSFER TO 489 UPI/DR/161847673612/SHOP/", "SBI|checking|9373"),
                r("c1", "2026-10-30", 500, "Refund Amazon", "HDFC|credit|0220", "credit")]
        self.assertEqual(transfers.detect(rows), [])


AXIS_FROM_HDFC = "UPI/P2A/121419291563/THEJUS M /HDFC/MF and R/"


class OwnNameTransfers(unittest.TestCase):
    """Transfers whose other side is not in the data (HDFC history starts later)."""

    def rows(self):
        return [
            # a real pair, which teaches that "THEJUS M ..." is you
            dict(r("h1", "2026-09-30", -20000, HDFC_DR), bank="HDFC"),
            dict(r("s1", "2026-09-30", 20000, SBI_CR, "SBI|checking|9373"), bank="SBI"),
            # an Axis credit from HDFC with no HDFC row, and a stranger, and a card row
            dict(r("a1", "2026-08-31", 14000, AXIS_FROM_HDFC, "AXIS|checking|2934"), bank="AXIS"),
            dict(r("a2", "2026-08-31", -300, "UPI/P2A/777777777777/RAVI KUMAR /HDFC/lunch/", "AXIS|checking|2934"), bank="AXIS"),
            dict(r("c1", "2026-08-31", 100, "THEJUS M REFUND", "HDFC|credit|0220", "credit"), bank="HDFC"),
        ]

    def test_the_name_is_learned_from_the_pairs_and_applied_to_unpaired_rows(self):
        rows = self.rows()
        pairs = transfers.detect(rows)
        names = transfers.own_names(pairs, rows)
        self.assertIn("THEJUSM", names)
        hits = transfers.detect_self(rows, {"h1", "s1"}, names)
        self.assertEqual([(h["id"], h["other"]) for h in hits], [("a1", "HDFC")])   # not RAVI, not the card

    def test_without_any_pair_nothing_is_guessed(self):
        rows = self.rows()[2:]
        self.assertEqual(transfers.detect_self(rows, set(), transfers.own_names([], rows)), [])

    def test_truncated_and_lookalike_names(self):
        same = transfers._same_person
        self.assertTrue(same("THEJUSM", "THEJUSMMANOJ"))
        self.assertTrue(same("THEJUSMM", "THEJUSMMANOJ"))
        self.assertFalse(same("THEJUSM", "THEJUSMO"[:0] + "RAVIKUMAR"))
        self.assertFalse(same("THEJ", "THEJUSMMANOJ"))                  # too short to trust

    def test_the_other_bank_is_read_off_the_text(self):
        self.assertEqual(transfers.other_bank_hint("AXIS", "UPI/P2A/1/THEJUS M /HDFC BANK/MF/"), "HDFC")
        self.assertEqual(transfers.other_bank_hint("HDFC", "UPI-X-Y@UPI-SBIN0001000-1-N"), "SBI")
        self.assertEqual(transfers.other_bank_hint("HDFC", "UPI-X-Y@OKHDFCBANK-1-N"), None)   # its own bank
        self.assertEqual(transfers.other_bank_hint("SBI", "UPI/DR/1/THEJUS M/ICIC/x"), "ICICI")


class InTheSnapshot(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)
        h = ingest.ensure_account(self.conn, "HDFC", "checking", "7367")
        s = ingest.ensure_account(self.conn, "SBI", "checking", "9373")
        ingest.upsert_rows(self.conn, h, [{"id": "t-h", "date": "2026-09-30", "merchant": HDFC_DR,
                                           "amount": -20000.0, "currency": "INR"}])
        ingest.upsert_rows(self.conn, s, [{"id": "t-s", "date": "2026-09-30", "merchant": SBI_CR,
                                           "amount": 20000.0, "currency": "INR"}])

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def cli(self, *args):
        subprocess.run([sys.executable, str(ROOT / "bin/txdb"), *args],
                       env={**os.environ, "TXDB_DB": str(self.path)}, check=True)

    def test_both_legs_are_tagged_and_the_pair_is_listed(self):
        snap = queries.snapshot(self.conn)
        legs = {t["id"]: t for t in snap["transactions"]}
        self.assertEqual((legs["t-h"]["transferRole"], legs["t-s"]["transferRole"]), ("out", "in"))
        self.assertEqual(legs["t-h"]["transferId"], legs["t-s"]["transferId"])
        (pair,) = snap["transfers"]
        self.assertEqual((pair["outId"], pair["inId"], pair["amount"], pair["split"]), ("t-h", "t-s", 20000.0, False))

    def test_splitting_a_pair_untags_it_and_restoring_brings_it_back(self):
        self.cli("transfer-split", "t-h", "t-s")
        snap = queries.snapshot(self.conn)
        legs = {t["id"]: t for t in snap["transactions"]}
        self.assertNotIn("transferId", legs["t-h"])
        self.assertTrue(legs["t-h"]["transferSplitId"])
        self.assertTrue(snap["transfers"][0]["split"])
        self.cli("transfer-restore", "t-h", "t-s")
        legs = {t["id"]: t for t in queries.snapshot(self.conn)["transactions"]}
        self.assertEqual(legs["t-h"]["transferRole"], "out")
        self.assertNotIn("transferSplitId", legs["t-h"])

    def test_an_own_name_row_with_no_other_side_is_tagged_and_can_be_split(self):
        a = ingest.ensure_account(self.conn, "AXIS", "checking", "2934")
        ingest.upsert_rows(self.conn, a, [{"id": "t-a", "date": "2026-08-31", "merchant": AXIS_FROM_HDFC,
                                           "amount": 14000.0, "currency": "INR"}])
        legs = {t["id"]: t for t in queries.snapshot(self.conn)["transactions"]}
        self.assertTrue(legs["t-a"]["transferSelf"])
        self.assertEqual(legs["t-a"]["transferOther"], "HDFC")
        self.cli("transfer-split", "t-a")
        legs = {t["id"]: t for t in queries.snapshot(self.conn)["transactions"]}
        self.assertNotIn("transferSelf", legs["t-a"])
        self.assertTrue(legs["t-a"]["transferSelfSplit"])
        self.cli("transfer-restore", "t-a")
        self.assertTrue({t["id"]: t for t in queries.snapshot(self.conn)["transactions"]}["t-a"]["transferSelf"])

    def test_renaming_one_side_does_not_touch_the_other(self):
        # the per-bank rename keys (v17) keep the two legs' names apart
        keys = {r[0]: r[1] for r in self.conn.execute("SELECT id, group_key FROM transactions")}
        self.assertNotEqual(keys["t-h"], keys["t-s"])


if __name__ == "__main__":
    unittest.main()
