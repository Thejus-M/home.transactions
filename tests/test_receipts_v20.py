"""Schema v20 and the app-order bill (printed total, waived charges, bill
category): migration on a v19 copy, save_parse, snapshot, recalc, overrides."""
import sqlite3
import tempfile
import unittest
from pathlib import Path

from txdb import db, receipts

KOTTAYAM = {
    "image_sha256": "k" * 64, "stored_path": "receipts/kk/k.jpg", "merchant": "Kottayam Kitchen",
    "date": "2026-11-05", "total_paise": 16000, "printed_total_paise": 16000, "subtotal_paise": 17900,
    "discount_paise": 4400, "tax_paise": 675, "payment_hint": None, "confidence": 90,
    "needs_review": False, "warnings": [], "raw_text": "x",
    "platform": "Swiggy", "order_id": "253090652144251", "payment_method": "Bank",
    "saved_paise": 6200, "llm_json": '{"merchant": "Kottayam Kitchen"}',
    "category": {"category": "Food Out", "subcategory": "Delivery"},
    "items": [{"description": "Biryani", "qty": 1, "amount": 179.0}], "taxes": [],
    "fees": [{"label": "Restaurant Packaging", "amount": 0, "original": 9.0, "waived": True},
             {"label": "Platform fee with GST", "amount": 17.98, "original": None, "waived": False},
             {"label": "Delivery Fee", "amount": 0, "original": 25.0, "waived": True},
             {"label": "empty", "amount": 0}],
}


