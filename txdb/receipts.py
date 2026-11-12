"""Photographed shop bills, and which transaction each one paid for.

Stdlib only, like the rest of `txdb`: the reading of a photo happens in the
separate receipt-reader project, which needs OCR and a machine-learning
stack; what arrives here is already a dict of figures. Keeping the two apart
is what lets the widget's database stay dependency-free.

Two halves, deliberately separate:

* `save_parse` owns what the parser read. It may be re-run whenever the
  parser improves, and replaces the items and taxes wholesale.
* `set_link` / `clear_link` own what the user decided. A re-parse never
  touches them, the same way re-fetching a bank statement never clears a
  `tracked` flag.

Identity is the sha256 of the image bytes, so the same photo under a second
name is the same receipt, and re-importing a folder is free.
"""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime

from .db import now, to_paise, write

ITEM_FIELDS = ("description", "hsn", "qty_e4", "unit", "rate_paise", "amount_paise", "gst_rate_e2")
TAX_FIELDS = ("rate_e2", "taxable_paise", "cgst_paise", "sgst_paise", "igst_paise", "cess_paise")
HEADER_FIELDS = (
    "image_sha256", "stored_path", "thumb_path", "source_path", "source_mtime", "source_size",
    "rotation", "merchant", "gstin", "date", "time", "invoice_no", "total_paise",
    "subtotal_paise", "tax_paise", "discount_paise", "round_off_paise", "payment_hint",
    "currency", "before_payment", "method", "confidence", "needs_review", "warnings",
    "raw_text", "parser_version", "image_meta",
    "platform", "order_id", "payment_method", "printed_total_paise", "saved_paise", "llm_json",
)
STATES = ("linked", "cash", "ignored")


def receipt_id(image_sha256: str) -> str:
    return "rcpt-" + image_sha256[:16]


def _e4(value) -> int | None:
    return None if value is None else int(round(float(value) * 10000))


def _e2(value) -> int | None:
    return None if value is None else int(round(float(value) * 100))


def save_parse(conn: sqlite3.Connection, parsed: dict) -> str:
    """Write (or re-write) one receipt. Returns its id.

    Everything the parser produces is replaced; nothing the user decided is
    touched. `imported_at` and the stored file keep their original values, so
    re-parsing never looks like a new import.
    """
    sha = parsed["image_sha256"]
    rid = receipt_id(sha)
    ts = now()
    header = {f: parsed.get(f) for f in HEADER_FIELDS}
    header["image_sha256"] = sha
    header["currency"] = parsed.get("currency") or "INR"
    header["rotation"] = int(parsed.get("rotation") or 0)
    header["before_payment"] = int(bool(parsed.get("before_payment")))
    header["needs_review"] = int(bool(parsed.get("needs_review", True)))
    header["confidence"] = int(parsed.get("confidence") or 0)
    header["parser_version"] = str(parsed.get("parser_version") or "1")
    # Columns the schema declares NOT NULL: passing None explicitly defeats
    # the column default, so they are filled here rather than left out.
    header["raw_text"] = parsed.get("raw_text") or ""
    if not header["stored_path"]:
        raise SystemExit("A receipt needs the path of the stored image")
    if isinstance(header.get("warnings"), (list, tuple)):
        header["warnings"] = json.dumps(list(header["warnings"]), ensure_ascii=False)
    if isinstance(header.get("image_meta"), dict):
        header["image_meta"] = json.dumps(header["image_meta"], ensure_ascii=False)

    columns = ", ".join(HEADER_FIELDS)
    placeholders = ", ".join("?" * len(HEADER_FIELDS))
    updates = ", ".join(f"{f} = excluded.{f}" for f in HEADER_FIELDS
                        if f not in ("stored_path", "thumb_path"))
    with write(conn):
        conn.execute(
            f"INSERT INTO receipts (id, {columns}, parsed_at, imported_at) "
            f"VALUES (?, {placeholders}, ?, ?) "
            f"ON CONFLICT(id) DO UPDATE SET {updates}, parsed_at = excluded.parsed_at, "
            # A re-parse must not pretend the photo arrived again, and must
            # not lose the copy already stored if this run did not make one.
            "stored_path = COALESCE(excluded.stored_path, receipts.stored_path), "
            "thumb_path = COALESCE(excluded.thumb_path, receipts.thumb_path)",
            (rid, *[header[f] for f in HEADER_FIELDS], ts, ts))

        conn.execute("DELETE FROM receipt_items WHERE receipt_id = ?", (rid,))
        for n, item in enumerate(parsed.get("items") or [], start=1):
            row = {
                "description": str(item.get("description") or "").strip() or "(unnamed)",
                "hsn": item.get("hsn"),
                "qty_e4": _e4(item.get("qty")),
                "unit": item.get("unit"),
                "rate_paise": to_paise(item.get("rate")),
                "amount_paise": to_paise(item.get("amount")),
                "gst_rate_e2": _e2(item.get("gst_rate")),
            }
            conn.execute(
                f"INSERT INTO receipt_items (receipt_id, line_no, {', '.join(ITEM_FIELDS)}) "
                f"VALUES (?, ?, {', '.join('?' * len(ITEM_FIELDS))})",
                (rid, n, *[row[f] for f in ITEM_FIELDS]))

        conn.execute("DELETE FROM receipt_fees WHERE receipt_id = ?", (rid,))
        for n, fee in enumerate(parsed.get("fees") or [], start=1):
            amount = to_paise(fee.get("amount"))
            original = to_paise(fee.get("original"))
            waived = bool(fee.get("waived"))
            # A waived charge is amount 0 with the struck-through original;
            # a plain zero fee (no original, not waived) says nothing.
            if amount or waived:
                conn.execute(
                    "INSERT INTO receipt_fees (receipt_id, line_no, label, amount_paise, original_paise, waived) "
                    "VALUES (?,?,?,?,?,?)",
                    (rid, n, str(fee.get("label") or "").strip() or "Fee", abs(amount or 0),
                     None if original is None else abs(original), int(waived)))

        conn.execute("DELETE FROM receipt_taxes WHERE receipt_id = ?", (rid,))
        seen: set[int] = set()
        for tax in parsed.get("taxes") or []:
            rate = _e2(tax.get("rate")) or 0
            if rate in seen:
                continue
            seen.add(rate)
            row = {"rate_e2": rate, "taxable_paise": to_paise(tax.get("taxable")),
                   "cgst_paise": to_paise(tax.get("cgst")), "sgst_paise": to_paise(tax.get("sgst")),
                   "igst_paise": to_paise(tax.get("igst")), "cess_paise": to_paise(tax.get("cess"))}
            conn.execute(
                f"INSERT INTO receipt_taxes ({', '.join(TAX_FIELDS)}, receipt_id) "
                f"VALUES ({', '.join('?' * len(TAX_FIELDS))}, ?)",
                (*[row[f] for f in TAX_FIELDS], rid))

        _save_llm_category(conn, rid, parsed.get("category"), ts)
    return rid


