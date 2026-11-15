"""Refund links: a credit that gives money back for an earlier purchase.

A refund is a row with money IN (a card credit, a UPI return) that undoes all or part of
one earlier row with money OUT. The link says so, so that:
  - the month and day totals net the refund against the purchase,
  - the Cashew export files the refund under the purchase's category (Cashew itself has no
    refund type and no link between two rows),
  - a refund that was started but has not arrived yet can be noted on the purchase.

Matching is deliberately careful, in the spirit of txdb/transfers.py: an amount alone never
links two rows. A shared UPI reference is certain; an exact amount with the same merchant in
the same CARD, with no rival, is a safe automatic link; everything else is only a
suggestion the person confirms.

Tables (txdb/db.py v26): refund_links, refund_not, refund_expect. None of them has a foreign
key, because a re-fetch can rewrite transaction ids; `heal` re-points a link by fingerprint.
"""
from __future__ import annotations

import re
import sqlite3
from datetime import date

from . import transfers

WINDOW_DAYS = 90            # a refund comes this many days after the purchase, at most
MODES = ("income", "skip", "lent")
# "skip" = net the refund against its purchase in the Cashew export (same category, right category total).
# Cashew ignores the sign in a link and takes income/expense from the category type, so a refund cannot be
# income under the purchase's expense category; "income" files it under an income category instead.
DEFAULT_MODE = "skip"

# Words that say nothing about WHO was paid: legal suffixes, "internet", the city a bank
# appends to a merchant on the purchase row but drops on the refund row.
_STOP = {
    "PVT", "PRIVATE", "LTD", "LIMITED", "LLP", "INDIA", "INTERNET", "THE", "AND", "PAYMENTS", "PAYMENT",
    "TECHNOLOGIES", "SERVICES", "STORE", "STORES", "UPI", "COM", "ONLINE", "BANGALORE", "BENGALURU",
    "MUMBAI", "DELHI", "CHENNAI", "HYDERABAD", "PUNE", "KOCHI", "TRIVANDRUM", "GURGAON", "NOIDA",
    # words every bank row has, which say nothing about who was paid ("UPI- TRANSFER FROM 4897...")
    "TRANSFER", "FROM", "REFUND", "REVERSAL", "DEBIT", "CREDIT", "NEFT", "IMPS", "RTGS", "CARD", "TXN",
    "BANK", "PURCHASE", "ECOM", "FOR", "WITH",
}
_TRAILING_CITY = re.compile(r"\s-\s*[A-Z ]+$")
# Credits that are not the return of a purchase: fees given back, interest, rewards.
_NOT_A_REFUND = re.compile(
    r"\b(surcharge|waiver|avg bal|bal chgs|cashback|interest|reward|dividend|salary)\b", re.I)


def tokens(merchant: str) -> set[str]:
    """The words of a merchant that identify it ("FLIPKART INTERNET PVT L -BANGALORE" -> {FLIPKART}).
    The same rules are in Model.js (refundTokens)."""
    s = (merchant or "").upper()
    s = re.sub(r"^UPI[- ]+", "", s)
    s = _TRAILING_CITY.sub("", s)
    return {w for w in re.findall(r"[A-Z]{3,}", s) if w not in _STOP}


def _days(later: str, earlier: str) -> int:
    return (date.fromisoformat(later) - date.fromisoformat(earlier)).days


def match(credit: dict, original: dict) -> dict | None:
    """How well `original` (money out) fits as the purchase behind `credit` (money in), or None.
    Keys: score, ref (shared UPI reference), exact (same amount), sameAccount, full (every word of
    the shorter merchant is in the other). Needs a shared reference, or a shared merchant word:
    an amount alone is never evidence. The same scoring is in Model.js (refundMatchScore)."""
    if credit["amount_paise"] <= 0 or original["amount_paise"] >= 0:
        return None
    paid = -original["amount_paise"]
    if credit["amount_paise"] > paid:
        return None                                        # a refund is never more than the purchase
    try:
        days = _days(credit["date"], original["date"])
    except (ValueError, TypeError, KeyError):
        return None
    if days < 0 or days > WINDOW_DAYS:
        return None
    ref_c, ref_o = transfers.upi_ref(credit["merchant"]), transfers.upi_ref(original["merchant"])
    ref = bool(ref_c and ref_c == ref_o)
    a, b = tokens(credit["merchant"]), tokens(original["merchant"])
    common = a & b
    full = bool(common) and common == (a if len(a) <= len(b) else b)
    if not ref and not common:
        return None
    exact = credit["amount_paise"] == paid
    same_account = credit["account_id"] == original["account_id"]
    score = 100 if ref else 0
    if not ref:
        score += 35 if full else 15
    score += 45 if exact else 25
    score += 15 if days <= 7 else 10 if days <= 30 else 5 if days <= 60 else 0
    score += 10 if same_account else (3 if credit.get("bank") == original.get("bank") else 0)
    return {"score": score, "ref": ref, "exact": exact, "sameAccount": same_account, "full": full, "days": days}


