"""Tests for the investments half of the database (stdlib unittest):
  python3 -m unittest discover -s tests

The activity rows are worked out, not read, so most of what is checked
here is the arithmetic that works them out: what counts as a buy, what is
only the market moving, and what is a bonus rather than a purchase."""
import tempfile
import unittest
import unittest.mock
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import db, portfolio, queries  # noqa: E402


def holding(instrument="MF|INF001", units=100.0, price=100.0, invested=9000.0, **extra):
    base = {
        "id": instrument, "kind": "mf", "name": "Test Flexi Cap", "isin": instrument.split("|")[-1],
        "broker": "", "units": units, "price": price, "invested": invested,
        "value": round(units * price, 2), "avg_cost": round(invested / units, 4) if units else None,
    }
    base.update(extra)
    return base


def snap(as_of, holdings, **totals):
    value = round(sum(h["value"] for h in holdings), 2)
    invested = round(sum(h["invested"] for h in holdings), 2)
    return {
        "as_of": as_of,
        "fetched_at": f"{as_of}T18:00:00",
        "totals": {"net_worth": value, "assets": value, "liabilities": 0.0,
                   "invested": invested, "value": value, "pnl": round(value - invested, 2),
                   **totals},
        "allocation": [{"bucket": "Mutual funds", "value": value, "pct": 100.0}],
        "holdings": holdings,
    }


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def kinds(self):
        return [(r["date"], r["kind"], r["units_e8"], r["amount_paise"]) for r in self.conn.execute(
            "SELECT * FROM portfolio_activity ORDER BY date, id")]


class RecordTests(Base):
    def test_saves_holdings_totals_and_history(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        out = portfolio.snapshot(self.conn)
        self.assertEqual(len(out["holdings"]), 1)
        self.assertEqual(out["holdings"][0]["units"], 100.0)
        self.assertEqual(out["holdings"][0]["value"], 10000.0)
        self.assertEqual(out["holdings"][0]["weight"], 100.0)
        self.assertEqual(out["portfolio"]["value"], 10000.0)
        self.assertEqual(out["portfolio"]["pnl"], 1000.0)
        self.assertEqual(out["portfolioHistory"], [{"asOf": "2026-10-20", "value": 10000.0, "invested": 9000.0}])
        self.assertEqual(out["allocation"][0]["bucket"], "Mutual funds")

    def test_rerunning_the_same_day_replaces_rather_than_doubles(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding(price=110.0)]))
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM holding_history").fetchone()[0], 1)
        self.assertEqual(portfolio.snapshot(self.conn)["holdings"][0]["price"], 110.0)

    def test_a_share_the_buckets_determine_is_filled_in_not_left_null(self):
        payload = snap("2026-10-20", [holding()])
        payload["allocation"] = [{"bucket": "Mutual funds", "value": 7500.0},
                                 {"bucket": "Stocks", "value": 2500.0}]
        portfolio.record_snapshot(self.conn, payload)
        self.assertEqual([(a["bucket"], a["pct"]) for a in portfolio.snapshot(self.conn)["allocation"]],
                         [("Mutual funds", 75.0), ("Stocks", 25.0)])

    def test_a_holding_that_is_gone_leaves_its_history_behind(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(instrument="MF|INF002")]))
        self.assertEqual([h["instrumentId"] for h in portfolio.snapshot(self.conn)["holdings"]], ["MF|INF002"])
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM holding_history").fetchone()[0], 2)

    def test_enrichment_never_blanks_a_field_it_did_not_fill(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding(category="Flexi Cap", amc="PPFAS")]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding()]))  # no category this time
        row = self.conn.execute("SELECT category, amc FROM instruments").fetchone()
        self.assertEqual((row["category"], row["amc"]), ("Flexi Cap", "PPFAS"))

    def test_the_raw_payload_is_kept_verbatim(self):
        payload = snap("2026-10-20", [holding()])
        payload["raw"] = {"networth_holdings": {"anything": [1, 2, 3]}}
        portfolio.record_snapshot(self.conn, payload)
        stored = self.conn.execute("SELECT payload FROM indmoney_raw").fetchone()[0]
        self.assertIn('"anything"', stored)


