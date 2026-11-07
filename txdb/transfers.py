"""The two sides of one movement between your own accounts.

Move money from HDFC to SBI and each bank records its own half: a debit on
one, a credit on the other. Seen separately they look like spending and
income; seen together they are one transfer. This pairs them.

How the banks write it (read off real statements):

    SBI   UPI- TRANSFER TO|FROM <acct> UPI/DR|CR/<ref>/<NAME>/<bank>/...
    AXIS  UPI/P2A|P2M/<ref>/<NAME>/<bank>/<remark>
    HDFC  UPI-<NAME>-<vpa>-<ifsc>-<ref>-<remark>      (a short "Upi-<name>" form
                                                      with no reference also exists)

`<ref>` is the 12-digit UPI reference (RRN), the same number on both banks'
rows of one payment - the one dependable thing to pair on. Amount and date
alone are NOT enough: a Rs 1,000 SIP debit and an unrelated Rs 1,000 credit
the same day are not a transfer. So:

  1. "ref": two rows in two different accounts sharing a UPI reference, equal
     and opposite amounts. (The same reference twice in ONE account is a
     reversal, not a transfer, and is left alone.)
  2. "card": a card bill payment - a debit on a bank account and the matching
     credit on a credit card, which share no reference but do share the
     amount, a date within a few days and the "payment" wording; only when
     that match is unambiguous both ways.

  3. "self": a transfer whose OTHER side is not in your data at all - HDFC
     history that starts later than Axis's, a bank not fetched. It is still
     plainly a transfer when the counterparty is YOU: the name is learned from
     the pairs found by (1) and (2) ("THEJUS M", "THEJUS M MANOJ" - whichever
     way each bank truncates it), and any other UPI row with that same name is
     one of your own transfers, shown with its missing side marked (the other
     bank is read off the text: "/HDFC/", "SBIN0001000" ...).

Pure functions over plain rows, no database - the snapshot computes it live,
so there is nothing to go stale. The user can split a wrong pair
(`transfer_splits`), which is remembered.
"""
from __future__ import annotations

import re
from datetime import date

from . import keys

_REF = re.compile(r"(?<!\d)(\d{12})(?!\d)")
_CARD_PAYMENT = re.compile(
    r"\b(CC PAYMENT|CC PYMT|CC BILL|CREDIT CARD|BPPY|BBPS|CARD PAYMENT|PAYMENT RECEIVED|BILLPAY|BILL PAY|PYMT)\b", re.I)
CARD_WINDOW_DAYS = 3


def upi_ref(merchant: str) -> str | None:
    m = _REF.search(merchant or "")
    return m.group(1) if m else None


def _days(a: str, b: str) -> int:
    return abs((date.fromisoformat(a) - date.fromisoformat(b)).days)


def _pair(out: dict, inn: dict, how: str, ref: str | None) -> dict:
    return {"id": f"{out['id']}>{inn['id']}", "outId": out["id"], "inId": inn["id"],
            "amountPaise": -out["amount_paise"], "date": out["date"], "inDate": inn["date"],
            "matchedBy": how, "ref": ref}