def candidates(credit: dict, rows: list[dict], skip: set[str] | None = None) -> list[dict]:
    """[{id, score, ...match}] best first, for the purchases `credit` may refund."""
    skip = skip or set()
    out = []
    for r in rows:
        if r["id"] == credit["id"] or r["id"] in skip:
            continue
        m = match(credit, r)
        if m:
            out.append({"id": r["id"], **m})
    out.sort(key=lambda c: (-c["score"], c["days"], c["id"]))
    return out


def detect(rows: list[dict], linked: set[str], refunded_paise: dict[str, int], nots: set[str]) -> list[dict]:
    """The links that can be made without asking: [{refundId, originalId, matchedBy, score}].

    `rows`: id, date, merchant, amount_paise, account_id, account_type, bank.
    `linked`: refund ids that already have a link. `refunded_paise`: original id -> money already
    refunded to it. `nots`: credits the person said are not refunds.

    Certain: the same UPI reference on a credit and an earlier debit. Safe: exact amount, every
    merchant word shared, same account, and exactly one such purchase."""
    pairs, hits, _names = transfers.resolve(rows)
    not_refunds = set(nots) | {t for p in pairs for t in (p["outId"], p["inId"])} | {h["id"] for h in hits}
    debits = [r for r in rows if r["amount_paise"] < 0 and r["id"] not in not_refunds]
    paid_for = {d["id"]: -d["amount_paise"] for d in debits}
    out, used = [], dict(refunded_paise)
    for credit in sorted((r for r in rows if r["amount_paise"] > 0), key=lambda r: (r["date"], r["id"])):
        if credit["id"] in linked or credit["id"] in not_refunds:
            continue
        if _NOT_A_REFUND.search(credit["merchant"] or "") or transfers._CARD_PAYMENT.search(credit["merchant"] or ""):
            continue
        # a purchase can only be refunded up to what it cost
        cands = [c for c in candidates(credit, debits)
                 if used.get(c["id"], 0) + credit["amount_paise"] <= paid_for[c["id"]]]
        if not cands:
            continue
        refs = [c for c in cands if c["ref"]]
        if len(refs) == 1:
            pick, how = refs[0], "ref"
        else:
            # Only a card credit is linked on exact amount + merchant: on a bank account a UPI
            # amount that comes back may be a friend paying you back, so it stays a suggestion.
            safe = [c for c in cands if c["exact"] and c["full"] and c["sameAccount"]]
            if len(safe) != 1 or refs or credit.get("account_type") != "credit":
                continue
            pick, how = safe[0], "auto"
        out.append({"refundId": credit["id"], "originalId": pick["id"], "matchedBy": how, "score": pick["score"]})
        used[pick["id"]] = used.get(pick["id"], 0) + credit["amount_paise"]
    return out


# ----------------------------------------------------------------------- database

def _row(conn: sqlite3.Connection, txn_id: str):
    return conn.execute(
        "SELECT t.id, t.account_id, t.date, t.amount_paise, t.merchant FROM transactions t WHERE t.id = ?",
        (txn_id,)).fetchone()


def set_link(conn: sqlite3.Connection, refund_id: str, original_id: str | None, matched_by: str = "manual",
             note: str = "", score: int | None = None, mode: str | None = None) -> None:
    """Link a credit to the purchase it refunds. `original_id` None = the purchase is not in the data
    (`note` then says what it was). Raises ValueError for rows that cannot be linked."""
    from .db import now, write
    refund = _row(conn, refund_id)
    if not refund:
        raise ValueError(f"Unknown transaction {refund_id}")
    if refund["amount_paise"] <= 0:
        raise ValueError("A refund must be money in")
    original = None
    if original_id:
        original = _row(conn, original_id)
        if not original:
            raise ValueError(f"Unknown transaction {original_id}")
        if original["amount_paise"] >= 0:
            raise ValueError("The purchase must be money out")
        if original_id == refund_id:
            raise ValueError("A row cannot refund itself")
    if mode is not None and mode not in MODES:
        raise ValueError(f"Unknown mode {mode!r}")
    with write(conn):
        old = conn.execute("SELECT cashew_mode FROM refund_links WHERE refund_id = ?", (refund_id,)).fetchone()
        conn.execute(
            "INSERT OR REPLACE INTO refund_links (refund_id, original_id, original_note, matched_by, score, cashew_mode, "
            "linked_at, fp_refund_account, fp_refund_date, fp_refund_amount_paise, fp_refund_merchant, "
            "fp_original_account, fp_original_date, fp_original_amount_paise, fp_original_merchant) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (refund_id, original_id, (note or "").strip(), matched_by, score,
             mode or (old["cashew_mode"] if old else DEFAULT_MODE), now(),
             refund["account_id"], refund["date"], refund["amount_paise"], refund["merchant"],
             original["account_id"] if original else None, original["date"] if original else None,
             original["amount_paise"] if original else None, original["merchant"] if original else None))
        conn.execute("DELETE FROM refund_not WHERE txn_id = ?", (refund_id,))
        if original_id:
            conn.execute("DELETE FROM refund_expect WHERE original_id = ?", (original_id,))