class DeriveTests(Base):
    def test_first_snapshot_is_a_new_position(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.derive_activity(self.conn)
        self.assertEqual(self.kinds(), [("2026-10-20", "new", 10000000000, 900000)])

    def test_price_moving_alone_is_not_a_trade(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(price=140.0)]))
        portfolio.derive_activity(self.conn)
        self.assertEqual([k for _, k, _, _ in self.kinds()], ["new"])

    def test_units_up_with_money_in_is_a_buy_at_the_implied_price(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(units=150.0, invested=14000.0)]))
        portfolio.derive_activity(self.conn)
        row = self.conn.execute("SELECT * FROM portfolio_activity WHERE kind = 'buy'").fetchone()
        self.assertEqual(row["units_e8"], 5000000000)     # 50 units
        self.assertEqual(row["amount_paise"], 500000)      # ₹5,000 went in
        self.assertEqual(row["price_e4"], 1000000)         # ₹100 a unit, not the ₹100 NAV by luck
        self.assertEqual(row["inferred"], 1)

    def test_units_up_with_no_money_in_is_a_bonus_not_a_buy(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(units=200.0, price=50.0)]))
        portfolio.derive_activity(self.conn)
        row = self.conn.execute("SELECT * FROM portfolio_activity WHERE date = '2026-10-21'").fetchone()
        self.assertEqual(row["kind"], "corporate")
        self.assertEqual(row["amount_paise"], 0)

    def test_units_down_is_a_sell_and_to_zero_is_an_exit(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(units=60.0, invested=5400.0)]))
        portfolio.record_snapshot(self.conn, snap("2026-10-22", [holding(units=0.0, invested=0.0)]))
        portfolio.derive_activity(self.conn)
        self.assertEqual([k for _, k, _, _ in self.kinds()], ["new", "sell", "exit"])
        sale = self.conn.execute("SELECT * FROM portfolio_activity WHERE kind = 'sell'").fetchone()
        self.assertEqual(sale["units_e8"], 4000000000)  # 40 units sold
        self.assertEqual(sale["amount_paise"], 400000)  # at ₹100 each, ₹4,000 came back

    def test_a_holding_that_vanishes_was_sold(self):
        """The server drops a sold-out position rather than reporting zero
        units, so an absent instrument has to end its own story."""
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [
            holding(), holding(instrument="MF|INF002", units=50.0, price=200.0, invested=9000.0)]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding()]))
        portfolio.derive_activity(self.conn)
        gone = self.conn.execute(
            "SELECT * FROM portfolio_activity WHERE instrument_id = 'MF|INF002'"
            " ORDER BY date DESC").fetchone()
        self.assertEqual(gone["kind"], "exit")
        self.assertEqual(gone["date"], "2026-10-21")
        self.assertEqual(gone["units_e8"], 5000000000)      # the 50 units it held
        self.assertEqual(gone["amount_paise"], 1000000)     # at ₹200, ₹10,000 back
        self.assertIn("no longer in the portfolio", gone["note"])

    def test_buying_back_in_later_is_a_new_position_not_a_top_up(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding(units=100.0)]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", []))
        portfolio.record_snapshot(self.conn, snap("2026-10-22", [holding(units=30.0, invested=3000.0)]))
        portfolio.derive_activity(self.conn)
        self.assertEqual([k for _, k, _, _ in self.kinds()], ["new", "exit", "new"])

    def test_monthly_buys_of_the_same_size_are_a_sip(self):
        portfolio.record_snapshot(self.conn, snap("2026-08-05", [holding(units=50.0, invested=5000.0)]))
        portfolio.record_snapshot(self.conn, snap("2026-09-05", [holding(units=100.0, invested=10000.0)]))
        portfolio.record_snapshot(self.conn, snap("2026-10-05", [holding(units=150.0, invested=15000.0)]))
        portfolio.derive_activity(self.conn)
        self.assertEqual([k for _, k, _, _ in self.kinds()], ["new", "sip", "sip"])

    def test_one_off_purchases_stay_buys(self):
        portfolio.record_snapshot(self.conn, snap("2026-09-05", [holding(units=50.0, invested=5000.0)]))
        portfolio.record_snapshot(self.conn, snap("2026-10-05", [holding(units=100.0, invested=31000.0)]))
        portfolio.derive_activity(self.conn)
        self.assertEqual([k for _, k, _, _ in self.kinds()], ["new", "buy"])

    def test_a_gap_between_snapshots_is_admitted_in_the_note(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-01", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-09", [holding(units=150.0, invested=14000.0)]))
        portfolio.derive_activity(self.conn)
        note = self.conn.execute("SELECT note FROM portfolio_activity WHERE kind = 'buy'").fetchone()[0]
        self.assertIn("after 2026-10-01", note)

    def test_deriving_twice_changes_nothing(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(units=150.0, invested=14000.0)]))
        first = portfolio.derive_activity(self.conn)
        before = self.kinds()
        self.assertEqual(portfolio.derive_activity(self.conn), first)
        self.assertEqual(self.kinds(), before)

    def test_a_correcting_snapshot_removes_the_activity_it_invented(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding(units=150.0, invested=14000.0)]))
        portfolio.derive_activity(self.conn)
        self.assertEqual(len(self.kinds()), 2)
        portfolio.record_snapshot(self.conn, snap("2026-10-21", [holding()]))  # the feed was wrong
        portfolio.derive_activity(self.conn)
        self.assertEqual([k for _, k, _, _ in self.kinds()], ["new"])


