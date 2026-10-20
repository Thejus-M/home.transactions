"""Write API for the bank fetchers. Each call is one transaction and updates
the change marker the widget watches.

A row is a dict with the shared fields the fetchers already build:
  id, date (YYYY-MM-DD), merchant, amount (float, negative = money out),
  currency, rawStatementRowId, and optionally status ('settled' /
  'unsettled'), balance (float), seq (statement order within a day, higher =
  later) and raw (the bank's own fields; see the per-bank tables in db.py)."""
from __future__ import annotations

import calendar
import re
import sqlite3
from datetime import date, datetime, timedelta

from . import keys
from .db import now, to_paise, write

RAW_TABLES = {
    ("SBI", "checking"): ("sbi_transactions", ["date_text", "description", "amount_text", "balance_text",
                                               "direction_icon", "sign_source", "upi_ref"]),
    ("AXIS", "checking"): ("axis_transactions", ["date_text", "description", "amount_text", "balance_text",
                                                 "occurrence", "window_start", "window_end"]),
    ("HDFC", "checking"): ("hdfc_savings_transactions", ["date_text", "description", "ref_no", "amount_text",
                                                         "dr_cr_text", "closing_balance_text"]),
    ("HDFC", "credit"): ("hdfc_card_transactions", ["date_text", "description", "amount_text", "dr_cr_text",
                                                    "status", "card_name"]),
}
OVERVIEW_FIELDS = ["unbilled_amount", "total_outstanding", "upcoming_payment_due", "payment_status",
                   "last_payment_amount", "last_payment_date", "spent_this_cycle", "credited_this_cycle",
                   "billing_cycle", "due_text", "last_statement_amount", "unbilled_credits",
                   "unbilled_purchases", "unsettled_amount", "credit_limit_total", "available_limit"]


def account_id(bank: str, account_type: str, last4: str) -> str:
    return f"{bank}|{account_type}|{last4}"


def ensure_account(conn: sqlite3.Connection, bank: str, account_type: str, last4: str,
                   network: str | None = None) -> str:
    if not last4:
        raise ValueError("An account needs its last four digits.")
    aid = account_id(bank, account_type, last4)
    with write(conn):
        conn.execute("INSERT INTO accounts (id, bank, account_type, last4, network, created_at) VALUES (?,?,?,?,?,?) "
                     "ON CONFLICT(id) DO UPDATE SET network = COALESCE(excluded.network, accounts.network)",
                     (aid, bank, account_type, last4, network, now()))
    return aid