class V20(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def snap(self):
        return receipts.snapshot(self.conn)["receipts"][0]

    def test_migration_from_v19_keeps_data_backs_up_and_shows_new_columns(self):
        old = Path(self.dir.name) / "old.db"
        c = sqlite3.connect(old, isolation_level=None)
        c.row_factory = sqlite3.Row
        for i in range(19):
            step = db.MIGRATIONS[i]
            if callable(step):
                step(c)
            else:
                for st in db._statements(step):
                    c.execute(st)
            c.execute(f"PRAGMA user_version={i + 1}")
        c.execute("INSERT INTO receipts (id, image_sha256, stored_path, merchant, total_paise, parsed_at, imported_at) "
                  "VALUES ('rcpt-x', 'x', 'p', 'Shop', 500, 'n', 'n')")
        c.execute("INSERT INTO receipt_fees VALUES ('rcpt-x', 1, 'Fee', 100)")
        c.close()
        conn = db.connect(old)
        self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], len(db.MIGRATIONS))
        row = receipts.snapshot(conn)["receipts"][0]
        self.assertEqual((row["merchant"], row["total"], row["printedTotal"], row["platform"], row["category"]),
                         ("Shop", 5.0, None, None, None))
        self.assertEqual(row["fees"], [{"line": 1, "label": "Fee", "amount": 1.0, "original": None, "waived": False}])
        backups = list((Path(self.dir.name) / "backups").glob("pre-v20-*.db"))
        self.assertEqual(len(backups), 1)
        b = sqlite3.connect(backups[0])
        self.assertEqual(b.execute("PRAGMA user_version").fetchone()[0], 19)   # the copy is the old schema
        b.close()
        conn.close()
        db.connect(old).close()                                                # idempotent: no second backup
        self.assertEqual(len(list((Path(self.dir.name) / "backups").glob("pre-v20-*.db"))), 1)

    def test_save_parse_keeps_waived_fees_and_the_new_fields(self):
        receipts.save_parse(self.conn, KOTTAYAM)
        r = self.snap()
        self.assertEqual([(f["label"], f["amount"], f["original"], f["waived"]) for f in r["fees"]],
                         [("Restaurant Packaging", 0.0, 9.0, True), ("Platform fee with GST", 17.98, None, False),
                          ("Delivery Fee", 0.0, 25.0, True)])                  # the plain zero fee is dropped
        self.assertEqual((r["platform"], r["orderId"], r["paymentMethod"], r["printedTotal"], r["saved"]),
                         ("Swiggy", "253090652144251", "Bank", 160.0, 62.0))
        self.assertEqual(r["category"]["category"], "Food Out")
        self.assertEqual(r["category"]["source"], "llm")
        self.assertEqual(r["tax"], 6.75)

    def test_old_style_rows_without_the_new_keys_still_save(self):
        rid = receipts.save_parse(self.conn, dict(KOTTAYAM, **{k: None for k in (
            "platform", "order_id", "payment_method", "printed_total_paise", "saved_paise", "llm_json", "category")},
            fees=[{"label": "Fee", "amount": 5.0}]))
        r = self.snap()
        self.assertEqual((r["printedTotal"], r["category"], r["fees"][0]["waived"]), (None, None, False))
        self.assertEqual(rid, r["id"])

    def test_a_user_category_survives_a_reread_and_an_llm_one_is_replaced(self):
        rid = receipts.save_parse(self.conn, KOTTAYAM)
        receipts.save_parse(self.conn, dict(KOTTAYAM, category={"category": "Groceries", "subcategory": ""}))
        self.assertEqual(self.snap()["category"]["category"], "Groceries")      # llm row replaced
        receipts.set_category(self.conn, rid, "Shopping", "Gifts")
        receipts.save_parse(self.conn, dict(KOTTAYAM, category={"category": "Food Out", "subcategory": "Delivery"}))
        c = self.snap()["category"]
        self.assertEqual((c["category"], c["subcategory"], c["source"]), ("Shopping", "Gifts", "user"))
        receipts.set_category(self.conn, rid, "")                               # empty removes the user row
        self.assertIsNone(self.snap()["category"])

    def test_recalc_never_changes_the_printed_total_and_keeps_the_warning(self):
        rid = receipts.save_parse(self.conn, dict(KOTTAYAM, taxes=[], tax_paise=None, needs_review=True,
                                                 warnings=["parts do not add up"]))
        receipts.recalc_totals(self.conn, rid, clear_flags=True)
        r = self.snap()
        self.assertEqual((r["printedTotal"], r["total"], r["subtotal"]), (160.0, 160.0, 179.0))
        self.assertEqual((r["warnings"], r["needsReview"]), (["parts do not add up"], True))   # 152.98 vs 160

    def test_recalc_clears_the_flags_when_the_parts_match(self):
        rid = receipts.save_parse(self.conn, dict(KOTTAYAM, needs_review=True, warnings=["old"]))
        receipts.recalc_totals(self.conn, rid, clear_flags=True)
        r = self.snap()
        self.assertEqual((r["printedTotal"], r["total"], r["warnings"], r["needsReview"]), (160.0, 160.0, [], False))

    def test_use_computed_is_the_only_way_to_replace_the_printed_total(self):
        rid = receipts.save_parse(self.conn, dict(KOTTAYAM, printed_total_paise=13500, total_paise=13500))
        receipts.recalc_totals(self.conn, rid)
        self.assertEqual(self.snap()["printedTotal"], 135.0)
        receipts.use_computed_total(self.conn, rid)
        r = self.snap()
        self.assertEqual((r["printedTotal"], r["total"]), (159.73, 159.73))

    def test_recalc_without_a_printed_total_keeps_the_old_behaviour(self):
        rid = receipts.save_parse(self.conn, dict(KOTTAYAM, printed_total_paise=None, total_paise=99999,
                                                 subtotal_paise=17900))
        receipts.recalc_totals(self.conn, rid)
        r = self.snap()
        self.assertEqual((r["printedTotal"], r["total"]), (None, 159.73))

    def test_edit_fields_and_fee_flags(self):
        rid = receipts.save_parse(self.conn, KOTTAYAM)
        receipts.edit_field(self.conn, rid, "printed_total", "161")
        receipts.edit_field(self.conn, rid, "platform", "Zomato")
        receipts.edit_field(self.conn, rid, "order_id", "9")
        receipts.edit_field(self.conn, rid, "payment_method", "UPI")
        r = self.snap()
        self.assertEqual((r["printedTotal"], r["total"], r["platform"], r["orderId"], r["paymentMethod"]),
                         (161.0, 161.0, "Zomato", "9", "UPI"))
        receipts.edit_fee(self.conn, rid, "1", "waived", "0")                   # un-waive: the original comes back
        receipts.edit_fee(self.conn, rid, "2", "waived", "1")
        fees = self.snap()["fees"]
        self.assertEqual((fees[0]["amount"], fees[0]["waived"]), (9.0, False))
        self.assertEqual((fees[1]["amount"], fees[1]["waived"]), (0.0, True))
        line = receipts.add_fee(self.conn, rid, "Tip", "0", "10", "1")
        self.assertTrue(self.snap()["fees"][line - 1]["waived"])


if __name__ == "__main__":
    unittest.main()
