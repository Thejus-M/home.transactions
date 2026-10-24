"""The investments half of the database: write a dated snapshot, work out
what must have been bought or sold between two of them, and hand the
widget the same kind of JSON the bank side gets.

Why it is shaped like this. INDmoney's MCP server is read-only and
reports holdings, not a statement: there is no transaction history to
fetch. So the fetcher stores what is held, dated, on every run, and
everything with a time axis -- a value line, a buy, a SIP, money put in
this month -- is worked out from consecutive snapshots here. Those rows
are flagged `inferred`, and the widget says so, the same way a running
balance nobody read off a statement is flagged balance_derived.

Money is paise and quantities are 1e-4 integers (db.to_e4 / db.from_e4);
floats appear only at the JSON boundary, as on the bank side.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import date, datetime

from .db import from_e4, from_e8, from_paise, now, to_e4, to_e8, to_paise, write

# Below this, a unit change is rounding in the broker's feed, not a trade.
# Small, because a fractional US share is a few thousandths of one.
UNIT_EPS = 1000          # 0.00001 units, at the e8 scale
# A buy whose rupee amount repeats within this, at roughly a month's
# spacing, is an instalment rather than a one-off purchase.
SIP_TOLERANCE = 0.02
SIP_MIN_GAP_DAYS = 20
SIP_MAX_GAP_DAYS = 40
# How much of the value line the widget gets. Half a year of daily points
# draws fine and keeps the snapshot JSON small.
HISTORY_POINTS = 180


# --- writing ----------------------------------------------------------------

def record_snapshot(conn: sqlite3.Connection, snap: dict) -> int:
    """One fetch's worth of portfolio data, in one transaction.

    Re-running on the same day overwrites that day's rows rather than
    adding a second set, so a fetch is safe to repeat. Returns how many
    holdings were saved.
    """
    as_of = snap["as_of"]
    fetched_at = snap.get("fetched_at") or now()
    holdings = snap.get("holdings") or []

    with write(conn):
        for h in holdings:
            _upsert_instrument(conn, h, fetched_at)

        conn.execute("DELETE FROM holdings")
        for h in holdings:
            conn.execute(
                """INSERT INTO holdings (instrument_id, broker, units_e8, avg_cost_e4, invested_paise,
                                         price_e4, value_paise, pnl_paise, pnl_pct_e4, xirr_e4,
                                         day_change_paise, as_of, fetched_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (h["id"], h.get("broker") or "", to_e8(h.get("units")), to_e4(h.get("avg_cost")),
                 to_paise(h.get("invested")), to_e4(h.get("price")), to_paise(h.get("value")),
                 to_paise(h.get("pnl")), to_e4(h.get("pnl_pct")), to_e4(h.get("xirr")),
                 to_paise(h.get("day_change")), as_of, fetched_at))
            conn.execute(
                """INSERT INTO holding_history (instrument_id, broker, as_of, units_e8, avg_cost_e4,
                                                invested_paise, price_e4, value_paise, pnl_paise, xirr_e4)
                   VALUES (?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(instrument_id, broker, as_of) DO UPDATE SET
                     units_e8 = excluded.units_e8, avg_cost_e4 = excluded.avg_cost_e4,
                     invested_paise = excluded.invested_paise, price_e4 = excluded.price_e4,
                     value_paise = excluded.value_paise, pnl_paise = excluded.pnl_paise,
                     xirr_e4 = excluded.xirr_e4""",
                (h["id"], h.get("broker") or "", as_of, to_e8(h.get("units")), to_e4(h.get("avg_cost")),
                 to_paise(h.get("invested")), to_e4(h.get("price")), to_paise(h.get("value")),
                 to_paise(h.get("pnl")), to_e4(h.get("xirr"))))

        totals = snap.get("totals") or {}
        conn.execute(
            """INSERT INTO portfolio_totals (as_of, net_worth_paise, assets_paise, liabilities_paise,
                                             invested_paise, value_paise, pnl_paise, day_change_paise,
                                             xirr_e4, fetched_at)
               VALUES (?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(as_of) DO UPDATE SET
                 net_worth_paise = excluded.net_worth_paise, assets_paise = excluded.assets_paise,
                 liabilities_paise = excluded.liabilities_paise, invested_paise = excluded.invested_paise,
                 value_paise = excluded.value_paise, pnl_paise = excluded.pnl_paise,
                 day_change_paise = excluded.day_change_paise, xirr_e4 = excluded.xirr_e4,
                 fetched_at = excluded.fetched_at""",
            (as_of, to_paise(totals.get("net_worth")), to_paise(totals.get("assets")),
             to_paise(totals.get("liabilities")), to_paise(totals.get("invested")),
             to_paise(totals.get("value")), to_paise(totals.get("pnl")),
             to_paise(totals.get("day_change")), to_e4(totals.get("xirr")), fetched_at))

        conn.execute("DELETE FROM allocation_history WHERE as_of = ?", (as_of,))
        buckets = snap.get("allocation") or []
        # A share the buckets themselves determine is filled in rather
        # than stored as a hole for the widget to work out again.
        bucket_total = sum(b.get("value") or 0 for b in buckets)
        for bucket in buckets:
            pct = bucket.get("pct")
            if pct is None and bucket_total:
                pct = round((bucket.get("value") or 0) / bucket_total * 100, 2)
            conn.execute(
                "INSERT INTO allocation_history (as_of, bucket, value_paise, pct_e4) VALUES (?,?,?,?)",
                (as_of, bucket["bucket"], to_paise(bucket.get("value")), to_e4(pct)))

        for tool, payload in (snap.get("raw") or {}).items():
            conn.execute(
                """INSERT INTO indmoney_raw (tool, as_of, payload, fetched_at) VALUES (?,?,?,?)
                   ON CONFLICT(tool, as_of) DO UPDATE SET
                     payload = excluded.payload, fetched_at = excluded.fetched_at""",
                (tool, as_of, json.dumps(payload, ensure_ascii=False, separators=(",", ":")), fetched_at))

    return len(holdings)