def _account(conn: sqlite3.Connection, aid: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM accounts WHERE id = ?", (aid,)).fetchone()
    if row is None:
        raise ValueError(f"Unknown account {aid}; call ensure_account first.")
    return row


def _upsert(conn: sqlite3.Connection, account: sqlite3.Row, row: dict, ts: str) -> None:
    gkey, counterparty, note = keys.describe(account["bank"], row["merchant"])
    conn.execute(
        """INSERT INTO transactions (id, account_id, date, merchant, amount_paise, currency, status, balance_paise,
                                     raw_row_id, group_key, counterparty, note, seq, first_seen_at, last_seen_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET
             date = excluded.date, merchant = excluded.merchant, amount_paise = excluded.amount_paise,
             currency = excluded.currency, status = excluded.status,
             balance_paise = COALESCE(excluded.balance_paise, transactions.balance_paise),
             -- A figure the statement printed replaces one we worked out.
             balance_derived = CASE WHEN excluded.balance_paise IS NULL THEN transactions.balance_derived ELSE 0 END,
             raw_row_id = excluded.raw_row_id, group_key = excluded.group_key,
             counterparty = excluded.counterparty, note = excluded.note, seq = excluded.seq,
             last_seen_at = excluded.last_seen_at""",
        (row["id"], account["id"], row["date"], row["merchant"], to_paise(row["amount"]), row.get("currency", "INR"),
         row.get("status", "settled"), to_paise(row.get("balance")), row.get("rawStatementRowId"),
         gkey, counterparty, note, row.get("seq", 0), ts, ts))
    raw = row.get("raw")
    table = RAW_TABLES.get((account["bank"], account["account_type"]))
    if raw is not None and table:
        name, columns = table
        values = [raw.get(c) for c in columns]
        conn.execute(f"INSERT OR REPLACE INTO {name} (id, account_id, {', '.join(columns)}, fetched_at) "
                     f"VALUES (?, ?, {', '.join('?' * len(columns))}, ?)", (row["id"], account["id"], *values, ts))


def upsert_rows(conn: sqlite3.Connection, aid: str, rows: list[dict]) -> int:
    """Insert new rows, refresh existing ones. Returns how many were new."""
    account = _account(conn, aid)
    ts = now()
    with write(conn):
        known = {r[0] for r in conn.execute("SELECT id FROM transactions WHERE account_id = ?", (aid,))}
        for row in rows:
            _upsert(conn, account, row, ts)
    return sum(1 for r in rows if r["id"] not in known)


def replace_window(conn: sqlite3.Connection, aid: str, rows: list[dict], start: str, end: str) -> int:
    """`rows` is a complete, checked read of [start, end]: settled rows of
    this account in that window that aren't in it are removed. Tracked
    flags and renames are kept (they aren't tied to row lifetimes)."""
    account = _account(conn, aid)
    ts = now()
    ids = {r["id"] for r in rows}
    with write(conn):
        known = {r[0] for r in conn.execute("SELECT id FROM transactions WHERE account_id = ?", (aid,))}
        stale = [r[0] for r in conn.execute(
            "SELECT id FROM transactions WHERE account_id = ? AND status = 'settled' AND date BETWEEN ? AND ?",
            (aid, start, end)) if r[0] not in ids]
        conn.executemany("DELETE FROM transactions WHERE id = ?", [(i,) for i in stale])
        for row in rows:
            _upsert(conn, account, row, ts)
    return len(ids - known)


def replace_unsettled(conn: sqlite3.Connection, aid: str, rows: list[dict]) -> None:
    """Card spends not yet settled are a snapshot: replaced on every fetch.
    When one has since settled (same date, amount and description), a
    tracked flag on it moves to the settled row."""
    account = _account(conn, aid)
    ts = now()
    ids = {r["id"] for r in rows}
    with write(conn):
        gone = conn.execute("SELECT id, date, amount_paise, merchant FROM transactions "
                            "WHERE account_id = ? AND status = 'unsettled'", (aid,)).fetchall()
        for old in gone:
            if old["id"] in ids:
                continue
            settled = conn.execute(
                "SELECT id FROM transactions WHERE account_id = ? AND status = 'settled' AND date = ? "
                "AND amount_paise = ? AND merchant = ? LIMIT 1",
                (aid, old["date"], old["amount_paise"], old["merchant"])).fetchone()
            if settled:
                conn.execute("UPDATE OR IGNORE tracked SET transaction_id = ? WHERE transaction_id = ?",
                             (settled[0], old["id"]))
            conn.execute("DELETE FROM tracked WHERE transaction_id = ?", (old["id"],))
            conn.execute("DELETE FROM transactions WHERE id = ?", (old["id"],))
        for row in rows:
            _upsert(conn, account, {**row, "status": "unsettled"}, ts)


def derive_balances(conn: sqlite3.Connection, bank: str | None = None) -> int:
    """Fills in the running balance for rows that have none, by walking back
    from the account's current balance: the newest row ends at that balance,
    and each earlier row ends at the next row's balance less the next row's
    amount.

    It is arithmetic, not a reading: it assumes every movement between a row
    and today is saved, so one missing transaction shifts every balance
    before it. Rows filled this way are flagged `balance_derived`, a real
    scraped figure overwrites them, and the reconciliation each fetch runs
    is what proves them right or wrong. Rows already carrying a balance are
    left alone. Returns how many rows were filled.
    """
    accounts = conn.execute(
        "SELECT a.id, b.balance_paise FROM accounts a JOIN balances b ON b.account_id = a.id "
        "WHERE a.account_type != 'credit'" + (" AND a.bank = ?" if bank else ""),
        (bank.upper(),) if bank else ()).fetchall()

    filled = 0
    with write(conn):
        for account in accounts:
            rows = conn.execute(
                "SELECT id, amount_paise, balance_paise FROM transactions "
                "WHERE account_id = ? ORDER BY date DESC, seq DESC, id DESC", (account["id"],)).fetchall()
            running = account["balance_paise"]
            for row in rows:
                if row["balance_paise"] is None:
                    conn.execute("UPDATE transactions SET balance_paise = ?, balance_derived = 1 WHERE id = ?",
                                 (running, row["id"]))
                    filled += 1
                else:
                    running = row["balance_paise"]
                running -= row["amount_paise"]
    return filled


def known_ids(conn: sqlite3.Connection, aid: str) -> set[str]:
    return {r[0] for r in conn.execute("SELECT id FROM transactions WHERE account_id = ?", (aid,))}


def set_balance(conn: sqlite3.Connection, aid: str, balance: float | None, currency: str = "INR",
                as_of: str | None = None) -> None:
    """Ignored when the balance couldn't be read: the saved one stays."""
    if balance is None:
        return
    as_of = as_of or now()
    with write(conn):
        conn.execute("INSERT INTO balances (account_id, balance_paise, currency, as_of) VALUES (?,?,?,?) "
                     "ON CONFLICT(account_id) DO UPDATE SET balance_paise = excluded.balance_paise, "
                     "currency = excluded.currency, as_of = excluded.as_of",
                     (aid, to_paise(balance), currency, as_of))
        conn.execute("INSERT OR REPLACE INTO balance_history (account_id, as_of, balance_paise) VALUES (?,?,?)",
                     (aid, as_of, to_paise(balance)))


def parse_money(text: str | None) -> int | None:
    """"₹1,234.50" / "- ₹956.62" -> paise (sign kept); None when empty."""
    if not text:
        return None
    digits = re.sub(r"[^0-9.]", "", str(text))
    if not digits:
        return None
    value = to_paise(float(digits))
    return -value if "-" in str(text) else value


_CYCLE_DAY = re.compile(r"(\d{1,2})(?:st|nd|rd|th)?\s+of every month", re.I)
_DUE_ON = re.compile(r"Due on\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,})(?:\s+(\d{4}))?", re.I)


def _on_day(year: int, month: int, day: int) -> date:
    """`day` of that month, or its last day for short months (31st -> 30 Nov)."""
    return date(year, month, min(day, calendar.monthrange(year, month)[1]))


def bill_dates(billing_cycle: str | None, due_text: str | None, today: date | None = None) -> dict:
    """Bill generation day and dates from HDFC's Overview wording:
    "Billing cycle : 12th of every month" -> the latest bill is the most
    recent 12th (today or earlier) and the next one a month later.
    "Due on 1st Nov" (no year) -> the first such date on or after the
    latest bill."""
    today = today or date.today()
    out = {"statement_day": None, "statement_date": None, "next_statement_date": None, "due_date": None}
    m = _CYCLE_DAY.search(billing_cycle or "")
    if m:
        day = int(m.group(1))
        last = _on_day(today.year, today.month, day)
        if last > today:
            prev = (today.replace(day=1) - timedelta(days=1))
            last = _on_day(prev.year, prev.month, day)
        nxt_month = last.month % 12 + 1
        nxt = _on_day(last.year + (last.month == 12), nxt_month, day)
        out.update(statement_day=day, statement_date=last.isoformat(), next_statement_date=nxt.isoformat())
    m = _DUE_ON.search(due_text or "")
    if m:
        try:
            month = datetime.strptime(m.group(2)[:3].title(), "%b").month
        except ValueError:
            month = None
        if month:
            base = date.fromisoformat(out["statement_date"]) if out["statement_date"] else today
            year = int(m.group(3)) if m.group(3) else base.year
            due = _on_day(year, month, int(m.group(1)))
            if not m.group(3) and due < base:
                due = _on_day(year + 1, month, int(m.group(1)))
            out["due_date"] = due.isoformat()
    return out


def set_card_cycle(conn: sqlite3.Connection, aid: str, overview: dict) -> None:
    """HDFC billing-cycle overview: raw display strings plus parsed numbers."""
    ts = now()
    with write(conn):
        conn.execute(f"INSERT OR REPLACE INTO hdfc_card_cycles_raw (account_id, name, {', '.join(OVERVIEW_FIELDS)}, "
                     f"fetched_at) VALUES (?, ?, {', '.join('?' * len(OVERVIEW_FIELDS))}, ?)",
                     (aid, overview.get("name"), *[overview.get(f) for f in OVERVIEW_FIELDS], ts))
        dates = bill_dates(overview.get("billing_cycle"), overview.get("due_text"))
        conn.execute(
            """INSERT OR REPLACE INTO card_cycles (account_id, name, unbilled_paise, total_outstanding_paise,
                 upcoming_due_paise, payment_status, last_payment_paise, last_payment_date, spent_paise,
                 credited_paise, fetched_at, statement_day, statement_date, next_statement_date, due_date,
                 last_statement_paise, unbilled_credits_paise, unbilled_purchases_paise, unsettled_paise,
                 credit_limit_paise, available_limit_paise)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (aid, overview.get("name"), parse_money(overview.get("unbilled_amount")),
             parse_money(overview.get("total_outstanding")), parse_money(overview.get("upcoming_payment_due")),
             overview.get("payment_status"), parse_money(overview.get("last_payment_amount")),
             overview.get("last_payment_date"), parse_money(overview.get("spent_this_cycle")),
             parse_money(overview.get("credited_this_cycle")), ts, dates["statement_day"],
             dates["statement_date"], dates["next_statement_date"], dates["due_date"],
             parse_money(overview.get("last_statement_amount")),
             # Kept negative, the way the page shows it: money sitting in the card.
             parse_money(overview.get("unbilled_credits")),
             parse_money(overview.get("unbilled_purchases")),
             parse_money(overview.get("unsettled_amount")),
             parse_money(overview.get("credit_limit_total")),
             parse_money(overview.get("available_limit"))))


def start_run(conn: sqlite3.Connection, bank: str) -> int:
    with write(conn):
        return conn.execute("INSERT INTO fetch_runs (bank, started_at) VALUES (?, ?)", (bank, now())).lastrowid


def finish_run(conn: sqlite3.Connection, run_id: int, outcome: str, message: str,
               added: int | None = None, total: int | None = None) -> None:
    with write(conn):
        conn.execute("UPDATE fetch_runs SET finished_at = ?, outcome = ?, message = ?, added = ?, total = ? "
                     "WHERE id = ?", (now(), outcome, message, added, total, run_id))


def count(conn: sqlite3.Connection, bank: str | None = None) -> int:
    if bank is None:
        return conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    return conn.execute("SELECT COUNT(*) FROM transactions t JOIN accounts a ON a.id = t.account_id "
                        "WHERE a.bank = ?", (bank,)).fetchone()[0]