def clear_link(conn: sqlite3.Connection, refund_id: str) -> None:
    """Remove the link and remember the credit is not to be auto-linked again."""
    from .db import now, write
    with write(conn):
        conn.execute("DELETE FROM refund_links WHERE refund_id = ?", (refund_id,))
        conn.execute("INSERT OR REPLACE INTO refund_not (txn_id, marked_at) VALUES (?, ?)", (refund_id, now()))


def mark_not(conn: sqlite3.Connection, refund_id: str) -> None:
    clear_link(conn, refund_id)


def restore(conn: sqlite3.Connection, refund_id: str) -> None:
    """Let the credit be auto-linked again."""
    from .db import write
    with write(conn):
        conn.execute("DELETE FROM refund_not WHERE txn_id = ?", (refund_id,))


def set_mode(conn: sqlite3.Connection, refund_id: str, mode: str) -> None:
    from .db import write
    if mode not in MODES:
        raise ValueError(f"Unknown mode {mode!r}")
    with write(conn):
        if conn.execute("UPDATE refund_links SET cashew_mode = ? WHERE refund_id = ?", (mode, refund_id)).rowcount == 0:
            raise ValueError(f"{refund_id} has no refund link")


def expect(conn: sqlite3.Connection, original_id: str, expected_paise: int | None = None, note: str = "") -> None:
    """Note on a purchase that its money is being returned but has not arrived."""
    from .db import now, write
    original = _row(conn, original_id)
    if not original:
        raise ValueError(f"Unknown transaction {original_id}")
    if original["amount_paise"] >= 0:
        raise ValueError("Only a purchase can wait for a refund")
    with write(conn):
        conn.execute("INSERT OR REPLACE INTO refund_expect (original_id, expected_paise, note, created_at) VALUES (?,?,?,?)",
                     (original_id, expected_paise, (note or "").strip(), now()))


def unexpect(conn: sqlite3.Connection, original_id: str) -> None:
    from .db import write
    with write(conn):
        conn.execute("DELETE FROM refund_expect WHERE original_id = ?", (original_id,))


def verify(conn: sqlite3.Connection) -> dict:
    """Link what can be linked without asking, after every fetch. Writes only when there is
    something new, so a check with nothing to do never wakes the widget. Returns {"new": n}."""
    rows = transfers.load_rows(conn)
    linked = {r[0] for r in conn.execute("SELECT refund_id FROM refund_links")}
    refunded: dict[str, int] = {}
    for r in conn.execute("SELECT l.original_id, t.amount_paise FROM refund_links l "
                          "JOIN transactions t ON t.id = l.refund_id WHERE l.original_id IS NOT NULL"):
        refunded[r[0]] = refunded.get(r[0], 0) + r[1]
    nots = {r[0] for r in conn.execute("SELECT txn_id FROM refund_not")}
    made = detect(rows, linked, refunded, nots)
    for m in made:
        set_link(conn, m["refundId"], m["originalId"], m["matchedBy"], score=m["score"])
    return {"new": len(made)}


