"""Connection, schema migrations and the change marker the widget watches."""
from __future__ import annotations

import os
import sqlite3
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

HOME = Path(os.environ.get("TXDB_HOME", Path(__file__).resolve().parent.parent))
DB_PATH = Path(os.environ.get("TXDB_DB", HOME / "data" / "transactions.db"))

def _rekey_counterparties(conn: sqlite3.Connection) -> None:
    """v5: one key per counterparty, whichever bank the row came from.

    Keys used to carry the bank and the counterparty's bank code, and HDFC
    rows were not parsed at all, so one person could hold four groups at
    once ("LAKSHMI MOHAN" as an HDFC row with a masked VPA, the same row
    unmasked, the same person via @OKAXIS, and the Axis row) and a rename
    had to be repeated for each. This recomputes every row's key, name and
    note with the current rules and carries saved renames over to the new
    keys; where several old keys collapse into one, the most recently
    edited name wins.
    """
    from . import keys

    rows = conn.execute(
        "SELECT t.id, t.merchant, t.group_key, a.bank FROM transactions t "
        "JOIN accounts a ON a.id = t.account_id").fetchall()
    moved: dict[str, str] = {}
    for r in rows:
        group_key, counterparty, note = keys.describe(r["bank"], r["merchant"])
        moved[r["group_key"]] = group_key
        conn.execute("UPDATE transactions SET group_key = ?, counterparty = ?, note = ? WHERE id = ?",
                     (group_key, counterparty, note, r["id"]))

    saved = conn.execute("SELECT group_key, name, updated_at FROM merchant_names ORDER BY updated_at").fetchall()
    conn.execute("DELETE FROM merchant_names")
    for r in saved:  # oldest first, so a later edit overwrites an earlier one
        conn.execute("INSERT INTO merchant_names (group_key, name, updated_at) VALUES (?,?,?) "
                     "ON CONFLICT(group_key) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at",
                     (moved.get(r["group_key"], r["group_key"]), r["name"], r["updated_at"]))


