"""The JSON snapshot the widget loads, in the shapes it already uses."""
from __future__ import annotations

import sqlite3

from .db import from_paise
from .ingest import OVERVIEW_FIELDS


def snapshot(conn: sqlite3.Connection) -> dict:
    transactions = [{
        "id": r["id"], "date": r["date"], "merchant": r["merchant"], "amount": from_paise(r["amount_paise"]),
        "currency": r["currency"], "bank": r["bank"], "accountType": r["account_type"], "last4": r["last4"],
        "accountId": r["account_id"], "status": r["status"], "source": "bank-scrape",
        "rawStatementRowId": r["raw_row_id"], "groupKey": r["group_key"], "counterparty": r["counterparty"] or "",
        "note": r["note"] or "", "tracked": bool(r["tracked"]),
        # The running balance the statement showed after this transaction.
        # None for a credit card (no running balance) and for rows scraped
        # before the balance was captured.
        "balance": from_paise(r["balance_paise"]) if r["balance_paise"] is not None else None,
        # True when it was worked back from the account's current balance
        # rather than read off the statement (see ingest.derive_balances).
        "balanceDerived": bool(r["balance_derived"]),
    } for r in conn.execute(
        """SELECT t.*, a.bank, a.account_type, a.last4, (k.transaction_id IS NOT NULL) AS tracked
           FROM transactions t JOIN accounts a ON a.id = t.account_id
           LEFT JOIN tracked k ON k.transaction_id = t.id
           ORDER BY t.date DESC, t.seq DESC, t.id""")]
    balances = [{
        "bank": r["bank"], "accountType": r["account_type"], "last4": r["last4"], "accountId": r["account_id"],
        "balance": from_paise(r["balance_paise"]), "currency": r["currency"], "asOf": r["as_of"],
    } for r in conn.execute(
        "SELECT b.*, a.bank, a.account_type, a.last4 FROM balances b JOIN accounts a ON a.id = b.account_id "
        "ORDER BY a.bank, a.last4")]
    card_overviews = [{
        "name": r["name"] or "", "last4": r["last4"], "accountId": r["account_id"], "bank": r["bank"],
        **{f: r[f] or "" for f in OVERVIEW_FIELDS},
        "billingDay": r["statement_day"], "statementDate": r["statement_date"] or "",
        "nextStatementDate": r["next_statement_date"] or "", "dueDate": r["due_date"] or "",
    } for r in conn.execute(
        "SELECT c.*, a.last4, a.bank, d.statement_day, d.statement_date, d.next_statement_date, d.due_date "
        "FROM card_cycles_raw c JOIN accounts a ON a.id = c.account_id "
        "LEFT JOIN card_cycles d ON d.account_id = c.account_id ORDER BY a.last4")]
    accounts = [{
        "id": r["id"], "bank": r["bank"], "accountType": r["account_type"], "last4": r["last4"],
        "displayName": r["display_name"] or "", "network": r["network"] or "",
    } for r in conn.execute("SELECT * FROM accounts ORDER BY bank, account_type, last4")]
    return {
        "transactions": transactions,
        "balances": balances,
        "cardOverviews": card_overviews,
        "accounts": accounts,
        # Keyed by last4, the key the widget's bill and account-name code uses.
        "bills": {r["last4"]: {"markedPaid": bool(r["marked_paid"]), **({"notifiedDate": r["notified_date"]} if r["notified_date"] else {})}
                  for r in conn.execute("SELECT b.*, a.last4 FROM bills b JOIN accounts a ON a.id = b.account_id")},
        "accountNames": {r["last4"]: r["display_name"] for r in conn.execute(
            "SELECT last4, display_name FROM accounts WHERE display_name IS NOT NULL")},
        "merchantNames": {r["group_key"]: r["name"] for r in conn.execute("SELECT * FROM merchant_names")},
    }


def reconcile(conn: sqlite3.Connection, bank: str | None = None) -> list[dict]:
    """Checks the running balances a statement gave us against the amounts
    beside them, for every checking/savings account (a credit card has no
    running balance). Two things have to hold:

      - consecutive rows: balance - previous balance == this row's amount;
      - the newest row's balance == the account's saved current balance.

    Returns one dict per problem, newest account first, empty when everything
    adds up. Rows with no balance are skipped rather than failing: older rows
    were saved before the balance was scraped, and a gap is not a mismatch.
    """
    problems = []
    accounts = conn.execute(
        "SELECT a.id, a.bank, a.last4, b.balance_paise AS current_paise FROM accounts a "
        "LEFT JOIN balances b ON b.account_id = a.id "
        "WHERE a.account_type != 'credit'" + (" AND a.bank = ?" if bank else "") + " ORDER BY a.bank, a.last4",
        (bank.upper(),) if bank else ()).fetchall()

    for account in accounts:
        rows = conn.execute(
            "SELECT id, date, merchant, amount_paise, balance_paise FROM transactions "
            "WHERE account_id = ? AND balance_paise IS NOT NULL ORDER BY date, seq, id",
            (account["id"],)).fetchall()
        if not rows:
            continue

        previous = None
        for row in rows:
            if previous is not None:
                step = row["balance_paise"] - previous["balance_paise"]
                if step != row["amount_paise"]:
                    problems.append({
                        "account": account["id"], "kind": "step", "id": row["id"], "date": row["date"],
                        "merchant": row["merchant"], "expected": from_paise(previous["balance_paise"] + row["amount_paise"]),
                        "found": from_paise(row["balance_paise"]), "off_by": from_paise(row["balance_paise"] - previous["balance_paise"] - row["amount_paise"]),
                    })
            previous = row

        newest = rows[-1]
        if account["current_paise"] is not None and newest["balance_paise"] != account["current_paise"]:
            problems.append({
                "account": account["id"], "kind": "current", "id": newest["id"], "date": newest["date"],
                "merchant": newest["merchant"], "expected": from_paise(account["current_paise"]),
                "found": from_paise(newest["balance_paise"]),
                "off_by": from_paise(newest["balance_paise"] - account["current_paise"]),
            })
    return problems


def reconcile_summary(conn: sqlite3.Connection, bank: str | None = None) -> str:
    """One line for a fetch's done message / the CLI: "" when it all adds up."""
    problems = reconcile(conn, bank)
    if not problems:
        return ""
    first = problems[0]
    worst = f"{first['merchant'][:28]} on {first['date']} (off by {first['off_by']:+.2f})"
    return (f"{len(problems)} balance mismatch{'es' if len(problems) > 1 else ''}: {worst}"
            if len(problems) > 1 else f"balance mismatch: {worst}")
