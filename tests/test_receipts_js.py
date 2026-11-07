"""The receipt ranking/formatting logic in Model.js, run through node:
    python3 -m unittest discover -s tests

Model.js has no QML imports, so node's `vm` can evaluate it directly — the
same harness test_model_js.py and test_portfolio_js.py use.

The matching cases here are deliberately the same ones
receipt-ledger-stitcher's tests/test_logic.py::Matching exercises against
src/match.py's score(), so the Python auto-match and this picker cannot
silently drift into disagreeing about what a good match looks like.
"""
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


def txn(id="t1", date="2026-11-05", amount=-456.0, merchant="Upi-kunnil Marginfree",
        counterparty="", tracked=False):
    return {"id": id, "date": date, "amount": amount, "merchant": merchant,
            "counterparty": counterparty, "tracked": tracked}


def receipt(merchant="KUNNIL MARGINFREE HYPERMARKET", date="2026-11-05", total=456.0, **extra):
    row = {"id": "rcpt-1", "merchant": merchant, "date": date, "total": total, "state": "unmatched",
           "items": [], "taxes": [], "warnings": [], "needsReview": False, "currency": "INR"}
    row.update(extra)
    return row


@unittest.skipUnless(NODE, "node is not installed")
class Harness(unittest.TestCase):
    def js(self, expression, **values):
        result = subprocess.run(
            [NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expression],
            capture_output=True, text=True, check=True)
        return json.loads(result.stdout)


class Sorting(Harness):
    def test_unmatched_is_pinned_above_linked_whatever_the_dates(self):
        old_unmatched = receipt(date="2026-01-01", state="unmatched")
        new_linked = receipt(date="2026-11-05", state="linked")
        out = self.js("receiptsSorted(input.list)", list=[new_linked, old_unmatched])
        self.assertEqual(out[0]["state"], "unmatched")

    def test_an_override_shows_before_the_snapshot_catches_up(self):
        out = self.js("receiptsWithOverrides(input.list, input.overrides)",
                      list=[receipt(id="rcpt-1", state="unmatched")],
                      overrides={"rcpt-1": {"state": "linked", "transactionId": "t1"}})
        self.assertEqual(out[0]["state"], "linked")