# Each entry upgrades the schema by one version (PRAGMA user_version). An
# entry is either a SQL script or a function that rewrites stored data.
MIGRATIONS = [
    """
    CREATE TABLE accounts (
        id            TEXT PRIMARY KEY,              -- BANK|type|last4
        bank          TEXT NOT NULL,                 -- HDFC / AXIS / SBI
        account_type  TEXT NOT NULL CHECK (account_type IN ('checking', 'credit')),
        last4         TEXT NOT NULL,
        display_name  TEXT,                          -- user override
        network       TEXT,
        created_at    TEXT NOT NULL
    );

    CREATE TABLE transactions (
        id             TEXT PRIMARY KEY,             -- axis-… / sbi-… / hdfc-…
        account_id     TEXT NOT NULL REFERENCES accounts(id),
        date           TEXT NOT NULL,                -- YYYY-MM-DD
        merchant       TEXT NOT NULL,
        amount_paise   INTEGER NOT NULL,             -- negative = money out
        currency       TEXT NOT NULL DEFAULT 'INR',
        status         TEXT NOT NULL DEFAULT 'settled' CHECK (status IN ('settled', 'unsettled')),
        balance_paise  INTEGER,
        raw_row_id     TEXT,
        group_key      TEXT NOT NULL,                -- what a rename applies to
        counterparty   TEXT,
        note           TEXT,
        seq            INTEGER NOT NULL DEFAULT 0,   -- statement order within a day (higher = later)
        first_seen_at  TEXT NOT NULL,
        last_seen_at   TEXT NOT NULL
    );
    CREATE INDEX transactions_by_date ON transactions (date DESC, seq DESC);
    CREATE INDEX transactions_by_account ON transactions (account_id, date);
    CREATE INDEX transactions_by_group ON transactions (group_key);

    CREATE TABLE tracked (
        transaction_id  TEXT PRIMARY KEY,
        tracked_at      TEXT NOT NULL
    );

    CREATE TABLE merchant_names (
        group_key   TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        updated_at  TEXT NOT NULL
    );

    CREATE TABLE balances (
        account_id     TEXT PRIMARY KEY REFERENCES accounts(id),
        balance_paise  INTEGER NOT NULL,
        currency       TEXT NOT NULL DEFAULT 'INR',
        as_of          TEXT NOT NULL
    );
    CREATE TABLE balance_history (
        account_id     TEXT NOT NULL REFERENCES accounts(id),
        as_of          TEXT NOT NULL,
        balance_paise  INTEGER NOT NULL,
        PRIMARY KEY (account_id, as_of)
    );

    CREATE TABLE card_cycles (
        account_id               TEXT PRIMARY KEY REFERENCES accounts(id),
        name                     TEXT,
        unbilled_paise           INTEGER,
        total_outstanding_paise  INTEGER,
        upcoming_due_paise       INTEGER,
        payment_status           TEXT,
        last_payment_paise       INTEGER,
        last_payment_date        TEXT,
        spent_paise              INTEGER,
        credited_paise           INTEGER,
        fetched_at               TEXT NOT NULL
    );

    CREATE TABLE bills (
        account_id     TEXT PRIMARY KEY REFERENCES accounts(id),
        marked_paid    INTEGER NOT NULL DEFAULT 0,
        notified_date  TEXT
    );

    CREATE TABLE fetch_runs (
        id           INTEGER PRIMARY KEY,
        bank         TEXT NOT NULL,
        started_at   TEXT NOT NULL,
        finished_at  TEXT,
        outcome      TEXT CHECK (outcome IN ('done', 'error', 'cancelled')),
        message      TEXT,
        added        INTEGER,
        total        INTEGER
    );

    -- Raw per-bank tables: every scraped field, shaped like each bank's
    -- statement. Each row belongs to one shared transactions row.
    CREATE TABLE sbi_transactions (
        id              TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE,
        account_id      TEXT NOT NULL,
        date_text       TEXT,
        description     TEXT,
        amount_text     TEXT,
        balance_text    TEXT,
        direction_icon  TEXT,
        sign_source     TEXT,
        upi_ref         TEXT,
        fetched_at      TEXT NOT NULL
    );
    CREATE TABLE axis_transactions (
        id            TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE,
        account_id    TEXT NOT NULL,
        date_text     TEXT,
        description   TEXT,
        amount_text   TEXT,
        balance_text  TEXT,
        occurrence    INTEGER,
        window_start  TEXT,
        window_end    TEXT,
        fetched_at    TEXT NOT NULL
    );
    CREATE TABLE hdfc_savings_transactions (
        id                    TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE,
        account_id            TEXT NOT NULL,
        date_text             TEXT,
        description           TEXT,
        ref_no                TEXT,
        amount_text           TEXT,
        dr_cr_text            TEXT,
        closing_balance_text  TEXT,
        fetched_at            TEXT NOT NULL
    );
    CREATE TABLE hdfc_card_transactions (
        id           TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE,
        account_id   TEXT NOT NULL,
        date_text    TEXT,
        description  TEXT,
        amount_text  TEXT,
        dr_cr_text   TEXT,
        status       TEXT,
        card_name    TEXT,
        fetched_at   TEXT NOT NULL
    );
    CREATE TABLE hdfc_card_cycles_raw (
        account_id            TEXT PRIMARY KEY REFERENCES accounts(id),
        name                  TEXT,
        unbilled_amount       TEXT,
        total_outstanding     TEXT,
        upcoming_payment_due  TEXT,
        payment_status        TEXT,
        last_payment_amount   TEXT,
        last_payment_date     TEXT,
        spent_this_cycle      TEXT,
        credited_this_cycle   TEXT,
        fetched_at            TEXT NOT NULL
    );

    -- Per-bank views for ad-hoc queries: raw fields + shared row + user state.
    CREATE VIEW sbi_view AS
        SELECT t.*, r.date_text, r.amount_text, r.balance_text, r.direction_icon, r.sign_source, r.upi_ref,
               (k.transaction_id IS NOT NULL) AS tracked, n.name AS renamed_to
        FROM transactions t JOIN sbi_transactions r ON r.id = t.id
        LEFT JOIN tracked k ON k.transaction_id = t.id LEFT JOIN merchant_names n ON n.group_key = t.group_key;
    CREATE VIEW axis_view AS
        SELECT t.*, r.date_text, r.amount_text, r.balance_text, r.occurrence, r.window_start, r.window_end,
               (k.transaction_id IS NOT NULL) AS tracked, n.name AS renamed_to
        FROM transactions t JOIN axis_transactions r ON r.id = t.id
        LEFT JOIN tracked k ON k.transaction_id = t.id LEFT JOIN merchant_names n ON n.group_key = t.group_key;
    CREATE VIEW hdfc_view AS
        SELECT t.*, COALESCE(s.date_text, c.date_text) AS date_text, COALESCE(s.amount_text, c.amount_text) AS amount_text,
               COALESCE(s.dr_cr_text, c.dr_cr_text) AS dr_cr_text, s.ref_no, s.closing_balance_text, c.card_name,
               (k.transaction_id IS NOT NULL) AS tracked, n.name AS renamed_to
        FROM transactions t JOIN accounts a ON a.id = t.account_id AND a.bank = 'HDFC'
        LEFT JOIN hdfc_savings_transactions s ON s.id = t.id LEFT JOIN hdfc_card_transactions c ON c.id = t.id
        LEFT JOIN tracked k ON k.transaction_id = t.id LEFT JOIN merchant_names n ON n.group_key = t.group_key;
    """,
    # v2: credit card bill dates (bill generation day, last/next bill, due date).
    """
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN billing_cycle TEXT;   -- "Billing cycle : 12th of every month"
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN due_text TEXT;        -- "Due on 1st Nov"
    ALTER TABLE card_cycles ADD COLUMN statement_day INTEGER;         -- day of month the bill is generated
    ALTER TABLE card_cycles ADD COLUMN statement_date TEXT;           -- latest bill (YYYY-MM-DD)
    ALTER TABLE card_cycles ADD COLUMN next_statement_date TEXT;
    ALTER TABLE card_cycles ADD COLUMN due_date TEXT;                 -- last day to pay the latest bill
    """,
    # v3: the Overview tab's "Outstanding Summary" split behind the total —
    # the bill already generated, what has been paid against it, the spend
    # that becomes next month's bill, and the unsettled remainder.
    """
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN last_statement_amount TEXT;  -- "₹4,374.00"
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN unbilled_credits TEXT;       -- "- ₹3,779.00" (paid in)
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN unbilled_purchases TEXT;     -- next month's bill so far
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN unsettled_amount TEXT;       -- loans/unsettled remainder
    ALTER TABLE card_cycles ADD COLUMN last_statement_paise INTEGER;
    ALTER TABLE card_cycles ADD COLUMN unbilled_credits_paise INTEGER;       -- negative: money in the card
    ALTER TABLE card_cycles ADD COLUMN unbilled_purchases_paise INTEGER;
    ALTER TABLE card_cycles ADD COLUMN unsettled_paise INTEGER;
    """,
    # v4: the card's limit. Both cards of this account report the same two
    # figures — the limit is one shared pool, not one limit per card (total
    # minus available equals the two cards' outstanding added together), so
    # the widget shows it once per bank rather than once per row.
    """
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN credit_limit_total TEXT;   -- "₹1,38,000.00"
    ALTER TABLE hdfc_card_cycles_raw ADD COLUMN available_limit TEXT;      -- "₹1,18,272.23"
    ALTER TABLE card_cycles ADD COLUMN credit_limit_paise INTEGER;
    ALTER TABLE card_cycles ADD COLUMN available_limit_paise INTEGER;
    """,
    # v5: see _rekey_counterparties — one key per counterparty, across banks.
    _rekey_counterparties,
    # v6: a balance the statement printed, or one worked back from the
    # account's current balance for rows scraped before the balance was
    # kept. Derived ones are replaced the moment a fetch reads the real
    # figure, and the fetch's own reconciliation then checks it.
    """
    ALTER TABLE transactions ADD COLUMN balance_derived INTEGER NOT NULL DEFAULT 0;
    """,
    # v7: a second bank's credit card arrived (ICICI), and the raw card
    # table was called hdfc_card_cycles_raw. The account id already carries
    # the bank, so the table never needed the name; it is renamed and the
    # old name kept as a view, since `sqlite3 txdb hdfc_card_cycles_raw` is
    # in the README and in muscle memory.
    """
    ALTER TABLE hdfc_card_cycles_raw RENAME TO card_cycles_raw;
    CREATE VIEW hdfc_card_cycles_raw AS
        SELECT r.* FROM card_cycles_raw r JOIN accounts a ON a.id = r.account_id
        WHERE a.bank = 'HDFC';
    """,
    # v8: investments. INDmoney's MCP server is read-only and hands over
    # holdings, not a statement, so this half of the database is a dated
    # snapshot plus the activity worked out from consecutive snapshots.
    # It stays clear of accounts and transactions: an investment has units
    # and a price where a bank row has an amount and a running balance, and
    # accounts.account_type only knows 'checking' and 'credit'.
    #
    # Money stays INTEGER paise. Units, prices and rates are INTEGER at
    # 1e-4 (to_e4 / from_e4), because a NAV is quoted to four decimals and
    # a fund holds fractional units -- paise would round both away.
    """
    CREATE TABLE instruments (
        id TEXT PRIMARY KEY,                     -- MF|<isin>, EQ|NSE|<symbol>, US|<ticker>, EPF|<id>
        kind TEXT NOT NULL,                      -- mf, equity, us_equity, etf, bond, epf, nps, fd, gold, crypto, reit, pms, aif, cash, other
        name TEXT NOT NULL,
        isin TEXT,
        symbol TEXT,
        category TEXT,                           -- 'Flexi Cap', 'Large Cap', once enrichment fills it
        amc TEXT,                                -- fund house, or the exchange for a stock
        currency TEXT NOT NULL DEFAULT 'INR',
        ind_key TEXT,                            -- INDmoney's own identifier, for re-querying
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL
    );
    CREATE INDEX instruments_by_kind ON instruments (kind, name);

    -- What is held right now: one row per instrument per broker, replaced
    -- on every fetch. INDmoney aggregates external brokers, so the same
    -- fund can sit in two places and they do not add up into one holding.
    CREATE TABLE holdings (
        instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
        broker TEXT NOT NULL DEFAULT '',
        units_e4 INTEGER,
        avg_cost_e4 INTEGER,
        invested_paise INTEGER,
        price_e4 INTEGER,                        -- NAV, or last traded price
        value_paise INTEGER,
        pnl_paise INTEGER,
        pnl_pct_e4 INTEGER,
        xirr_e4 INTEGER,
        day_change_paise INTEGER,
        as_of TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        PRIMARY KEY (instrument_id, broker)
    );

    -- The same row kept per day, the way balance_history keeps a bank
    -- balance. Everything the widget can say about a portfolio over time
    -- -- and every derived buy and sell -- comes out of this table.
    CREATE TABLE holding_history (
        instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
        broker TEXT NOT NULL DEFAULT '',
        as_of TEXT NOT NULL,
        units_e4 INTEGER,
        avg_cost_e4 INTEGER,
        invested_paise INTEGER,
        price_e4 INTEGER,
        value_paise INTEGER,
        pnl_paise INTEGER,
        xirr_e4 INTEGER,
        PRIMARY KEY (instrument_id, broker, as_of)
    );
    CREATE INDEX holding_history_by_date ON holding_history (as_of);

    CREATE TABLE portfolio_totals (
        as_of TEXT PRIMARY KEY,
        net_worth_paise INTEGER,
        assets_paise INTEGER,
        liabilities_paise INTEGER,
        invested_paise INTEGER,
        value_paise INTEGER,
        pnl_paise INTEGER,
        day_change_paise INTEGER,
        xirr_e4 INTEGER,
        fetched_at TEXT NOT NULL
    );

    CREATE TABLE allocation_history (
        as_of TEXT NOT NULL,
        bucket TEXT NOT NULL,
        value_paise INTEGER,
        pct_e4 INTEGER,
        PRIMARY KEY (as_of, bucket)
    );

    -- Portfolio "transactions". INDmoney exposes no transaction history,
    -- so every row here is worked out by diffing two snapshots and is
    -- flagged inferred, the same honesty rule transactions.balance_derived
    -- follows: a number nobody read off a statement says so.
    CREATE TABLE portfolio_activity (
        id TEXT PRIMARY KEY,
        instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
        broker TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('buy', 'sell', 'sip', 'new', 'exit', 'corporate')),
        units_e4 INTEGER,
        price_e4 INTEGER,
        amount_paise INTEGER,
        inferred INTEGER NOT NULL DEFAULT 1,
        note TEXT,
        first_seen_at TEXT NOT NULL
    );
    CREATE INDEX portfolio_activity_by_date ON portfolio_activity (date DESC, id);

    -- Every tool response as it arrived, so a later idea can mine a field
    -- without another round trip. Same reasoning as card_cycles_raw.
    CREATE TABLE indmoney_raw (
        tool TEXT NOT NULL,
        as_of TEXT NOT NULL,
        payload TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        PRIMARY KEY (tool, as_of)
    );

    CREATE VIEW portfolio_view AS
        SELECT i.kind, i.name, i.symbol, i.isin, i.category, i.amc, h.broker,
               h.units_e4 / 10000.0 AS units,
               h.avg_cost_e4 / 10000.0 AS avg_cost,
               h.price_e4 / 10000.0 AS price,
               h.invested_paise / 100.0 AS invested,
               h.value_paise / 100.0 AS value,
               h.pnl_paise / 100.0 AS pnl,
               h.xirr_e4 / 10000.0 AS xirr,
               h.as_of, h.instrument_id
        FROM holdings h JOIN instruments i ON i.id = h.instrument_id
        ORDER BY h.value_paise DESC;
    """,
    # v9: units need eight decimals, not four. A fractional US share is
    # quoted to seven (0.0081521 of SanDisk), and rounding that to four
    # moved a holding's value by over a percent -- enough for the
    # portfolio's own units-times-price check to call it a mismatch,
    # which it was. Prices stay at 1e-4: a NAV has four decimals and a
    # price in rupees needs no more.
    """
    DROP VIEW portfolio_view;

    ALTER TABLE holdings ADD COLUMN units_e8 INTEGER;
    UPDATE holdings SET units_e8 = units_e4 * 10000;
    ALTER TABLE holdings DROP COLUMN units_e4;

    ALTER TABLE holding_history ADD COLUMN units_e8 INTEGER;
    UPDATE holding_history SET units_e8 = units_e4 * 10000;
    ALTER TABLE holding_history DROP COLUMN units_e4;

    ALTER TABLE portfolio_activity ADD COLUMN units_e8 INTEGER;
    UPDATE portfolio_activity SET units_e8 = units_e4 * 10000;
    ALTER TABLE portfolio_activity DROP COLUMN units_e4;

    CREATE VIEW portfolio_view AS
        SELECT i.kind, i.name, i.symbol, i.isin, i.category, i.amc, h.broker,
               h.units_e8 / 100000000.0 AS units,
               h.avg_cost_e4 / 10000.0 AS avg_cost,
               h.price_e4 / 10000.0 AS price,
               h.invested_paise / 100.0 AS invested,
               h.value_paise / 100.0 AS value,
               h.pnl_paise / 100.0 AS pnl,
               h.xirr_e4 / 10000.0 AS xirr,
               h.as_of, h.instrument_id
        FROM holdings h JOIN instruments i ON i.id = h.instrument_id
        ORDER BY h.value_paise DESC;
    """,
]


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def connect(path: Path | None = None) -> sqlite3.Connection:
    """Opens (creating if needed) the database and brings the schema up to
    date. Autocommit mode: writes go through write()."""
    path = Path(path or DB_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)  # the database holds account data
    try:
        conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    finally:
        os.umask(old_umask)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA foreign_keys=ON")
    _migrate(conn)
    return conn


