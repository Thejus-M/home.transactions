"""Refund helpers in Model.js: candidates and score (mirror txdb/refunds.py), month totals, filter part."""
import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

SCRIPT = """
const vm = require('vm'), fs = require('fs');
const ctx = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv[1], 'utf8'), ctx);
ctx.input = JSON.parse(process.argv[3]);
process.stdout.write(JSON.stringify(vm.runInContext(process.argv[2], ctx)));
"""


def tx(i, date, amount, merchant, bank="ICICI", kind="credit", last4="4002", **extra):
    return {"id": i, "date": date, "amount": amount, "merchant": merchant, "bank": bank, "accountType": kind,
            "last4": last4, "currency": "INR", "status": "settled", "tracked": False, **extra}


OUT = tx("o1", "2026-11-02", -3816.0, "FLIPKART INTERNET PVT L -BANGALORE")
BACK = tx("c1", "2026-11-12", 3816.0, "FLIPKART INTERNET PVT L")


@unittest.skipUnless(shutil.which("node"), "node not installed")
class RefundJs(unittest.TestCase):
    def js(self, expr, **values):
        out = subprocess.run(["node", "-e", SCRIPT, str(ROOT / "Model.js"), expr, json.dumps(values)],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out) if out else None

    def test_the_words_that_name_a_merchant_match_the_python_ones(self):
        self.assertEqual(sorted(self.js("refundTokens('FLIPKART INTERNET PVT L -BANGALORE')")), ["FLIPKART"])
        self.assertEqual(self.js("refundTokens('UPI- TRANSFER FROM 48977351620')"), {})
        from txdb import refunds
        for m in ("FLIPKART INTERNET PVT L -BANGALORE", "UPI-SWIGGY LIMITED-x@y", "AMAZON PAY INDIA", "Setu Bro"):
            self.assertEqual(sorted(self.js("refundTokens(input.m)", m=m)), sorted(refunds.tokens(m)), m)

    def test_the_score_matches_the_python_score_for_the_same_cases(self):
        from txdb import refunds
        cases = [
            (BACK, OUT),
            (tx("c", "2026-11-12", 1000.0, "FLIPKART INTERNET"), OUT),
            (tx("c", "2026-11-12", 3816.0, "SWIGGY"), OUT),
            (tx("c", "2026-11-01", 3816.0, "FLIPKART"), OUT),
            (tx("c", "2026-11-12", 4000.0, "FLIPKART"), OUT),
            (tx("c", "2026-11-12", 3816.0, "FLIPKART", bank="HDFC", last4="7462"), OUT),
        ]

        def py(t):
            return {"id": t["id"], "date": t["date"], "merchant": t["merchant"], "amount_paise": round(t["amount"] * 100),
                    "account_id": f"{t['bank']}|{t['accountType']}|{t['last4']}", "account_type": t["accountType"], "bank": t["bank"]}
        for credit, out in cases:
            want = refunds.match(py(credit), py(out))
            got = self.js("refundMatchScore(input.c, input.o)", c=credit, o=out)
            if want is None:
                self.assertIsNone(got, credit)
            else:
                self.assertEqual(got["score"], want["score"], credit)
                self.assertEqual((got["exact"], got["full"], got["sameAccount"]), (want["exact"], want["full"], want["sameAccount"]))

    def test_the_shared_upi_reference_is_certain(self):
        out = tx("o", "2025-08-24", -1.0, "UPI/DR/523638826363/Setu Bro/kkbk", bank="SBI", kind="checking", last4="9373")
        back = tx("c", "2025-09-14", 1.0, "UPI/REVERSAL/523638826363/24082025", bank="SBI", kind="checking", last4="9373")
        got = self.js("refundMatchScore(input.c, input.o)", c=back, o=out)
        self.assertTrue(got["ref"])
        self.assertGreaterEqual(got["score"], 100)

    def test_candidates_are_best_first_and_skip_transfers_and_credits(self):
        weak = tx("o2", "2026-10-20", -5000.0, "FLIPKART INTERNET PVT L")
        other = tx("o3", "2026-11-05", -50.0, "SWIGGY")
        credit2 = tx("c2", "2026-11-01", 10.0, "FLIPKART")
        moved = tx("o4", "2026-11-04", -3816.0, "FLIPKART", transferId="a>b")
        out = self.js("refundCandidates(input.c, input.t)", c=BACK, t=[weak, other, OUT, credit2, moved])
        self.assertEqual([c["txn"]["id"] for c in out], ["o1", "o2"])
        everything = self.js("refundCandidates(input.c, input.t, { all: true })", c=BACK, t=[weak, other, OUT, credit2, moved])
        self.assertEqual([c["txn"]["id"] for c in everything], ["o1", "o2", "o3"])    # then the rest, score 0

    def test_a_linked_refund_nets_the_month_instead_of_counting_as_income(self):
        rows = [OUT, dict(BACK, refundOf="o1", refundMode="income"), tx("p", "2026-11-03", 500.0, "FRIEND", kind="checking")]
        got = self.js("monthSummary(input.r, '2026-11-14')", r=rows)
        self.assertEqual((got["spent"], got["income"], got["refunded"]), (0, 500.0, 3816.0))

    def test_a_refund_never_pushes_spent_below_zero_and_an_unlinked_credit_stays_income(self):
        rows = [tx("o", "2026-11-02", -100.0, "A"), dict(tx("c", "2026-11-05", 100.0, "A"), refundOf="o"),
                dict(tx("c2", "2026-11-06", 40.0, "A"), refundOf="o"), tx("u", "2026-11-07", 70.0, "ZZZ")]
        got = self.js("monthSummary(input.r, '2026-11-14')", r=rows)
        self.assertEqual((got["spent"], got["income"]), (0, 70.0))
        plain = self.js("monthSummary(input.r, '2026-11-14')", r=[OUT, BACK])
        self.assertEqual((plain["spent"], plain["income"]), (3816.0, 3816.0))     # not linked: as before

    def test_the_refund_filter_part(self):
        linked = dict(BACK, refundOf="o1")
        bought = dict(OUT, refundState="full")
        needs = tx("c3", "2026-11-13", 90.0, "MYSTERY")
        said_no = dict(tx("c4", "2026-11-13", 91.0, "MYSTERY"), refundNot=True)
        rows = [linked, bought, needs, said_no, tx("d", "2026-11-13", -5.0, "COFFEE")]
        f = "Object.assign(defaultFilter(), { refund: input.w })"
        ids = lambda w: [t["id"] for t in self.js(f"filterTransactions(input.r, {f.replace('input.w', json.dumps(w))}, {{}})", r=rows)]
        self.assertEqual(ids("linked"), ["c1", "o1"])
        self.assertEqual(ids("needs"), ["c3"])
        self.assertEqual(len(ids("any")), 5)

    def test_chips_save_and_restore_the_refund_part(self):
        f = self.js("Object.assign(defaultFilter(), { refund: 'needs' })")
        self.assertEqual(self.js("activeFilterChips(input.f, [])", f=f), [{"id": "refund", "label": "Needs refund link"}])
        self.assertEqual(self.js("removeFilterPart(input.f, 'refund').refund", f=f), "any")
        saved = self.js("serializeFilter(input.f)", f=f)
        self.assertEqual(self.js("restoreFilter(input.s, []).refund", s=saved), "needs")
        self.assertEqual(self.js("restoreFilter('{\"refund\":\"zzz\"}', []).refund"), "any")

    def test_the_cashew_window_notes_about_refunds(self):
        drafts = [
            {"id": "f", "kind": "refund", "refundMode": "income", "include": True, "viaFile": True, "title": "Refund: F"},
            {"id": "g", "kind": "spend", "include": True, "viaFile": True, "title": "Friend"},
            {"id": "a", "kind": "refund", "refundMode": "income", "include": True, "categoryPk": "i-shop", "title": "Refund: X"},
            {"id": "p", "kind": "refund", "refundMode": "income", "include": True, "title": "Refund: P"},
            {"id": "s", "kind": "refund", "refundMode": "income", "include": True, "title": "Refund: S",
             "refundCategory": "Shopping", "refundSubcategory": "Footwear"},
            {"id": "b", "kind": "refund", "refundMode": "skip", "include": False, "title": "Refund: Y"},
            {"id": "c", "kind": "spend", "refundMode": "skip", "include": False, "title": "Y"},
            {"id": "n", "kind": "spend", "refundMode": "net", "include": True, "title": "Z"},
            {"id": "d", "kind": "spend", "refundMode": "lent", "include": True, "title": "Shoes"},
            {"id": "e", "kind": "spend", "include": True, "title": "Coffee"},
        ]
        notes = self.js("cashewRefundNotes(input.d, null)", d=drafts)
        self.assertEqual(len(notes), 7)
        self.assertIn("2 rows are marked to be added by file, not by link", notes[0])
        self.assertIn("txdb cashew-fix", notes[0])
        self.assertIn("1 refund goes in as income under the income twin", notes[1])
        self.assertIn("1 refund goes in as income in the category of the purchase", notes[2])
        self.assertIn("1 refund has no purchase to copy a category from", notes[3])
        self.assertIn("1 refund is netted into its purchase", notes[4])
        self.assertIn("1 purchase is sent at the amount left", notes[5])
        self.assertIn('open "Shoes" in Cashew', notes[6])
        self.assertEqual(self.js("cashewRefundNotes(input.d, [9])", d=drafts), [])      # only shown rows count
        self.assertEqual(self.js("cashewRefundNotes([], null)"), [])

    def test_the_file_button_counts_its_rows_and_reads_the_result(self):
        drafts = [{"id": "a", "viaFile": True, "include": True}, {"id": "b", "viaFile": True, "include": False},
                  {"id": "c", "include": True}, {"id": "d", "viaFile": True}]
        self.assertEqual(self.js("cashewFileRows(input.d, null)", d=drafts), 2)
        self.assertEqual(self.js("cashewFileRows(input.d, [0, 1])", d=drafts), 1)         # only shown rows
        ok = self.js("cashewFixResult(input.o, '')", o="  2026-11-12 ... will be added\n7 rows added. Import this file in Cashew: /home/pc/Downloads/cashew-import.sql\n")
        self.assertEqual(ok, {"path": "/home/pc/Downloads/cashew-import.sql", "message": "7 rows are in the file."})
        self.assertEqual(self.js("cashewFixResult('0 rows to add; nothing to do', '')")["path"], "")
        self.assertIn("Nothing to add", self.js("cashewFixResult('0 rows to add; nothing to do', '')")["message"])
        self.assertEqual(self.js("cashewFixResult('', 'x\\ncashew-fix: no Cashew database found')")["message"], "cashew-fix: no Cashew database found")
        self.assertEqual(self.js("cashewFixResult('', '')")["message"], "No file was made.")

    def test_the_texts(self):
        byid = {"o1": OUT}
        self.assertEqual(self.js("refundOfText(input.c, input.b)", c=dict(BACK, refundOf="o1"), b=byid),
                         "Refund of FLIPKART INTERNET PVT L -BANGALORE · 02-Nov · ₹3,816")
        self.assertIn("not in your data", self.js("refundOfText(input.c, input.b)", c=dict(BACK, refundOf=""), b=byid))
        self.assertEqual(self.js("refundedChip(input.t)", t=dict(OUT, refundState="full", refundedAmount=3816.0)), "Refunded ₹3,816")
        self.assertEqual(self.js("refundedChip(input.t)", t=dict(OUT, refundState="partial", refundedAmount=1000.0)), "Refunded ₹1,000 of ₹3,816")
        self.assertEqual(self.js("refundedChip(input.t)", t=dict(OUT, refundState="pending")), "Refund pending")
        self.assertEqual(self.js("refundedChip(input.t)", t=OUT), "")


if __name__ == "__main__":
    unittest.main()