class ReconcileTests(Base):
    def test_clean_data_reconciles(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        self.assertEqual(portfolio.reconcile(self.conn), [])
        self.assertEqual(portfolio.reconcile_summary(self.conn), "")

    def test_units_times_price_not_matching_value_is_reported(self):
        payload = snap("2026-10-20", [holding()])
        payload["holdings"][0]["value"] = 12000.0      # 100 x 100 is not 12,000
        payload["totals"]["value"] = 12000.0
        portfolio.record_snapshot(self.conn, payload)
        problems = portfolio.reconcile(self.conn)
        self.assertEqual([p["kind"] for p in problems], ["holding"])
        self.assertEqual(problems[0]["off_by"], 2000.0)
        self.assertIn("off by +2000.00", portfolio.reconcile_summary(self.conn))

    def test_holdings_not_adding_up_to_the_total_is_reported(self):
        payload = snap("2026-10-20", [holding()])
        payload["totals"]["value"] = 50000.0
        portfolio.record_snapshot(self.conn, payload)
        self.assertEqual([p["kind"] for p in portfolio.reconcile(self.conn)], ["total"])


class SnapshotTests(Base):
    def test_the_widget_snapshot_carries_both_halves(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        out = queries.snapshot(self.conn)
        for key in ("transactions", "balances", "portfolio", "holdings",
                    "allocation", "portfolioActivity", "portfolioHistory"):
            self.assertIn(key, out)

    def test_an_empty_portfolio_still_answers(self):
        out = queries.snapshot(self.conn)
        self.assertEqual(out["holdings"], [])
        self.assertTrue(out["portfolio"]["stale"])
        self.assertIsNone(out["portfolio"]["netWorth"])

    def test_activity_can_be_marked_tracked_through_the_existing_table(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [holding()]))
        portfolio.derive_activity(self.conn)
        row_id = self.conn.execute("SELECT id FROM portfolio_activity").fetchone()[0]
        with db.write(self.conn):
            self.conn.execute("INSERT INTO tracked VALUES (?, '2026-10-20T10:00:00')", (row_id,))
        self.assertTrue(queries.snapshot(self.conn)["portfolioActivity"][0]["tracked"])

    def test_weights_are_shares_of_the_whole(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [
            holding(units=100.0, price=100.0),
            holding(instrument="EQ|NSE|TEST", units=100.0, price=300.0, kind="equity"),
        ]))
        weights = {h["instrumentId"]: h["weight"] for h in portfolio.snapshot(self.conn)["holdings"]}
        self.assertEqual(weights, {"EQ|NSE|TEST": 75.0, "MF|INF001": 25.0})


class MigrationTests(unittest.TestCase):
    """The database is live on this machine, so v8 has to land on an
    existing v7 file rather than a fresh one."""

    def test_v8_adds_the_portfolio_tables_to_a_v7_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.db"
            with unittest.mock.patch.object(db, "MIGRATIONS", db.MIGRATIONS[:7]):
                conn = db.connect(path)
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 7)
                with db.write(conn):
                    conn.execute("INSERT INTO accounts (id, bank, account_type, last4, created_at) "
                                 "VALUES ('HDFC|checking|7367', 'HDFC', 'checking', '7367', '2026-10-01')")
                conn.close()

            conn = db.connect(path)  # reopening runs v8
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], len(db.MIGRATIONS))
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0], 1)
            for table in ("instruments", "holdings", "holding_history", "portfolio_totals",
                          "allocation_history", "portfolio_activity", "indmoney_raw"):
                self.assertEqual(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], 0)
            portfolio.record_snapshot(conn, snap("2026-10-20", [holding()]))
            self.assertEqual(len(portfolio.snapshot(conn)["holdings"]), 1)
            conn.close()


class PrecisionTests(Base):
    """Migration v9. A fractional US share is quoted to seven decimals,
    and the four the schema started with rounded enough away to make the
    holding's own units-times-price check fail."""

    def test_seven_decimal_units_survive_the_round_trip(self):
        portfolio.record_snapshot(self.conn, snap("2026-10-20", [
            holding(units=0.0081521, price=120310.6215, invested=900.0)]))
        self.assertEqual(portfolio.snapshot(self.conn)["holdings"][0]["units"], 0.0081521)

    def test_a_fractional_share_reconciles(self):
        payload = snap("2026-10-20", [holding(units=0.0081521, price=120310.6215, invested=900.0)])
        portfolio.record_snapshot(self.conn, payload)
        self.assertEqual(portfolio.reconcile(self.conn), [])

    def test_v9_rescales_the_units_an_existing_v8_database_holds(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.db"
            with unittest.mock.patch.object(db, "MIGRATIONS", db.MIGRATIONS[:8]):
                conn = db.connect(path)
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 8)
                with db.write(conn):
                    conn.execute("INSERT INTO instruments (id, kind, name, currency, first_seen_at,"
                                 " last_seen_at) VALUES ('MF|1','mf','Old','INR','x','x')")
                    conn.execute("INSERT INTO holdings (instrument_id, broker, units_e4, as_of,"
                                 " fetched_at) VALUES ('MF|1','',1234567,'2026-10-20','x')")
                conn.close()

            conn = db.connect(path)  # reopening runs v9
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 9)
            # 123.4567 units before, the same 123.4567 units after.
            self.assertEqual(conn.execute("SELECT units_e8 FROM holdings").fetchone()[0], 12345670000)
            self.assertEqual(conn.execute("SELECT units FROM portfolio_view").fetchone()[0], 123.4567)
            conn.close()


if __name__ == "__main__":
    unittest.main()
