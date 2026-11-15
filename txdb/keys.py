"""What a transaction is "about": the group key a rename applies to, the
counterparty name shown by default, and the free-text remark. Ported from
the widget's Model.js so the rules live in one place and are stored with
each row.

Each bank writes the same transfer differently — SBI and Axis put their
own account/reference numbers before the counterparty, HDFC writes
"UPI-<name>-<vpa>-<ifsc>-<refnum>-<remark>" — so each has its own pattern
here. The key is "UPI|<BANK>|<NAME>": the same person (or the same
transfer) seen on two of your banks is two groups, one per bank, so a rename
on an HDFC row never changes the matching SBI or Axis row - a transfer
between your own accounts appears once on each, and each side gets its own
name. Within one bank the VPA is deliberately NOT part of the key (HDFC masks
it on some rows and not others, which once split a single person into four
groups). Rows nothing can parse - bank charges, interest, card vendor names -
stay keyed by bank and description, where the text is the only identity they
have."""
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


def _upi_key(bank: str, name: str) -> str:
    """One counterparty, one key per bank the row came from."""
    return f"UPI|{bank}|{_clean(name).upper()}"


def parsed_counterparty(bank: str, merchant: str) -> dict | None:
    """{key, name, remark} for a UPI/NEFT row of any of the three banks,
    else None."""
    if bank == "SBI":
        m = _SBI_UPI.match(merchant)
        if m:
            name = _clean(m.group(1))
            return {"key": _upi_key(bank, name), "name": name, "remark": _clean(m.group(3))}
        m = _SBI_NEFT.match(merchant)
        if m:
            name = _clean(m.group(1))
            return {"key": f"NEFT|{bank}|{name.upper()}", "name": name, "remark": ""}
    if bank == "AXIS":
        m = _AXIS_UPI.match(merchant)
        if m:
            name = _clean(m.group(1))
            return {"key": _upi_key(bank, name), "name": name, "remark": _clean(m.group(3))}
    if bank == "HDFC":
        m = _HDFC_UPI.match(merchant)
        if m:
            name = _clean(m.group(1))
            if name:
                return {"key": _upi_key(bank, name), "name": name, "remark": _clean(m.group(5))}
    return None


# What HDFC prints for a UPI payment, read from the right so a VPA with a hyphen or a masked one
# ("BINUMK42-1@OKAXIS", "******42-1@OKAXIS") does not break the split: UPI-<name>-<vpa>-<ifsc>-<ref>[-<remark>].
_HDFC_UPI_LOOSE = re.compile(
    r"^UPI-(?P<name>.+?)-(?P<vpa>\S+@[A-Za-z0-9.]+)-(?P<ifsc>[A-Za-z]{4}0[A-Za-z0-9]{6})-(?P<ref>\d+)(?:-(?P<remark>.*))?$",
    re.I)
# A card or debit row: "Upi-tobox Ventures Private Li" - the merchant after a "Upi-" prefix, no id at all.
_HDFC_UPI_PLAIN = re.compile(r"^UPI-(?P<name>[^@]+)$", re.I)


def display_counterparty(bank: str, merchant: str) -> dict | None:
    """{name, remark} to SHOW for a row, else None. The strict parse first (parsed_counterparty), then
    for HDFC the looser shapes above, so the screen shows "BINU M K" and never the whole UPI id.

    Display only: the group key (what a rename or a taught category is saved under) still comes from
    parsed_counterparty, so changing what is shown can never orphan something the person saved.
    The same rules are in Model.js (displayCounterparty)."""
    parsed = parsed_counterparty(bank, merchant)
    if parsed:
        return {"name": parsed["name"], "remark": parsed["remark"]}
    if bank != "HDFC":
        return None
    m = _HDFC_UPI_LOOSE.match(merchant or "")
    if m and _clean(m.group("name")):
        return {"name": _clean(m.group("name")), "remark": _clean(m.group("remark"))}
    m = _HDFC_UPI_PLAIN.match(_clean(merchant))
    if m and _clean(m.group("name")):
        name = _clean(m.group("name"))
        return {"name": name[0].upper() + name[1:], "remark": ""}
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