class Formatting(Harness):
    def test_the_subtitle_never_prints_undefined_for_a_bare_receipt(self):
        out = self.js("receiptSubtitle(input.r)", r=receipt(date=None, items=[], tax=None))
        self.assertNotIn("undefined", out)
        self.assertNotIn("NaN", out)

    def test_the_subtitle_counts_items_and_gst(self):
        out = self.js("receiptSubtitle(input.r)",
                      r=receipt(date="2026-11-05", items=[{"amount": 1}, {"amount": 2}], tax=17.03))
        self.assertIn("2 items", out)
        self.assertIn("17", out)

    def test_gst_lines_fold_one_slab_into_one_row(self):
        out = self.js("receiptGstLines(input.r)",
                      r=receipt(taxes=[{"rate": 5.0, "taxable": 340.47, "cgst": 8.52, "sgst": 8.52}]))
        self.assertEqual(len(out), 1)
        self.assertIn("5%", out[0]["label"])
        self.assertIn("17.04", out[0]["value"])

    def test_a_mismatch_between_items_and_the_total_is_warned(self):
        out = self.js("receiptWarnings(input.r)",
                      r=receipt(total=456.0, items=[{"amount": 100.0}]))
        self.assertTrue(any("add up to" in w for w in out))

    def test_a_bill_that_balances_with_discount_and_round_off_is_clean(self):
        # 1275.00 - 25.00 + 0.00 == 1250.00 (the FreshMart grocery bill).
        out = self.js("receiptWarnings(input.r)",
                      r=receipt(total=1250.0, subtotal=1275.0, discount=25.0, roundOff=0.0,
                               items=[{"amount": 1275.0}]))
        self.assertEqual(out, [])

    def test_a_discount_that_does_not_reconcile_is_warned(self):
        out = self.js("receiptWarnings(input.r)",
                      r=receipt(total=1250.0, subtotal=1275.0, discount=5.0, roundOff=0.0, items=[]))
        self.assertTrue(any("not the total" in w for w in out))

    def test_a_negative_discount_is_still_treated_as_a_positive_amount_off(self):
        # A hand edit (or an un-normalised old row) that left discount
        # negative must not flip the arithmetic to addition.
        out = self.js("receiptWarnings(input.r)",
                      r=receipt(total=1250.0, subtotal=1275.0, discount=-25.0, roundOff=0.0, items=[]))
        self.assertEqual(out, [])

    def test_items_sum_ignores_the_optional_qty_rate_hsn_fields(self):
        # The LLM path can send qty/unit/rate/hsn alongside amount (richer
        # schema, Stage B); receiptItemsSum must keep summing only amount.
        out = self.js("receiptItemsSum(input.r)",
                      r=receipt(items=[{"description": "X", "amount": 45.0,
                                       "qty": 2, "unit": "pc", "rate": 22.5, "hsn": "1905"}]))
        self.assertEqual(out, 45.0)

    def test_the_state_mark_distinguishes_to_link_from_check_this_parse(self):
        plain = self.js("receiptStateMark(input.r)", r=receipt(state="unmatched", needsReview=False))
        shaky = self.js("receiptStateMark(input.r)", r=receipt(state="unmatched", needsReview=True))
        self.assertEqual(plain["pill"], "TO LINK")
        self.assertEqual(shaky["pill"], "CHECK")

    def test_dates_print_dd_mm_yyyy_and_parse_back_to_iso(self):
        self.assertEqual(self.js("formatReceiptDate('2026-11-05')"), "05-11-2026")
        self.assertEqual(self.js("formatReceiptDate(null)"), "")
        self.assertEqual(self.js("parseReceiptDate('5-11-2026')"), "2026-11-05")
        self.assertEqual(self.js("parseReceiptDate('2026-11-05')"), "2026-11-05")
        self.assertEqual(self.js("parseReceiptDate('25/06/26')"), "2026-06-25")
        self.assertEqual(self.js("parseReceiptDate('')"), "")
        self.assertIsNone(self.js("parseReceiptDate('31-02-2026')"))
        self.assertIsNone(self.js("parseReceiptDate('yesterday')"))

    def test_tax_rows_split_a_slab_like_the_printout(self):
        out = self.js("receiptTaxRows(input.r)",
                      r=receipt(taxes=[{"rate": 5.0, "cgst": 8.52, "sgst": 8.52, "igst": None, "cess": 0}]))
        self.assertEqual([(x["label"], x["field"], x["value"], x["rate"]) for x in out],
                         [("CGST (2.5%)", "cgst", 8.52, 5.0), ("SGST (2.5%)", "sgst", 8.52, 5.0)])

    def test_summary_lines_follow_print_order_and_skip_what_is_absent(self):
        r = receipt(subtotal=460.82, discount=4.61, roundOff=-0.21,
                    taxes=[{"rate": 5.0, "cgst": 8.52, "sgst": 8.52}])
        out = self.js("receiptSummaryLines(input.r)", r=r)
        self.assertEqual([(x["label"], x["value"]) for x in out],
                         [("Subtotal", "460.82"), ("Bill Discount", "-4.61"), ("Round Off", "-0.21"),
                          ("CGST (2.5%)", "8.52"), ("SGST (2.5%)", "8.52")])
        self.assertEqual(self.js("receiptSummaryLines(input.r)", r=receipt()), [])

    def test_a_bill_with_tax_on_top_is_balanced(self):
        # Malabar Qissa: 772.80 - 0 - 0.44 + 38.64 GST = 811.00
        r = receipt(total=811.0, subtotal=772.8, discount=None, roundOff=-0.44,
                    items=[{"amount": 772.8}], taxes=[{"rate": 0, "cgst": 19.32, "sgst": 19.32}])
        self.assertTrue(self.js("receiptIsBalanced(input.r)", r=r))
        self.assertTrue(self.js("receiptTaxExclusive(input.r)", r=r))
        # ...and is still caught when the total is simply wrong.
        self.assertFalse(self.js("receiptIsBalanced(input.r)", r=dict(r, total=900.0)))

    def test_item_prices_that_include_gst_balance_against_the_subtotal_before_gst(self):
        # Loaded Restaurant: item 250, Sub Total 238.10, CGST + SGST 11.90, total 250.
        r = receipt(total=250.0, subtotal=238.10, discount=None, roundOff=None,
                    items=[{"amount": 250.0}], taxes=[{"rate": 5.0, "cgst": 5.95, "sgst": 5.95}])
        self.assertEqual(self.js("receiptTaxMode(input.r)", r=r), "inclusive")
        self.assertTrue(self.js("receiptIsBalanced(input.r)", r=r))
        self.assertEqual(self.js("receiptRecompute(input.r, 'inclusive')", r=r),
                         {"subtotal": 238.1, "total": 250.0})
        # the broken parse the screenshot showed is still flagged
        bad = dict(r, subtotal=250.0, total=261.9)
        self.assertEqual(self.js("receiptTaxMode(input.r)", r=bad), "on-top")

    def test_recompute_for_each_tax_mode(self):
        base = receipt(items=[{"amount": 100.0}], taxes=[{"rate": 5.0, "cgst": 2.5, "sgst": 2.5}],
                       discount=None, roundOff=None)
        self.assertEqual(self.js("receiptRecompute(input.r, 'inside')", r=base), {"subtotal": 100.0, "total": 100.0})
        self.assertEqual(self.js("receiptRecompute(input.r, 'on-top')", r=base), {"subtotal": 100.0, "total": 105.0})
        self.assertEqual(self.js("receiptRecompute(input.r, 'inclusive')", r=base), {"subtotal": 95.0, "total": 100.0})

    def test_an_inclusive_tax_bill_is_not_mistaken_for_tax_on_top(self):
        r = receipt(total=456.0, subtotal=460.82, discount=4.61, roundOff=-0.21,
                    items=[{"amount": 460.82}], taxes=[{"rate": 5.0, "cgst": 8.52, "sgst": 8.52}])
        self.assertFalse(self.js("receiptTaxExclusive(input.r)", r=r))
        self.assertTrue(self.js("receiptIsBalanced(input.r)", r=r))

    def test_a_missing_slab_rate_is_read_off_the_figures(self):
        r = receipt(subtotal=772.8, taxes=[{"rate": 0, "cgst": 19.32, "sgst": 19.32}], items=[])
        out = self.js("receiptTaxRows(input.r)", r=r)
        self.assertEqual([x["label"] for x in out], ["CGST (2.5%)", "SGST (2.5%)"])

    def test_the_info_rows_describe_the_photo_and_compare_its_date_to_the_bills(self):
        r = receipt(date="2026-06-25", imageMeta={"taken": "2026-06-26 08:01:09", "camera": "Google Pixel 8",
                                                  "width": 3000, "height": 4000, "format": "JPEG",
                                                  "size_bytes": 2411724, "file_name": "bill.jpg"},
                    importedAt="2026-11-06T10:00:00", parsedAt="2026-11-06T10:01:00", method="vision-llm:gemma")
        rows = dict((x["label"], x["value"]) for x in self.js("receiptInfoRows(input.r)", r=r))
        self.assertEqual(rows["Photo taken"], "26-06-2026 08:01")
        self.assertEqual(rows["Bill date vs photo"], "1 day apart")
        self.assertEqual(rows["Camera"], "Google Pixel 8")
        self.assertEqual(rows["Image"], "3000 × 4000 px  ·  JPEG  ·  2.3 MB")
        self.assertEqual(rows["File"], "bill.jpg")
        self.assertIn("vision-llm:gemma", rows["Last read"])

    def test_the_info_rows_say_which_date_was_used_and_what_the_bill_printed(self):
        r = receipt(date="2026-06-26", imageMeta={"taken": "2026-06-26 08:01:09", "date_source": "taken",
                                                  "printed_date": "2026-06-25"})
        rows = dict((x["label"], x["value"]) for x in self.js("receiptInfoRows(input.r)", r=r))
        self.assertEqual(rows["Date used"], "photo taken date")
        self.assertEqual(rows["Printed on the bill"], "2026-06-25")

    def test_the_photo_note_says_it_is_compressed_and_kept_never_deleted(self):
        saved = receipt(state="linked", imageSaved={"bytes": 145000, "originalBytes": 3200000})
        note = self.js("receiptPhotoNote(input.r)", r=saved)
        self.assertIn("kept in the database", note)
        self.assertIn("142 KB", note)
        self.assertIn("3.1 MB", note)
        self.assertNotIn("deleted in", note)
        self.assertIn("will be compressed", self.js("receiptPhotoNote(input.r)", r=receipt(state="linked")))
        self.assertEqual(self.js("receiptPhotoNote(input.r)", r=receipt(state="unmatched")), "")
        self.assertEqual(self.js("receiptPhotoNote(input.r)", r=receipt(imageDeleted=True)), "Photo deleted")

    def test_a_bill_with_no_metadata_has_only_what_it_knows(self):
        rows = self.js("receiptInfoRows(input.r)", r=receipt(importedAt="2026-11-06T10:00:00"))
        self.assertEqual([x["label"] for x in rows], ["Imported"])

    def test_changing_a_quantity_keeps_the_gst_a_line_was_printed_with(self):
        toblerone = {"qty": 1, "unit": "pc", "rate": 228.72, "amount": 240.16}
        self.assertEqual(self.js("receiptLineAmount(input.i, 2, 228.72)", i=toblerone), 480.32)   # 2 pc, still +5%
        arum = {"qty": 1.444, "unit": "kg", "rate": 71.35, "amount": 103.31}
        self.assertEqual(self.js("receiptLineAmount(input.i, 2, 71.35)", i=arum), 142.7)          # rounding is not GST
        plain = {"qty": 3, "unit": "pc", "rate": 50, "amount": 150}
        self.assertEqual(self.js("receiptLineAmount(input.i, 4, 50)", i=plain), 200.0)
        none = {"qty": None, "unit": "pc", "rate": None, "amount": 45}
        self.assertEqual(self.js("receiptLineAmount(input.i, 2, 10)", i=none), 20.0)

    def test_the_unit_never_changes_the_arithmetic(self):
        for unit in ("pc", "pcs", "kg", "L", None):
            item = {"qty": 3, "unit": unit, "rate": 50, "amount": 150}
            self.assertEqual(self.js("receiptLineAmount(input.i, 3, 50)", i=item), 150.0)

    def test_a_platform_fee_on_top_balances_and_is_counted_by_recompute(self):
        # Flipkart: 3795 + 10 platform fee = 3805
        r = receipt(total=3805.0, subtotal=3795.0, discount=None, roundOff=None, taxes=[],
                    items=[{"amount": 3795.0}], fees=[{"line": 1, "label": "Platform Fee", "amount": 10.0}])
        self.assertTrue(self.js("receiptIsBalanced(input.r)", r=r))
        self.assertEqual(self.js("receiptFeesSum(input.r)", r=r), 10.0)
        self.assertEqual(self.js("receiptRecompute(input.r, 'inside')", r=r), {"subtotal": 3795.0, "total": 3805.0})
        self.assertFalse(self.js("receiptIsBalanced(input.r)", r=dict(r, fees=[])))
        lines = self.js("receiptSummaryLines(input.r)", r=r)
        self.assertEqual([(x["label"], x["value"]) for x in lines], [("Subtotal", "3795.00"), ("Platform Fee", "10.00")])

    def test_fees_do_not_make_a_gst_inclusive_bill_look_tax_on_top(self):
        # 250 (GST included) + 20 fee: total 270, subtotal 238.10, tax 11.90
        r = receipt(total=270.0, subtotal=238.10, items=[{"amount": 250.0}],
                    taxes=[{"rate": 5.0, "cgst": 5.95, "sgst": 5.95}], fees=[{"line": 1, "label": "Delivery", "amount": 20.0}])
        self.assertEqual(self.js("receiptTaxMode(input.r)", r=r), "inclusive")
        self.assertTrue(self.js("receiptIsBalanced(input.r)", r=r))

    def test_quantities_print_like_the_bill(self):
        self.assertEqual(self.js("formatQty({qty: 1, unit: 'pc'})"), "1 pc")
        self.assertEqual(self.js("formatQty({qty: 1.444, unit: 'kg'})"), "1.444kg")
        self.assertEqual(self.js("formatQty({qty: null, unit: 'kg'})"), "")

    def test_adding_or_removing_a_product_moves_the_balance_check(self):
        base = dict(total=100.0, subtotal=100.0, discount=0.0, roundOff=0.0)
        ok = receipt(**base, items=[{"amount": 60.0}, {"amount": 40.0}])
        short = receipt(**base, items=[{"amount": 60.0}])
        self.assertTrue(self.js("receiptIsBalanced(input.r)", r=ok))
        self.assertFalse(self.js("receiptIsBalanced(input.r)", r=short))
        self.assertEqual(self.js("receiptItemCount(input.r)", r=short), 1)

    def test_a_clean_bill_is_balanced(self):
        out = self.js("receiptIsBalanced(input.r)",
                      r=receipt(total=456.0, subtotal=460.82, discount=4.61, roundOff=-0.21,
                               items=[{"amount": 460.82}]))
        self.assertTrue(out)

    def test_a_hand_edit_that_breaks_the_arithmetic_flips_the_state_mark_to_check(self):
        # needsReview was already False (the parser was confident) - a live
        # imbalance, from a hand edit, must still raise the flag on its own.
        r = receipt(state="unmatched", needsReview=False, total=456.0, subtotal=460.82,
                   discount=1.0, roundOff=0.0, items=[{"amount": 460.82}])
        self.assertFalse(self.js("receiptIsBalanced(input.r)", r=r))
        self.assertEqual(self.js("receiptStateMark(input.r)", r=r)["pill"], "CHECK")