def detect(rows: list[dict]) -> list[dict]:
    """Every pair that looks like a transfer between two of your own
    accounts. `rows`: dicts with id, date, merchant, amount_paise, account_id
    and account_type."""
    pairs: list[dict] = []
    used: set[str] = set()

    by_ref: dict[str, list[dict]] = {}
    for r in rows:
        ref = upi_ref(r["merchant"])
        if ref:
            by_ref.setdefault(ref, []).append(r)
    for ref, group in by_ref.items():
        outs = [r for r in group if r["amount_paise"] < 0]
        ins = [r for r in group if r["amount_paise"] > 0]
        if len(outs) != 1 or len(ins) != 1:
            continue                                   # ambiguous or one-sided: leave it
        out, inn = outs[0], ins[0]
        if out["account_id"] == inn["account_id"] or -out["amount_paise"] != inn["amount_paise"]:
            continue                                   # a reversal in one account, or different sums
        pairs.append(_pair(out, inn, "ref", ref))
        used.update((out["id"], inn["id"]))

    debits = [r for r in rows if r["id"] not in used and r["amount_paise"] < 0 and r["account_type"] != "credit"]
    credits = [r for r in rows if r["id"] not in used and r["amount_paise"] > 0 and r["account_type"] == "credit"]
    wanted: dict[str, list[dict]] = {}
    for d in debits:
        wanted[d["id"]] = [c for c in credits
                           if c["amount_paise"] == -d["amount_paise"]
                           and _days(d["date"], c["date"]) <= CARD_WINDOW_DAYS
                           and (_CARD_PAYMENT.search(c["merchant"]) or _CARD_PAYMENT.search(d["merchant"]))]
    taken_by: dict[str, list[dict]] = {}
    for did, cs in wanted.items():
        for c in cs:
            taken_by.setdefault(c["id"], []).append(next(d for d in debits if d["id"] == did))
    for d in debits:
        cs = wanted[d["id"]]
        if len(cs) == 1 and len(taken_by[cs[0]["id"]]) == 1:       # unambiguous both ways
            pairs.append(_pair(d, cs[0], "card", None))
    return pairs


# ---------------------------------------------------------------- one-sided

_BANK_WORDS = (("HDFC", "HDFC"), ("SBIN", "SBI"), ("STATE BANK", "SBI"), ("UTIB", "AXIS"),
               ("AXIS", "AXIS"), ("ICIC", "ICICI"))


def _norm(name: str | None) -> str:
    return re.sub(r"[^A-Z]", "", (name or "").upper().replace("0", "O"))


def _same_person(a: str, b: str) -> bool:
    """Equal once spaces are ignored, or one a bank's truncation of the other
    ("THEJUS M" / "THEJUS M MANOJ"): the shorter is a prefix, at least 7
    letters, and the rest of the longer is letters only."""
    if not a or not b:
        return False
    if a == b:
        return True
    short, long_ = sorted((a, b), key=len)
    return len(short) >= 7 and long_.startswith(short)


def other_bank_hint(own_bank: str, merchant: str) -> str | None:
    """Which bank the other side was, read off the statement text."""
    upper = (merchant or "").upper()
    found = [bank for word, bank in _BANK_WORDS if word in upper and bank != own_bank]
    return found[0] if found else None


def own_names(pairs: list[dict], rows: list[dict]) -> set[str]:
    """The names you appear under - learned from the counterparty on both sides
    of every pair found by reference (the other party there is you)."""
    by_id = {r["id"]: r for r in rows}
    names: set[str] = set()
    for p in pairs:
        if p["matchedBy"] != "ref":
            continue
        for tid in (p["outId"], p["inId"]):
            r = by_id.get(tid)
            parsed = keys.parsed_counterparty(r["bank"], r["merchant"]) if r and r.get("bank") else None
            if parsed and _norm(parsed["name"]):
                names.add(_norm(parsed["name"]))
    return names


def detect_self(rows: list[dict], paired_ids: set[str], names: set[str]) -> list[dict]:
    """Rows that are one side of a transfer between your own accounts whose
    other side is not in `rows`: [{id, other}] (`other` = the bank read off the
    text, or None). Only UPI/NEFT rows of a bank account whose counterparty is
    you; a card or an unparseable row is never guessed at."""
    out = []
    for r in rows:
        if r["id"] in paired_ids or r.get("account_type") == "credit" or not r.get("bank"):
            continue
        parsed = keys.parsed_counterparty(r["bank"], r["merchant"])
        if not parsed:
            continue
        who = _norm(parsed["name"])
        if any(_same_person(who, n) for n in names):
            out.append({"id": r["id"], "other": other_bank_hint(r["bank"], r["merchant"])})
    return out
