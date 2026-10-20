"""What a transaction is "about": the group key a rename applies to, the
counterparty name shown by default, and the free-text remark. Ported from
the widget's Model.js so the rules live in one place and are stored with
each row.

Each bank writes the same transfer differently — SBI and Axis put their
own account/reference numbers before the counterparty, HDFC writes
"UPI-<name>-<vpa>-<ifsc>-<refnum>-<remark>" — so each has its own pattern
here, and all three yield the same key for the same person: "UPI|<NAME>".
That is deliberate. A key carrying the bank, or the VPA, split one
counterparty into four groups (the same person reached via HDFC and via
Axis, and HDFC masking the VPA on some rows but not others), so renaming
them meant renaming each variant by hand. Rows nothing can parse — bank
charges, interest, card vendor names — stay keyed by bank and description,
where the text is the only identity they have."""
from __future__ import annotations

import re

_LONG_DIGIT_RUN = re.compile(r"\d{8,}")
_SBI_UPI = re.compile(r"^UPI- TRANSFER (?:TO|FROM) \d+ UPI/(?:DR|CR)/\d+/([^/]*)(?:/([^/]*))?(?:/[^/]*)?(?:/(.*))?")
_SBI_NEFT = re.compile(r"^NEFT- TRANSFER (?:TO|FROM) \d+ NEFT\*[^*]*\*[^*]*\*(.+)$")
_AXIS_UPI = re.compile(r"^UPI/P2[AMV]/\d+/([^/]*)/([^/]*)(?:/([^/]*))?")
# "UPI-LAKSHMI MOHAN-LMLAKSHMIMOHAN2002@OKSBI-SBIN0070528-627610349848-NO REMARK"
# The VPA is sometimes masked ("**********2002@OKSBI"), so it is read but
# never keyed on.
_HDFC_UPI = re.compile(r"^UPI-([^-]*)-([^-]*)-([^-]*)-(\d+)(?:-(.*))?$")
_NON_INFORMATIVE = {"", "UPI", "NO REMARK", "NO REMARKS"}


def _clean(s: str | None) -> str:
    return " ".join((s or "").split())


def _bank_code(s: str | None) -> str:
    return re.sub(r" BANK$", "", _clean(s).upper())


def _upi_key(name: str) -> str:
    """One counterparty, one key, whichever bank the row came from."""
    return f"UPI|{_clean(name).upper()}"


def parsed_counterparty(bank: str, merchant: str) -> dict | None:
    """{key, name, remark} for a UPI/NEFT row of any of the three banks,
    else None."""
    if bank == "SBI":
        m = _SBI_UPI.match(merchant)
        if m:
            name = _clean(m.group(1))
            return {"key": _upi_key(name), "name": name, "remark": _clean(m.group(3))}
        m = _SBI_NEFT.match(merchant)
        if m:
            name = _clean(m.group(1))
            return {"key": f"NEFT|{name.upper()}", "name": name, "remark": ""}
    if bank == "AXIS":
        m = _AXIS_UPI.match(merchant)
        if m:
            name = _clean(m.group(1))
            return {"key": _upi_key(name), "name": name, "remark": _clean(m.group(3))}
    if bank == "HDFC":
        m = _HDFC_UPI.match(merchant)
        if m:
            name = _clean(m.group(1))
            if name:
                return {"key": _upi_key(name), "name": name, "remark": _clean(m.group(5))}
    return None


def legacy_group_key(merchant: str) -> str:
    """The widget's old key: the description up to the first long digit run."""
    m = _LONG_DIGIT_RUN.search(merchant)
    key = merchant[: m.start()] if m else merchant
    return re.sub(r"[-\s]+$", "", key)


def group_key(bank: str, merchant: str) -> str:
    parsed = parsed_counterparty(bank, merchant)
    return parsed["key"] if parsed else f"{bank}|{legacy_group_key(merchant)}"


def _is_boilerplate(note: str) -> bool:
    n = note.upper()
    return n in _NON_INFORMATIVE or (len(n) >= 2 and "NO REMARKS".startswith(n))


def note(bank: str, merchant: str) -> str:
    parsed = parsed_counterparty(bank, merchant)
    if parsed:
        return "" if _is_boilerplate(parsed["remark"]) else parsed["remark"]
    runs = list(_LONG_DIGIT_RUN.finditer(merchant))
    if not runs:
        return ""
    text = re.sub(r"^[-\s]+", "", merchant[runs[-1].end():]).strip()
    return "" if text.upper() in _NON_INFORMATIVE else text


def describe(bank: str, merchant: str) -> tuple[str, str | None, str]:
    """(group_key, counterparty or None, note) for one row."""
    parsed = parsed_counterparty(bank, merchant)
    return group_key(bank, merchant), (parsed["name"] or None) if parsed else None, note(bank, merchant)