class Matching(Harness):
    """Mirrors receipt-ledger-stitcher/tests/test_logic.py::Matching."""

    def test_exact_amount_same_day_and_name_scores_high(self):
        out = self.js("receiptMatchScore(input.r, input.t)", r=receipt(), t=txn())
        self.assertGreaterEqual(out["score"], 85)
        self.assertIn("exact amount", out["reasons"])

    def test_money_in_is_never_a_candidate(self):
        out = self.js("receiptMatchScore(input.r, input.t)", r=receipt(), t=txn(amount=456.0))
        self.assertEqual(out["score"], 0)

    def test_a_different_merchant_is_penalised_not_merely_unrewarded(self):
        # The real near-miss: a 250 restaurant bill and a 250 PVR Inox
        # ticket three days apart. Amount and date alone rank it as a good
        # match; only the name says otherwise.
        r = receipt(merchant="LOADED RESTAURANT", date="2026-09-16", total=250.0)
        t = txn(date="2026-09-19", merchant="Upi-pvr Inox Limited", amount=-250.0)
        out = self.js("receiptMatchScore(input.r, input.t)", r=r, t=t)
        self.assertLess(out["score"], 85)
        self.assertIn("merchant does not match", out["reasons"])

    def test_a_name_inside_a_longer_one_still_counts(self):
        r = receipt(merchant="K.S.B.C. 6020-CHINNAKANAL", date="2026-08-30", total=2550.0)
        t = txn(date="2026-08-30", amount=-2550.0, merchant="UPI/P2M/165729881322/KSBC FL01 6020 CHINNA/Liq")
        out = self.js("receiptMatchScore(input.r, input.t)", r=r, t=t)
        self.assertGreaterEqual(out["score"], 85)

    def test_rails_and_reference_numbers_are_not_merchant_words(self):
        out = self.js("Object.keys(_receiptTokens(input.text))", text="UPI/P2M/165729881322/HDFC BANK")
        self.assertEqual(out, [])

    def test_untracked_only_filters_the_candidates(self):
        txns = [txn(id="tracked-one", tracked=True)]
        none = self.js("receiptCandidates(input.r, input.txns, {untrackedOnly: true})",
                       r=receipt(), txns=txns)
        some = self.js("receiptCandidates(input.r, input.txns, {untrackedOnly: false})",
                       r=receipt(), txns=txns)
        self.assertEqual(none, [])
        self.assertEqual(len(some), 1)

    def test_excluded_ids_drop_a_transaction_another_receipt_already_holds(self):
        txns = [txn(id="claimed")]
        out = self.js("receiptCandidates(input.r, input.txns, {excludeIds: input.ex})",
                      r=receipt(), txns=txns, ex={"claimed": True})
        self.assertEqual(out, [])

    def test_candidates_are_ranked_best_first(self):
        txns = [txn(id="far", date="2026-11-01", amount=-456.0),
                txn(id="same-day", date="2026-11-05", amount=-456.0)]
        out = self.js("receiptCandidates(input.r, input.txns, {})", r=receipt(), txns=txns)
        self.assertEqual(out[0]["txn"]["id"], "same-day")

    def test_a_same_day_transaction_shows_up_even_with_a_wrong_total(self):
        # A bad OCR/LLM read (the exact case a human needs the picker for)
        # scores 0 against the real transaction, since the amount is wrong.
        # It must still appear, not vanish from the list entirely.
        r = receipt(merchant="MANDI MANZIL", date="2026-11-04", total=1592.0)
        t = txn(id="real", date="2026-11-04", amount=-882.0, merchant="Upi-mandi Manzil")
        out = self.js("receiptCandidates(input.r, input.txns, {})", r=r, txns=[t])
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["txn"]["id"], "real")

    def test_same_day_rows_sort_ahead_of_a_higher_score_elsewhere(self):
        txns = [txn(id="far-but-exact", date="2026-11-01", amount=-456.0),
                txn(id="same-day-no-match", date="2026-11-05", amount=-1.0, merchant="Nobody")]
        out = self.js("receiptCandidates(input.r, input.txns, {})", r=receipt(), txns=txns)
        self.assertEqual(out[0]["txn"]["id"], "same-day-no-match")

    def test_the_same_amount_on_the_same_date_is_flagged_as_a_match(self):
        same = txn(id="same", date="2026-11-05", amount=-456.0)
        other_day = txn(id="other", date="2026-11-06", amount=-456.0)
        other_amt = txn(id="amt", date="2026-11-05", amount=-100.0, merchant="Nobody")
        out = self.js("receiptCandidates(input.r, input.txns, {nearDays: 3})", r=receipt(),
                      txns=[same, other_day, other_amt])
        by_id = dict((o["txn"]["id"], o) for o in out)
        self.assertTrue(by_id["same"]["match"])
        self.assertTrue(by_id["other"]["exact"] and not by_id["other"]["match"])
        self.assertFalse(by_id["amt"]["exact"] or by_id["amt"]["match"])
        self.assertEqual(out[0]["txn"]["id"], "same")

    def test_nearby_days_are_offered_even_at_score_zero(self):
        near = txn(id="near", date="2026-11-07", amount=-5.0, merchant="Nobody")
        far = txn(id="far", date="2026-12-25", amount=-5.0, merchant="Nobody")
        out = self.js("receiptCandidates(input.r, input.txns, {nearDays: 3})", r=receipt(), txns=[near, far])
        self.assertEqual([o["txn"]["id"] for o in out], ["near"])
        self.assertTrue(any("apart" in x for x in out[0]["reasons"]))
        self.assertEqual(self.js("receiptCandidates(input.r, input.txns, {})", r=receipt(), txns=[near]), [])

    def test_a_zero_score_same_day_row_is_still_included(self):
        t = txn(date="2026-11-05", amount=-1.0, merchant="Nobody")
        out = self.js("receiptCandidates(input.r, input.txns, {})", r=receipt(), txns=[t])
        self.assertEqual(out[0]["score"], 0)

    def test_every_same_day_transaction_survives_a_tight_limit(self):
        # A date with more transactions than the limit used to lose the
        # overflow silently - exactly the day a human most needs "show me
        # everything that happened that day" to actually mean everything.
        txns = [txn(id="t%d" % i, date="2026-11-05", amount=-float(i + 1), merchant="Nobody")
               for i in range(10)]
        out = self.js("receiptCandidates(input.r, input.txns, {limit: 3})", r=receipt(), txns=txns)
        self.assertEqual(len(out), 10)


class LinkedReceiptNote(Harness):
    def test_an_unlinked_transaction_has_no_receipt_note(self):
        out = self.js("receiptNoteForTransaction(input.t, input.receipts)",
                      t=txn(id="t1"), receipts=[receipt(state="unmatched", transactionId=None)])
        self.assertEqual(out, "")

    def test_a_linked_receipts_merchant_and_items_become_the_note(self):
        r = receipt(state="linked", transactionId="t1", merchant="FRESH MART",
                   items=[{"description": "Rice (Matta)"}, {"description": "Sunflower Oil"}])
        out = self.js("receiptNoteForTransaction(input.t, input.receipts)", t=txn(id="t1"), receipts=[r])
        self.assertIn("FRESH MART", out)
        self.assertIn("Rice (Matta)", out)
        self.assertIn("Sunflower Oil", out)

    def test_a_receipt_linked_to_a_different_transaction_is_not_the_note(self):
        r = receipt(state="linked", transactionId="other", merchant="FRESH MART")
        out = self.js("receiptNoteForTransaction(input.t, input.receipts)", t=txn(id="t1"), receipts=[r])
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