def _save_llm_category(conn: sqlite3.Connection, rid: str, category, ts: str) -> None:
    """The model's pick goes in as source 'llm', replacing an older 'llm' row
    but never a row the user chose (source 'user')."""
    if not isinstance(category, dict):
        return
    name = str(category.get("category") or "").strip()
    if not name:
        return
    sub = str(category.get("subcategory") or "").strip()
    conn.execute(
        "INSERT INTO receipt_categories (receipt_id, category, subcategory, source, updated_at) "
        "VALUES (?,?,?,'llm',?) ON CONFLICT(receipt_id) DO UPDATE SET category = excluded.category, "
        "subcategory = excluded.subcategory, source = 'llm', updated_at = excluded.updated_at "
        "WHERE receipt_categories.source != 'user'", (rid, name, sub, ts))


def set_category(conn: sqlite3.Connection, rid: str, category: str | None, subcategory: str | None = None) -> None:
    """The user's own category for a bill. An empty category removes the
    user's choice (a model pick, if any, comes back with the next read)."""
    _require(conn, rid)
    name = (category or "").strip()
    with write(conn):
        if not name:
            conn.execute("DELETE FROM receipt_categories WHERE receipt_id = ? AND source = 'user'", (rid,))
            return
        conn.execute(
            "INSERT INTO receipt_categories (receipt_id, category, subcategory, source, updated_at) "
            "VALUES (?,?,?,'user',?) ON CONFLICT(receipt_id) DO UPDATE SET category = excluded.category, "
            "subcategory = excluded.subcategory, source = 'user', updated_at = excluded.updated_at",
            (rid, name, (subcategory or "").strip(), now()))


def use_computed_total(conn: sqlite3.Connection, rid: str) -> None:
    """The ONLY way the printed total is replaced: an explicit override (the
    "Use computed total" button). The new printed total (and the stored total)
    is what the parts add up to; with no items to add up, the stored total is
    simply taken as the printed one."""
    _require(conn, rid)
    p = _parts(conn, rid)
    if conn.execute("SELECT COUNT(*) FROM receipt_items WHERE receipt_id = ?", (rid,)).fetchone()[0]:
        value = _parts_total(p)
    else:
        value = p["old_total"]
    if value is None:
        return
    with write(conn):
        conn.execute("UPDATE receipts SET printed_total_paise = ?, total_paise = ? WHERE id = ?", (value, value, rid))


def _require(conn: sqlite3.Connection, rid: str) -> None:
    if conn.execute("SELECT 1 FROM receipts WHERE id = ?", (rid,)).fetchone() is None:
        raise SystemExit(f"Unknown receipt {rid}")