def heal(conn: sqlite3.Connection) -> dict:
    """A link names rows by id. When a row's id is gone (an unsettled row settled under a new id),
    look for the same row by the fingerprint the link carries (date, amount, same account first,
    else same bank). Exactly one unclaimed candidate -> the link moves; otherwise it is left
    and reported. A wrong link is worse than a missing one.
    Returns {"healed": [...], "orphans": [{refund_id, side, reason}]}."""
    from .db import write
    healed, orphans = [], []

    def find(account, day, paise, claimed_sql):
        bank = (account or "").split("|")[0]
        for same_account in (True, False):
            found = [r[0] for r in conn.execute(
                "SELECT t.id FROM transactions t JOIN accounts a ON a.id = t.account_id "
                "WHERE t.date = ? AND t.amount_paise = ? AND " + ("t.account_id = ?" if same_account else "a.bank = ?")
                + claimed_sql, (day, paise, account if same_account else bank))]
            if found:
                return found
        return []

    for l in conn.execute("SELECT * FROM refund_links").fetchall():
        for side, id_col, fp in (("refund", "refund_id", "fp_refund_"), ("original", "original_id", "fp_original_")):
            tid = l[id_col]
            if tid is None or conn.execute("SELECT 1 FROM transactions WHERE id = ?", (tid,)).fetchone():
                continue
            day, paise, acct = l[fp + "date"], l[fp + "amount_paise"], l[fp + "account"]
            if not day or paise is None:
                orphans.append({"refund_id": l["refund_id"], "side": side, "reason": "no fingerprint saved"})
                continue
            claimed = (" AND NOT EXISTS (SELECT 1 FROM refund_links o WHERE o.refund_id = t.id)" if side == "refund" else "")
            found = find(acct, day, paise, claimed)
            if len(found) != 1:
                orphans.append({"refund_id": l["refund_id"], "side": side,
                                "reason": "no transaction matches" if not found else f"{len(found)} transactions match"})
                continue
            with write(conn):
                if side == "refund":
                    conn.execute("UPDATE refund_links SET refund_id = ? WHERE refund_id = ?", (found[0], l["refund_id"]))
                else:
                    conn.execute("UPDATE refund_links SET original_id = ? WHERE refund_id = ?", (found[0], l["refund_id"]))
            healed.append({"refund_id": l["refund_id"], "side": side, "from": tid, "to": found[0]})
            break
    return {"healed": healed, "orphans": orphans}


def orphans(conn: sqlite3.Connection) -> list[dict]:
    """Links whose rows are gone and could not be healed (for `txdb check`)."""
    out = []
    for l in conn.execute("SELECT refund_id, original_id FROM refund_links").fetchall():
        for side, tid in (("refund", l["refund_id"]), ("original", l["original_id"])):
            if tid and not conn.execute("SELECT 1 FROM transactions WHERE id = ?", (tid,)).fetchone():
                out.append({"refund_id": l["refund_id"], "side": side})
    return out


# ------------------------------------------------------------------------ snapshot

def snapshot(conn: sqlite3.Connection, by_id: dict[str, dict]) -> dict:
    """Tag the snapshot rows (`by_id`: id -> row dict, edited in place) and return the top-level keys.

    On the credit: refundOf (the purchase id, "" when it is not in the data), refundMode,
    refundNote; refundNot (true) on a credit said not to be a refund. On the purchase: refundedBy (ids), refundedAmount, refundState
    ("full", "partial" or "pending")."""
    try:
        link_rows = conn.execute("SELECT * FROM refund_links").fetchall()
    except sqlite3.OperationalError:                 # a read-only look at a database not yet migrated to v26
        return {"refunds": [], "refundNot": [], "refundExpect": []}
    links = []
    refunded: dict[str, list[str]] = {}
    for l in link_rows:
        credit = by_id.get(l["refund_id"])
        if credit is None:
            continue
        original = by_id.get(l["original_id"]) if l["original_id"] else None
        if l["original_id"] and original is None:
            continue                                        # the purchase vanished: `check` reports it
        links.append({
            "refundId": l["refund_id"], "originalId": l["original_id"] or "", "originalNote": l["original_note"] or "",
            "refundAmount": credit["amount"], "originalAmount": original["amount"] if original else None,
            "partial": bool(original and credit["amount"] < -original["amount"]),
            "matchedBy": l["matched_by"], "score": l["score"], "mode": l["cashew_mode"]})
        credit["refundOf"] = l["original_id"] or ""
        credit["refundMode"] = l["cashew_mode"]
        if l["original_note"]:
            credit["refundNote"] = l["original_note"]
        if original is not None:
            refunded.setdefault(l["original_id"], []).append(l["refund_id"])
    expect = {r["original_id"]: r for r in conn.execute("SELECT * FROM refund_expect")}
    for oid, ids in refunded.items():
        o = by_id[oid]
        total = round(sum(by_id[i]["amount"] for i in ids), 2)
        o["refundedBy"] = ids
        o["refundedAmount"] = total
        o["refundState"] = "full" if total >= -o["amount"] - 0.004 else "partial"
    not_ids = sorted(r[0] for r in conn.execute("SELECT txn_id FROM refund_not"))
    for tid in not_ids:
        if tid in by_id:
            by_id[tid]["refundNot"] = True
    pending = []
    for oid, e in expect.items():
        o = by_id.get(oid)
        if o is None:
            continue
        pending.append({"originalId": oid, "expected": e["expected_paise"] / 100 if e["expected_paise"] is not None else None,
                        "note": e["note"] or ""})
        if "refundState" not in o:
            o["refundState"] = "pending"
    return {"refunds": links,
            "refundNot": not_ids,
            "refundExpect": pending}