def _upsert_instrument(conn: sqlite3.Connection, h: dict, ts: str) -> None:
    """Enrichment arrives later than the holding itself, so a field that
    came back empty never overwrites one already known."""
    conn.execute(
        """INSERT INTO instruments (id, kind, name, isin, symbol, category, amc, currency,
                                    ind_key, first_seen_at, last_seen_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET
             kind = excluded.kind,
             name = excluded.name,
             isin = COALESCE(excluded.isin, instruments.isin),
             symbol = COALESCE(excluded.symbol, instruments.symbol),
             category = COALESCE(excluded.category, instruments.category),
             amc = COALESCE(excluded.amc, instruments.amc),
             currency = excluded.currency,
             ind_key = COALESCE(excluded.ind_key, instruments.ind_key),
             last_seen_at = excluded.last_seen_at""",
        (h["id"], h.get("kind") or "other", h.get("name") or h["id"], h.get("isin") or None,
         h.get("symbol") or None, h.get("category") or None, h.get("amc") or None,
         h.get("currency") or "INR", h.get("ind_key") or None, ts, ts))


# --- working out the activity -----------------------------------------------

def derive_activity(conn: sqlite3.Connection) -> int:
    """Rebuild portfolio_activity from holding_history. Safe to repeat:
    every row's id is a hash of what it says, so a rerun rewrites the same
    rows rather than duplicating them. Returns how many rows there are.
    """
    # The snapshot calendar -- the days a fetch actually ran, taken from
    # portfolio_totals (written on every fetch, even one that found
    # nothing) as well as the holdings. A date missing from one
    # instrument's series is a date it was not held on: sold, not
    # skipped, because a fetch writes every holding it saw or fails.
    dates = [r[0] for r in conn.execute(
        """SELECT as_of FROM portfolio_totals
           UNION SELECT as_of FROM holding_history
           ORDER BY as_of""")]

    series: dict[tuple[str, str], dict[str, sqlite3.Row]] = {}
    for row in conn.execute(
            "SELECT * FROM holding_history ORDER BY instrument_id, broker, as_of"):
        series.setdefault((row["instrument_id"], row["broker"]), {})[row["as_of"]] = row

    events: list[dict] = []
    for (instrument_id, broker), by_date in series.items():
        previous = None
        for as_of in dates:
            row = by_date.get(as_of)
            if row is None:
                # Gone from this snapshot entirely. The server reports
                # zero units often enough, but a sold-out position is
                # usually just absent, and an exit nobody recorded would
                # leave the activity list ending mid-story.
                if previous is not None and (previous["units_e8"] or 0) >= UNIT_EPS:
                    events.append({
                        "instrument_id": instrument_id, "broker": broker, "date": as_of,
                        "kind": "exit", "units_e8": previous["units_e8"],
                        "price_e4": previous["price_e4"],
                        "amount_paise": _proceeds(previous),
                        "note": _join(_gap_note(previous["as_of"], as_of),
                                      "no longer in the portfolio"),
                    })
                # Reappearing later is a new position, not a top-up of
                # the units it used to have.
                previous = None
                continue
            event = _classify(previous, row)
            if event:
                event.update(instrument_id=instrument_id, broker=broker)
                events.append(event)
            previous = row

    _mark_sips(events)

    ts = now()
    with write(conn):
        for event in events:
            event["id"] = _activity_id(event)
            conn.execute(
                """INSERT INTO portfolio_activity (id, instrument_id, broker, date, kind, units_e8,
                                                   price_e4, amount_paise, inferred, note, first_seen_at)
                   VALUES (?,?,?,?,?,?,?,?,1,?,?)
                   ON CONFLICT(id) DO UPDATE SET
                     kind = excluded.kind, units_e8 = excluded.units_e8, price_e4 = excluded.price_e4,
                     amount_paise = excluded.amount_paise, note = excluded.note""",
                (event["id"], event["instrument_id"], event["broker"], event["date"],
                 event["kind"], event["units_e8"], event["price_e4"], event["amount_paise"],
                 event.get("note"), ts))
        keep = {e["id"] for e in events}
        for (row_id,) in conn.execute("SELECT id FROM portfolio_activity").fetchall():
            if row_id not in keep:
                conn.execute("DELETE FROM portfolio_activity WHERE id = ?", (row_id,))
    return len(events)