def set_link(conn: sqlite3.Connection, rid: str, transaction_id: str | None = None,
             state: str = "linked", matched_by: str = "manual", score: int | None = None) -> None:
    """File a receipt against a transaction, or park it."""
    _require(conn, rid)
    if state not in STATES:
        raise SystemExit(f"Unknown state {state!r}; expected one of {', '.join(STATES)}")
    if (state == "linked") != bool(transaction_id):
        raise SystemExit("A linked receipt needs a transaction, and a parked one must not have one")
    if transaction_id:
        held = conn.execute(
            "SELECT receipt_id FROM receipt_links WHERE transaction_id = ? AND receipt_id != ?",
            (transaction_id, rid)).fetchone()
        if held:
            raise SystemExit(f"That transaction already has receipt {held[0]} filed against it")
    with write(conn):
        conn.execute(
            "INSERT INTO receipt_links (receipt_id, transaction_id, state, matched_by, score, "
            "linked_at) VALUES (?,?,?,?,?,?) ON CONFLICT(receipt_id) DO UPDATE SET "
            "transaction_id = excluded.transaction_id, state = excluded.state, "
            "matched_by = excluded.matched_by, score = excluded.score, "
            "linked_at = excluded.linked_at",
            (rid, transaction_id, state, matched_by, score, now()))


def clear_link(conn: sqlite3.Connection, rid: str) -> None:
    """Back to the top of the list."""
    _require(conn, rid)
    with write(conn):
        conn.execute("DELETE FROM receipt_links WHERE receipt_id = ?", (rid,))


def set_review(conn: sqlite3.Connection, rid: str, needs_review: bool) -> None:
    _require(conn, rid)
    with write(conn):
        conn.execute("UPDATE receipts SET needs_review = ? WHERE id = ?",
                     (int(needs_review), rid))


def forget(conn: sqlite3.Connection, rid: str) -> None:
    """Drop the row; the caller removes the stored image."""
    _require(conn, rid)
    with write(conn):
        conn.execute("DELETE FROM receipts WHERE id = ?", (rid,))


def remove_receipt(conn: sqlite3.Connection, rid: str) -> list[str]:
    """Remove a bill altogether: its row, items, taxes, filing and the photo
    kept in the database go; the photo's fingerprint is remembered so the
    importer never brings it back. Returns the stored paths the caller must
    delete from disk. (The original photo in the import folder is not
    touched.)"""
    _require(conn, rid)
    row = conn.execute("SELECT image_sha256, stored_path, thumb_path FROM receipts WHERE id = ?",
                       (rid,)).fetchone()
    with write(conn):
        conn.execute("INSERT OR REPLACE INTO removed_receipts (image_sha256, removed_at) VALUES (?, ?)",
                     (row["image_sha256"], now()))
        conn.execute("DELETE FROM receipts WHERE id = ?", (rid,))
    return [p for p in (row["stored_path"], row["thumb_path"]) if p]


def removed_hashes(conn: sqlite3.Connection) -> set[str]:
    return {r[0] for r in conn.execute("SELECT image_sha256 FROM removed_receipts")}


def save_image(conn: sqlite3.Connection, rid: str, data: bytes, mime: str = "image/jpeg",
               width: int | None = None, height: int | None = None,
               original_bytes: int | None = None) -> None:
    """Keep the (compressed) photo inside the database. Nothing is ever
    deleted: a re-compress simply replaces this copy."""
    _require(conn, rid)
    with write(conn):
        conn.execute(
            "INSERT INTO receipt_images (receipt_id, mime, width, height, bytes, original_bytes, data, saved_at) "
            "VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(receipt_id) DO UPDATE SET mime = excluded.mime, "
            "width = excluded.width, height = excluded.height, bytes = excluded.bytes, "
            "original_bytes = excluded.original_bytes, data = excluded.data, saved_at = excluded.saved_at",
            (rid, mime, width, height, len(data), original_bytes, data, now()))


def mark_image_deleted(conn: sqlite3.Connection, rid: str) -> None:
    """The on-disk photo at `stored_path` is gone (the caller deletes it once
    its bytes are safely kept in `receipt_images`, see compress_linked in the
    receipt reader). The database's own copy is untouched; the snapshot's
    `storedPath` then reads None and the widget falls back to it."""
    _require(conn, rid)
    with write(conn):
        conn.execute("UPDATE receipts SET image_deleted = 1 WHERE id = ?", (rid,))


def image_data(conn: sqlite3.Connection, rid: str) -> tuple[bytes, str] | None:
    row = conn.execute("SELECT data, mime FROM receipt_images WHERE receipt_id = ?", (rid,)).fetchone()
    return (bytes(row["data"]), row["mime"]) if row else None


def export_image(conn: sqlite3.Connection, rid: str, dest) -> bool:
    """Write the database's copy of the photo to `dest` (e.g. when the file on
    disk has gone missing). False when there is no copy."""
    found = image_data(conn, rid)
    if found is None:
        return False
    from pathlib import Path
    target = Path(dest)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(found[0])
    return True