def _migrate(conn: sqlite3.Connection) -> None:
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version >= len(MIGRATIONS):
        return
    conn.execute("BEGIN IMMEDIATE")
    try:
        version = conn.execute("PRAGMA user_version").fetchone()[0]  # another process may have migrated
        for i in range(version, len(MIGRATIONS)):
            step = MIGRATIONS[i]
            if callable(step):   # a data migration, not a schema one
                step(conn)
            else:
                for statement in _statements(step):
                    conn.execute(statement)
            conn.execute(f"PRAGMA user_version={i + 1}")
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def _statements(script: str):
    buf = ""
    for line in script.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            if buf.strip():
                yield buf
            buf = ""


@contextmanager
def write(conn: sqlite3.Connection):
    """One write transaction (BEGIN IMMEDIATE, so writers queue rather than
    fail). On commit the change marker is updated so the widget reloads."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    touch_changed(conn)


def touch_changed(conn: sqlite3.Connection | None = None) -> None:
    """Atomically rewrites data/.changed. With WAL the database file itself
    doesn't change on every commit, so this is what the widget watches."""
    path = (Path(conn.execute("PRAGMA database_list").fetchone()[2]).parent if conn else DB_PATH.parent) / ".changed"
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".changed.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        f.write(f"{time.time_ns()}\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def to_paise(amount) -> int | None:
    return None if amount is None else int(round(float(amount) * 100))


def from_paise(paise) -> float | None:
    return None if paise is None else paise / 100


# Units, prices and rates: four decimals, stored as integers for the same
# reason money is. A NAV of 123.4567 is 1234567; 8.4% XIRR is 840.
def to_e4(value) -> int | None:
    return None if value is None else int(round(float(value) * 10000))


def from_e4(value) -> float | None:
    return None if value is None else value / 10000


# Units: eight decimals. A fractional share of a US stock is quoted to
# seven (0.0081521), and four would round away more than the value of
# the holding can tolerate -- see migration v9.
def to_e8(value) -> int | None:
    return None if value is None else int(round(float(value) * 100000000))


def from_e8(value) -> float | None:
    return None if value is None else value / 100000000