def _classify(previous: sqlite3.Row | None, row: sqlite3.Row) -> dict | None:
    """What must have happened between two snapshots of one holding.

    A value that moved while the units stood still is the market, not a
    trade, and produces nothing. Units that moved while the invested
    amount stood still is a bonus or a split, not a purchase -- calling it
    a buy would invent money that was never paid.
    """
    units = row["units_e8"] or 0
    price = row["price_e4"]
    if previous is None:
        return {"date": row["as_of"], "kind": "new", "units_e8": units,
                "price_e4": row["avg_cost_e4"] or price,
                "amount_paise": row["invested_paise"],
                "note": _gap_note(None, row["as_of"], "first seen")}

    before = previous["units_e8"] or 0
    delta = units - before
    if abs(delta) < UNIT_EPS:
        return None

    invested_delta = (row["invested_paise"] or 0) - (previous["invested_paise"] or 0)
    note = _gap_note(previous["as_of"], row["as_of"])

    if delta > 0:
        if abs(invested_delta) < 100:      # under a rupee: no money changed hands
            return {"date": row["as_of"], "kind": "corporate", "units_e8": delta,
                    "price_e4": 0, "amount_paise": 0,
                    "note": _join(note, "units changed with nothing invested - bonus or split")}
        # What was actually paid a unit, which is the money that moved
        # divided by the units it bought -- not the NAV, which is the
        # price at the moment of the snapshot, days later.
        implied = to_e4((invested_delta / 100) / (delta / 100000000))
        return {"date": row["as_of"], "kind": "buy", "units_e8": delta,
                "price_e4": implied or price, "amount_paise": invested_delta, "note": note}

    sold = -delta
    kind = "exit" if units < UNIT_EPS else "sell"
    return {"date": row["as_of"], "kind": kind, "units_e8": sold, "price_e4": price,
            "amount_paise": _proceeds(row, sold) if price else abs(invested_delta),
            "note": note}


def _proceeds(row: sqlite3.Row, units_e8: int | None = None) -> int:
    """What a sale brought in: the units times the price. A sale leaves no
    trace in the invested amount beyond the cost basis it removes, so the
    cost basis cannot stand in for it."""
    units = units_e8 if units_e8 is not None else (row["units_e8"] or 0)
    price = row["price_e4"] or 0
    return round(units / 100000000 * price / 100)


def _gap_note(previous_date: str | None, as_of: str, prefix: str = "") -> str:
    """A snapshot every day makes a date exact. A gap makes it a window,
    and the row should admit that rather than pick a day."""
    parts = [prefix] if prefix else []
    if previous_date and _days_between(previous_date, as_of) > 1:
        parts.append(f"some time after {previous_date}")
    return " - ".join(parts)


def _join(*parts: str) -> str:
    return " - ".join(p for p in parts if p)


def _days_between(start: str, end: str) -> int:
    try:
        return (date.fromisoformat(end) - date.fromisoformat(start)).days
    except ValueError:
        return 0