def linked_without_saved_image(conn: sqlite3.Connection) -> list[dict]:
    """Linked bills whose photo is not yet compressed into the database."""
    rows = conn.execute(
        "SELECT r.id, r.stored_path FROM receipts r JOIN receipt_links l ON l.receipt_id = r.id "
        "WHERE l.state = 'linked' AND r.image_deleted = 0 "
        "AND NOT EXISTS (SELECT 1 FROM receipt_images i WHERE i.receipt_id = r.id)").fetchall()
    return [{"id": r["id"], "stored_path": r["stored_path"]} for r in rows]


# A human correcting a field by hand, kept apart from save_parse (what the
# parser read) the same way set_link is kept apart from it. Note: a re-parse
# DOES replace every header figure, items, fees and taxes (save_parse), so a
# hand edit to those is lost on a re-read; only the link and the user's
# category survive one. Only money columns need the paise conversion; the
# rest are plain text.
EDITABLE_FIELDS = {
    "merchant", "date", "time", "invoice_no", "gstin", "payment_hint",
    "total", "subtotal", "discount", "round_off",
    "printed_total", "platform", "order_id", "payment_method", "tax",
}
_MONEY_FIELDS = {"total", "subtotal", "discount", "round_off", "printed_total", "tax"}


def edit_field(conn: sqlite3.Connection, rid: str, field: str, value: str | None) -> None:
    """Set one field on a receipt by hand. `value` is whatever text the
    widget's TextField held; an empty string clears the field to NULL."""
    _require(conn, rid)
    if field not in EDITABLE_FIELDS:
        raise SystemExit(f"Unknown or non-editable field {field!r}; "
                         f"expected one of {', '.join(sorted(EDITABLE_FIELDS))}")
    column = f"{field}_paise" if field in _MONEY_FIELDS else field
    if field == "date" and value is not None and value.strip():
        try:
            datetime.strptime(value.strip(), "%Y-%m-%d")
        except ValueError:
            raise SystemExit(f"date needs the form YYYY-MM-DD, not {value!r}")
    stored: object = None
    if value is not None and value.strip():
        if field in _MONEY_FIELDS:
            try:
                stored = to_paise(float(value))
            except ValueError:
                raise SystemExit(f"{field} needs a plain number, not {value!r}")
        else:
            stored = value.strip()
    with write(conn):
        if field == "printed_total" or (field == "total" and conn.execute(
                "SELECT printed_total_paise IS NOT NULL FROM receipts WHERE id = ?", (rid,)).fetchone()[0]):
            # the amount paid: the stored total stays equal to it
            conn.execute("UPDATE receipts SET printed_total_paise = ?, total_paise = ? WHERE id = ?",
                         (stored, stored, rid))
        else:
            conn.execute(f"UPDATE receipts SET {column} = ? WHERE id = ?", (stored, rid))


_ITEM_EDITABLE_FIELDS = {"description", "amount", "qty", "rate", "unit", "hsn", "gst_rate"}
_ITEM_MONEY_FIELDS = {"amount": "amount_paise", "rate": "rate_paise"}


def edit_item_field(conn: sqlite3.Connection, rid: str, line_no: str, field: str,
                    value: str | None) -> None:
    """Set one field on one line item by hand - the same hand-correction
    the receipt's own header fields get in edit_field, just addressed by
    line number instead of by column name alone."""
    _require(conn, rid)
    if field not in _ITEM_EDITABLE_FIELDS:
        raise SystemExit(f"Unknown or non-editable item field {field!r}; "
                         f"expected one of {', '.join(sorted(_ITEM_EDITABLE_FIELDS))}")
    try:
        line = int(line_no)
    except ValueError:
        raise SystemExit(f"line number needs to be a plain integer, not {line_no!r}")
    if conn.execute("SELECT 1 FROM receipt_items WHERE receipt_id = ? AND line_no = ?",
                    (rid, line)).fetchone() is None:
        raise SystemExit(f"No item on line {line} for receipt {rid}")
    stripped = (value or "").strip()
    if field in _ITEM_MONEY_FIELDS:
        column = _ITEM_MONEY_FIELDS[field]
        stored: object = None
        if stripped:
            try:
                stored = to_paise(float(stripped))
            except ValueError:
                raise SystemExit(f"{field} needs a plain number, not {value!r}")
    elif field == "qty":
        column = "qty_e4"
        stored = None
        if stripped:
            try:
                stored = _e4(float(stripped))
            except ValueError:
                raise SystemExit(f"qty needs a plain number, not {value!r}")
    elif field == "gst_rate":
        column = "gst_rate_e2"
        stored = None
        if stripped:
            try:
                stored = _e2(float(stripped))
            except ValueError:
                raise SystemExit(f"gst_rate needs a plain number, not {value!r}")
    else:
        column = field
        stored = stripped or None
    with write(conn):
        conn.execute(f"UPDATE receipt_items SET {column} = ? WHERE receipt_id = ? AND line_no = ?",
                    (stored, rid, line))