def _mark_sips(events: list[dict]) -> None:
    """A buy is an instalment when the same instrument has another buy of
    nearly the same size about a month away. One repeat is enough: two
    identical ₹5,000 purchases 30 days apart are a SIP, and calling them
    that is what makes "₹15,000 invested this month" readable."""
    by_instrument: dict[str, list[dict]] = {}
    for event in events:
        if event["kind"] == "buy" and event["amount_paise"]:
            by_instrument.setdefault(event["instrument_id"], []).append(event)

    for buys in by_instrument.values():
        for event in buys:
            for other in buys:
                if other is event:
                    continue
                gap = abs(_days_between(other["date"], event["date"]))
                if not SIP_MIN_GAP_DAYS <= gap <= SIP_MAX_GAP_DAYS:
                    continue
                bigger = max(abs(event["amount_paise"]), abs(other["amount_paise"]))
                if bigger and abs(event["amount_paise"] - other["amount_paise"]) / bigger <= SIP_TOLERANCE:
                    event["kind"] = "sip"
                    break


def _activity_id(event: dict) -> str:
    key = "|".join(str(event[k]) for k in ("instrument_id", "broker", "date", "kind", "units_e8"))
    return "ind-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]


# --- checking ----------------------------------------------------------------

def reconcile(conn: sqlite3.Connection) -> list[dict]:
    """Two arithmetic claims the data makes about itself: a holding's
    units times its price is its value, and the holdings add up to the
    total. Same contract as queries.reconcile -- an empty list means it
    all adds up."""
    problems: list[dict] = []
    for row in conn.execute(
            """SELECT h.*, i.name FROM holdings h JOIN instruments i ON i.id = h.instrument_id"""):
        if not row["units_e8"] or not row["price_e4"] or row["value_paise"] is None:
            continue
        expected = (row["units_e8"] / 100000000) * (row["price_e4"] / 10000)
        found = from_paise(row["value_paise"])
        if abs(expected - found) > max(1.0, abs(found) * 0.01):
            problems.append({"kind": "holding", "instrument": row["name"], "broker": row["broker"],
                             "expected": round(expected, 2), "found": found,
                             "off_by": round(found - expected, 2)})

    row = conn.execute("SELECT as_of, value_paise FROM portfolio_totals ORDER BY as_of DESC LIMIT 1").fetchone()
    if row and row["value_paise"]:
        total = conn.execute("SELECT COALESCE(SUM(value_paise), 0) FROM holdings").fetchone()[0]
        expected, found = from_paise(total), from_paise(row["value_paise"])
        if abs(expected - found) > max(1.0, abs(found) * 0.01):
            problems.append({"kind": "total", "as_of": row["as_of"], "expected": expected,
                             "found": found, "off_by": round(found - expected, 2)})
    return problems


def reconcile_summary(conn: sqlite3.Connection) -> str:
    problems = reconcile(conn)
    if not problems:
        return ""
    first = problems[0]
    what = first.get("instrument") or f"the {first['as_of']} total"
    return (f"{len(problems)} portfolio mismatches: {what} (off by {first['off_by']:+.2f})"
            if len(problems) > 1 else f"portfolio mismatch: {what} (off by {first['off_by']:+.2f})")


# --- reading ------------------------------------------------------------------