def _number(value, what: str) -> float | None:
    stripped = (value or "").strip() if isinstance(value, str) else value
    if stripped in (None, ""):
        return None
    try:
        return float(stripped)
    except ValueError:
        raise SystemExit(f"{what} needs a plain number, not {value!r}")


def add_item(conn: sqlite3.Connection, rid: str, description: str, qty: str | None = None,
             unit: str | None = None, rate: str | None = None, amount: str | None = None,
             gst_rate: str | None = None) -> int:
    """Append a product by hand. A blank amount is worked out from qty x rate
    when both are given. Returns the new line number. A re-parse replaces the
    item table wholesale (save_parse), so hand-added lines do not survive one."""
    _require(conn, rid)
    qty_n, rate_n, amount_n = _number(qty, "qty"), _number(rate, "rate"), _number(amount, "amount")
    gst_n = _number(gst_rate, "gst_rate")
    if amount_n is None and qty_n is not None and rate_n is not None:
        amount_n = round(qty_n * rate_n, 2)
    if amount_n is None:
        raise SystemExit("A product needs an amount, or a qty and a rate to work it out from")
    name = (description or "").strip() or "(unnamed)"
    with write(conn):
        line = conn.execute("SELECT COALESCE(MAX(line_no), 0) + 1 FROM receipt_items WHERE receipt_id = ?",
                            (rid,)).fetchone()[0]
        conn.execute(
            f"INSERT INTO receipt_items (receipt_id, line_no, {', '.join(ITEM_FIELDS)}) "
            f"VALUES (?, ?, {', '.join('?' * len(ITEM_FIELDS))})",
            (rid, line, name, None, _e4(qty_n), (unit or "").strip() or None,
             to_paise(rate_n), to_paise(amount_n), _e2(gst_n)))
    return line


def delete_item(conn: sqlite3.Connection, rid: str, line_no: str) -> None:
    _require(conn, rid)
    try:
        line = int(line_no)
    except ValueError:
        raise SystemExit(f"line number needs to be a plain integer, not {line_no!r}")
    with write(conn):
        gone = conn.execute("DELETE FROM receipt_items WHERE receipt_id = ? AND line_no = ?",
                            (rid, line)).rowcount
    if not gone:
        raise SystemExit(f"No item on line {line} for receipt {rid}")


_TAX_EDITABLE = {"cgst": "cgst_paise", "sgst": "sgst_paise", "igst": "igst_paise",
                 "cess": "cess_paise", "taxable": "taxable_paise"}


def edit_tax_field(conn: sqlite3.Connection, rid: str, rate: str, field: str, value: str | None) -> None:
    """Correct one figure of one GST slab, addressed by the slab's rate."""
    _require(conn, rid)
    if field not in _TAX_EDITABLE:
        raise SystemExit(f"Unknown or non-editable tax field {field!r}; "
                         f"expected one of {', '.join(sorted(_TAX_EDITABLE))}")
    rate_n = _number(rate, "rate")
    rate_e2 = _e2(rate_n or 0)
    amount = _number(value, field)
    with write(conn):
        done = conn.execute(
            f"UPDATE receipt_taxes SET {_TAX_EDITABLE[field]} = ? WHERE receipt_id = ? AND rate_e2 = ?",
            (to_paise(amount), rid, rate_e2)).rowcount
    if not done:
        raise SystemExit(f"No {rate}% tax slab for receipt {rid}")


def add_tax(conn: sqlite3.Connection, rid: str, rate: str, field: str, value: str) -> None:
    """Put one tax figure on a bill that does not have it yet (or replace it),
    creating the GST slab for `rate` when there is none. `rate` is the slab
    (CGST 2.5% + SGST 2.5% is the 5 slab)."""
    _require(conn, rid)
    if field not in ("cgst", "sgst", "igst", "cess"):
        raise SystemExit(f"Unknown tax field {field!r}; expected cgst, sgst, igst or cess")
    amount = _number(value, field)
    if amount is None:
        raise SystemExit(f"{field} needs an amount")
    rate_e2 = _e2(_number(rate, "rate") or 0)
    with write(conn):
        conn.execute("INSERT OR IGNORE INTO receipt_taxes (receipt_id, rate_e2) VALUES (?, ?)", (rid, rate_e2))
        conn.execute(f"UPDATE receipt_taxes SET {_TAX_EDITABLE[field]} = ? WHERE receipt_id = ? AND rate_e2 = ?",
                     (to_paise(amount), rid, rate_e2))


def _flag(value) -> bool:
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def add_fee(conn: sqlite3.Connection, rid: str, label: str, amount: str,
            original: str | None = None, waived: str | None = None) -> int:
    """A platform / delivery / service fee the reader missed. Returns its line.
    A waived fee has amount 0 (pass any amount; it is ignored) and keeps the
    struck-through `original`."""
    _require(conn, rid)
    is_waived = _flag(waived) if waived not in (None, "") else False
    value = _number(amount, "amount")
    orig = _number(original, "original")
    if is_waived:
        value = 0.0
    elif not value:
        raise SystemExit("A fee needs an amount")
    with write(conn):
        line = conn.execute("SELECT COALESCE(MAX(line_no), 0) + 1 FROM receipt_fees WHERE receipt_id = ?",
                            (rid,)).fetchone()[0]
        conn.execute("INSERT INTO receipt_fees (receipt_id, line_no, label, amount_paise, original_paise, waived) "
                     "VALUES (?,?,?,?,?,?)",
                     (rid, line, (label or "").strip() or "Fee", abs(to_paise(value)),
                      None if orig is None else abs(to_paise(orig)), int(is_waived)))
    return line


def edit_fee(conn: sqlite3.Connection, rid: str, line_no: str, field: str, value: str) -> None:
    _require(conn, rid)
    if field not in ("label", "amount", "original", "waived"):
        raise SystemExit(f"Unknown fee field {field!r}; expected label, amount, original or waived")
    try:
        line = int(line_no)
    except ValueError:
        raise SystemExit(f"line number needs to be a plain integer, not {line_no!r}")
    extra = ""
    if field == "amount":
        amount = _number(value, "amount")
        if not amount:
            raise SystemExit("A fee needs an amount (delete it to remove it)")
        column, stored = "amount_paise", abs(to_paise(amount))
        extra = ", waived = 0"   # a real amount means the charge is paid
    elif field == "original":
        orig = _number(value, "original")
        column, stored = "original_paise", None if orig is None else abs(to_paise(orig))
    elif field == "waived":
        column, stored = "waived", int(_flag(value))
        if stored:
            extra = ", amount_paise = 0"
        else:   # back to a paid charge: the struck-through amount is what it costs
            extra = ", amount_paise = CASE WHEN amount_paise = 0 AND original_paise IS NOT NULL " \
                    "THEN original_paise ELSE amount_paise END"
    else:
        column, stored = "label", (value or "").strip() or "Fee"
    with write(conn):
        done = conn.execute(f"UPDATE receipt_fees SET {column} = ?{extra} WHERE receipt_id = ? AND line_no = ?",
                            (stored, rid, line)).rowcount
    if not done:
        raise SystemExit(f"No fee on line {line} for receipt {rid}")


def delete_fee(conn: sqlite3.Connection, rid: str, line_no: str) -> None:
    _require(conn, rid)
    try:
        line = int(line_no)
    except ValueError:
        raise SystemExit(f"line number needs to be a plain integer, not {line_no!r}")
    with write(conn):
        gone = conn.execute("DELETE FROM receipt_fees WHERE receipt_id = ? AND line_no = ?", (rid, line)).rowcount
    if not gone:
        raise SystemExit(f"No fee on line {line} for receipt {rid}")


def _tax_paise(conn: sqlite3.Connection, rid: str) -> int:
    """The bill's tax: the GST slabs when it has them, else the lump figure."""
    slabs = conn.execute("SELECT COALESCE(SUM(COALESCE(cgst_paise,0) + COALESCE(sgst_paise,0) + "
                         "COALESCE(igst_paise,0) + COALESCE(cess_paise,0)), 0) FROM receipt_taxes "
                         "WHERE receipt_id = ?", (rid,)).fetchone()[0]
    if slabs:
        return slabs
    return conn.execute("SELECT COALESCE(tax_paise, 0) FROM receipts WHERE id = ?", (rid,)).fetchone()[0]


def _parts(conn: sqlite3.Connection, rid: str) -> dict:
    """The bill's figures in paise and the tax mode they imply (see
    Model.receiptTaxMode, which uses the same rule). `printed` is what the
    bill says was paid: printed_total_paise, else the stored total."""
    head = conn.execute("SELECT discount_paise, round_off_paise, subtotal_paise, total_paise, "
                        "printed_total_paise FROM receipts WHERE id = ?", (rid,)).fetchone()
    tax = _tax_paise(conn, rid)
    items = conn.execute("SELECT COALESCE(SUM(amount_paise), 0) FROM receipt_items WHERE receipt_id = ?",
                         (rid,)).fetchone()[0]
    fees = conn.execute("SELECT COALESCE(SUM(amount_paise), 0) FROM receipt_fees WHERE receipt_id = ?",
                        (rid,)).fetchone()[0]
    disc, ro = abs(head["discount_paise"] or 0), head["round_off_paise"] or 0
    old_sub = head["subtotal_paise"]
    printed = head["printed_total_paise"] if head["printed_total_paise"] is not None else head["total_paise"]
    # The subtotal is the amount BEFORE GST. Three shapes occur (the bill's own
    # figures say which, same rule as Model.receiptTaxMode): item prices that
    # already include GST ("inclusive": they add up to subtotal + tax), tax
    # added after the items ("on-top"), or no tax to add ("inside").
    mode = "inside"
    if tax and old_sub is not None and printed is not None:
        if abs(items - tax - old_sub) <= 50:
            mode = "inclusive"
        elif printed - (old_sub - disc + ro) - fees > tax / 2:
            mode = "on-top"
    return {"items": items, "fees": fees, "tax": tax, "discount": disc, "round_off": ro,
            "mode": mode, "printed": printed, "has_printed": head["printed_total_paise"] is not None,
            "subtotal": items - tax if mode == "inclusive" else items,
            "old_subtotal": old_sub, "old_total": head["total_paise"]}