def snapshot(conn: sqlite3.Connection) -> dict:
    """The five keys the widget's PORTFOLIO tab reads. Shapes follow the
    bank side's conventions: camelCase, rupee floats, nulls flattened to
    "" for anything a QML string interpolates."""
    totals = conn.execute(
        "SELECT * FROM portfolio_totals ORDER BY as_of DESC LIMIT 1").fetchone()
    last_run = conn.execute(
        "SELECT * FROM fetch_runs WHERE bank = 'INDMONEY' ORDER BY id DESC LIMIT 1").fetchone()

    rows = conn.execute(
        """SELECT h.*, i.kind, i.name, i.isin, i.symbol, i.category, i.amc, i.currency
           FROM holdings h JOIN instruments i ON i.id = h.instrument_id
           ORDER BY h.value_paise DESC""").fetchall()
    total_value = sum(r["value_paise"] or 0 for r in rows)
    first_held = {(r["instrument_id"], r["broker"]): r["as_of"] for r in conn.execute(
        """SELECT instrument_id, broker, MIN(as_of) AS as_of FROM holding_history
           GROUP BY instrument_id, broker""")}

    holdings = [{
        "instrumentId": r["instrument_id"], "kind": r["kind"], "name": r["name"],
        "symbol": r["symbol"] or "", "isin": r["isin"] or "", "category": r["category"] or "",
        "amc": r["amc"] or "", "broker": r["broker"] or "", "currency": r["currency"],
        "units": from_e8(r["units_e8"]), "avgCost": from_e4(r["avg_cost_e4"]),
        "invested": from_paise(r["invested_paise"]), "price": from_e4(r["price_e4"]),
        "value": from_paise(r["value_paise"]), "pnl": from_paise(r["pnl_paise"]),
        "pnlPct": from_e4(r["pnl_pct_e4"]), "xirr": from_e4(r["xirr_e4"]),
        "dayChange": from_paise(r["day_change_paise"]),
        "weight": round((r["value_paise"] or 0) / total_value * 100, 2) if total_value else 0.0,
        "firstHeld": first_held.get((r["instrument_id"], r["broker"]), r["as_of"]),
        "asOf": r["as_of"],
    } for r in rows]

    activity = [{
        "id": r["id"], "date": r["date"], "instrumentId": r["instrument_id"], "name": r["name"],
        "kind": r["kind"], "broker": r["broker"] or "", "units": from_e8(r["units_e8"]),
        "price": from_e4(r["price_e4"]), "amount": from_paise(r["amount_paise"]),
        "inferred": bool(r["inferred"]), "note": r["note"] or "", "tracked": bool(r["tracked"]),
    } for r in conn.execute(
        """SELECT a.*, i.name, (k.transaction_id IS NOT NULL) AS tracked
           FROM portfolio_activity a JOIN instruments i ON i.id = a.instrument_id
           LEFT JOIN tracked k ON k.transaction_id = a.id
           ORDER BY a.date DESC, a.id""")]

    history = [{
        "asOf": r["as_of"], "value": from_paise(r["value_paise"]),
        "invested": from_paise(r["invested_paise"]),
    } for r in conn.execute(
        """SELECT as_of, SUM(value_paise) AS value_paise, SUM(invested_paise) AS invested_paise
           FROM holding_history GROUP BY as_of ORDER BY as_of DESC LIMIT ?""", (HISTORY_POINTS,))][::-1]

    allocation = [{
        "bucket": r["bucket"], "value": from_paise(r["value_paise"]), "pct": from_e4(r["pct_e4"]),
    } for r in conn.execute(
        """SELECT * FROM allocation_history WHERE as_of = (SELECT MAX(as_of) FROM allocation_history)
           ORDER BY value_paise DESC""")]

    return {
        "portfolio": _totals_payload(totals, last_run),
        "holdings": holdings,
        "allocation": allocation,
        "portfolioActivity": activity,
        "portfolioHistory": history,
    }


def _totals_payload(totals: sqlite3.Row | None, last_run: sqlite3.Row | None) -> dict:
    if totals is None:
        return {"asOf": "", "stale": True, "lastFetch": "", "lastOutcome": "",
                "lastMessage": "", "netWorth": None}
    value = from_paise(totals["value_paise"])
    invested = from_paise(totals["invested_paise"])
    pnl = from_paise(totals["pnl_paise"])
    if pnl is None and value is not None and invested is not None:
        pnl = round(value - invested, 2)
    day_change = from_paise(totals["day_change_paise"])
    return {
        "asOf": totals["as_of"], "netWorth": from_paise(totals["net_worth_paise"]),
        "assets": from_paise(totals["assets_paise"]),
        "liabilities": from_paise(totals["liabilities_paise"]),
        "invested": invested, "value": value, "pnl": pnl,
        "pnlPct": round(pnl / invested * 100, 2) if pnl is not None and invested else None,
        "dayChange": day_change,
        "dayChangePct": round(day_change / (value - day_change) * 100, 2)
                        if day_change is not None and value and (value - day_change) else None,
        "xirr": from_e4(totals["xirr_e4"]),
        "fetchedAt": totals["fetched_at"],
        "lastFetch": (last_run["finished_at"] or last_run["started_at"]) if last_run else "",
        "lastOutcome": (last_run["outcome"] or "") if last_run else "",
        "lastMessage": (last_run["message"] or "") if last_run else "",
        "stale": _is_stale(totals["as_of"]),
    }


def _is_stale(as_of: str) -> bool:
    """Older than a day is stale. The widget says how old rather than
    hiding it: a wrong number that looks current is the failure worth
    avoiding."""
    try:
        return (datetime.now().date() - date.fromisoformat(as_of)).days >= 1
    except ValueError:
        return True