def _computed_total(p: dict) -> int:
    return p["subtotal"] - p["discount"] + p["round_off"] + (0 if p["mode"] == "inside" else p["tax"]) + p["fees"]


def _parts_total(p: dict) -> int:
    """What the parts add up to, as Model.receiptParts: tax counts, unless
    the item prices already hold it (then the parts match without it)."""
    with_tax = p["subtotal"] - p["discount"] + p["round_off"] + p["fees"] + p["tax"]
    tol = max(100, abs(p["round_off"]) + 50)
    if (p["printed"] is not None and p["tax"] and abs(with_tax - p["printed"]) > tol
            and abs(with_tax - p["tax"] - p["printed"]) <= tol):
        return with_tax - p["tax"]
    return with_tax


def recalc_totals(conn: sqlite3.Connection, rid: str, clear_flags: bool = False) -> None:
    """Re-add the parts from the items, charges and tax.

    A bill WITHOUT a printed total (older reads): subtotal = sum of the items,
    total = subtotal - |discount| + round off (+ tax and charges). A line with
    no amount but a qty and a rate gets qty x rate first; a line that already
    has an amount is never overwritten (a weighed item's printed amount is the
    bill's own rounding). Tax is not added when the bill prints GST as an
    inclusive split of the item prices.

    A bill WITH a printed total (printed_total_paise, the amount paid): only
    the subtotal is recomputed. The printed total is never written here (only
    `use_computed_total` replaces it) and `total_paise` stays equal to it, so
    the widget can compare the parts with what the bill says.

    `clear_flags` is the explicit "recalculate and verify" button: when the
    figures reconcile, the parser's stale warnings and its "check this parse"
    flag are cleared too. When the parts do not match the printed total they
    are left on."""
    _require(conn, rid)
    if not conn.execute("SELECT COUNT(*) FROM receipt_items WHERE receipt_id = ?", (rid,)).fetchone()[0]:
        raise SystemExit("Nothing to add up: this receipt has no items")
    with write(conn):
        conn.execute(
            "UPDATE receipt_items SET amount_paise = CAST(ROUND(qty_e4 / 10000.0 * rate_paise) AS INTEGER) "
            "WHERE receipt_id = ? AND amount_paise IS NULL AND qty_e4 IS NOT NULL AND rate_paise IS NOT NULL",
            (rid,))
        p = _parts(conn, rid)
        computed = _computed_total(p)
        if p["has_printed"]:
            computed = _parts_total(p)
            conn.execute("UPDATE receipts SET subtotal_paise = ?, total_paise = printed_total_paise WHERE id = ?",
                         (p["subtotal"], rid))
            agrees = abs(computed - p["printed"]) <= max(100, abs(p["round_off"]) + 50)
        else:
            conn.execute("UPDATE receipts SET subtotal_paise = ?, total_paise = ? WHERE id = ?",
                         (p["subtotal"], computed, rid))
            agrees = True
        if clear_flags and agrees:
            conn.execute("UPDATE receipts SET warnings = '[]', needs_review = 0 WHERE id = ?", (rid,))


def _from_paise(value) -> float | None:
    return None if value is None else round(value / 100, 2)


def snapshot(conn: sqlite3.Connection) -> dict:
    """The widget's view: unmatched first, each with its items and taxes."""
    items: dict[str, list] = {}
    for r in conn.execute("SELECT * FROM receipt_items ORDER BY receipt_id, line_no"):
        items.setdefault(r["receipt_id"], []).append({
            "line": r["line_no"], "description": r["description"], "hsn": r["hsn"],
            "qty": None if r["qty_e4"] is None else round(r["qty_e4"] / 10000, 4),
            "unit": r["unit"], "rate": _from_paise(r["rate_paise"]),
            "amount": _from_paise(r["amount_paise"]),
            "gstRate": None if r["gst_rate_e2"] is None else round(r["gst_rate_e2"] / 100, 2),
        })
    fees: dict[str, list] = {}
    for r in conn.execute("SELECT * FROM receipt_fees ORDER BY receipt_id, line_no"):
        fees.setdefault(r["receipt_id"], []).append(
            {"line": r["line_no"], "label": r["label"], "amount": _from_paise(r["amount_paise"]),
             "original": _from_paise(r["original_paise"]), "waived": bool(r["waived"])})
    cats = {r["receipt_id"]: {"category": r["category"], "subcategory": r["subcategory"], "source": r["source"]}
            for r in conn.execute("SELECT * FROM receipt_categories")}
    taxes: dict[str, list] = {}
    for r in conn.execute("SELECT * FROM receipt_taxes ORDER BY receipt_id, rate_e2"):
        taxes.setdefault(r["receipt_id"], []).append({
            "rate": round(r["rate_e2"] / 100, 2), "taxable": _from_paise(r["taxable_paise"]),
            "cgst": _from_paise(r["cgst_paise"]), "sgst": _from_paise(r["sgst_paise"]),
            "igst": _from_paise(r["igst_paise"]), "cess": _from_paise(r["cess_paise"]),
        })

    saved = {r["receipt_id"]: {"bytes": r["bytes"], "originalBytes": r["original_bytes"],
                               "width": r["width"], "height": r["height"], "savedAt": r["saved_at"]}
             for r in conn.execute("SELECT receipt_id, bytes, original_bytes, width, height, saved_at "
                                   "FROM receipt_images")}
    out = []
    for r in conn.execute(
            "SELECT * FROM receipts_view ORDER BY (state = 'unmatched') DESC, date DESC, id"):
        try:
            warnings = json.loads(r["warnings"]) if r["warnings"] else []
        except (TypeError, ValueError):
            warnings = []
        try:
            image_meta = json.loads(r["image_meta"]) if r["image_meta"] else {}
        except (TypeError, ValueError):
            image_meta = {}
        out.append({
            "id": r["id"], "merchant": r["merchant"] or "", "date": r["date"],
            "time": r["time"], "gstin": r["gstin"], "invoiceNo": r["invoice_no"],
            "total": _from_paise(r["total_paise"]), "subtotal": _from_paise(r["subtotal_paise"]),
            "tax": _from_paise(r["tax_paise"]), "discount": _from_paise(r["discount_paise"]),
            "roundOff": _from_paise(r["round_off_paise"]),
            "platform": r["platform"], "orderId": r["order_id"], "paymentMethod": r["payment_method"],
            "printedTotal": _from_paise(r["printed_total_paise"]), "saved": _from_paise(r["saved_paise"]),
            "category": cats.get(r["id"]),
            "paymentHint": r["payment_hint"], "currency": r["currency"],
            "beforePayment": bool(r["before_payment"]),
            "rotation": r["rotation"],
            # None for a photo that was deleted by an earlier version (rows
            # with image_deleted set): the widget's own fallback (storedPath,
            # else thumbPath, else nothing) then shows the thumbnail instead of
            # a file that is gone. Nothing is deleted any more.
            "storedPath": None if r["image_deleted"] else r["stored_path"],
            "thumbPath": r["thumb_path"], "imageDeleted": bool(r["image_deleted"]),
            # What the photo file knew (taken, camera, size) plus where it
            # came from - the info panel's figures.
            "imageSaved": saved.get(r["id"]),
            "imageMeta": image_meta, "sourcePath": r["source_path"],
            "sourceMtime": r["source_mtime"], "sourceSize": r["source_size"],
            "importedAt": r["imported_at"], "parsedAt": r["parsed_at"], "linkedAt": r["linked_at"],
            "confidence": r["confidence"], "needsReview": bool(r["needs_review"]),
            "warnings": warnings, "method": r["method"], "rawText": r["raw_text"] or "",
            "state": r["state"], "transactionId": r["transaction_id"],
            "matchedBy": r["matched_by"], "score": r["score"],
            # Linked to a row that no longer exists: a re-fetch can rewrite
            # transaction ids, and the link deliberately has no foreign key.
            "linkMissing": bool(r["transaction_id"] and r["txn_date"] is None),
            "txnDate": r["txn_date"], "txnMerchant": r["txn_merchant"],
            "txnAmount": _from_paise(r["txn_amount_paise"]),
            "txnTracked": bool(r["txn_tracked"]),
            "items": items.get(r["id"], []), "taxes": taxes.get(r["id"], []),
            "fees": fees.get(r["id"], []),
        })
    from . import cashew
    cats = [{"name": c["name"], "type": c["type"], "icon": c.get("icon", ""), "color": c.get("color", ""),
             "subcategories": c.get("subcategories") or [], "subIcons": c.get("subIcons") or {}} for c in cashew.load_categories()]
    return {"receipts": out, "receiptCategories": cats}
