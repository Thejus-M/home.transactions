"""Tests for the Cashew category guesser, against a fake Ollama (no real model)."""
import json
import os
import signal
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import cashew_guess as g  # noqa: E402

CATS = g.cashew.load_categories()


def rows(n, amount="-100.00"):
    return [{"id": f"r{i}", "title": f"Shop {i}", "merchant": f"SHOP{i}", "notes": "", "amount": amount,
             "kind": "spend", "bank": "HDFC", "accountType": "checking"} for i in range(n)]


class Fake:
    """A tiny /api/generate. `replies` is a list of response strings used in order
    (the last one repeats); a callable gets the prompt."""

    def __init__(self, replies, delay=0.0):
        self.replies, self.delay, self.prompts, self.calls = replies, delay, [], 0
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"models":[]}')

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                with outer.lock:
                    outer.prompts.append(body["prompt"])
                    k = outer.calls
                    outer.calls += 1
                time.sleep(outer.delay)
                r = outer.replies
                text = r(body["prompt"]) if callable(r) else r[min(k, len(r) - 1)]
                out = json.dumps({"response": text}).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(out)

        self.lock = threading.Lock()
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_port}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def reply(*items):
    return json.dumps({"results": [{"i": i, "category": c, "subcategory": s} for i, c, s in items]})


def cli(payload, *args, url=None, timeout=60):
    cmd = [sys.executable, str(ROOT / "bin" / "txdb"), "cashew-guess", "-", "--url", url, *args]
    p = subprocess.run(cmd, input=json.dumps(payload), capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, "TXDB_NO_RUN_LOG": "1"})
    lines = [json.loads(x) for x in p.stdout.splitlines() if x.strip()]
    lines = [m for m in lines if "progress" not in m]   # live progress lines are tested on their own
    return p, lines


class Validate(unittest.TestCase):
    def v(self, amount, cat, sub):
        return g.validate({"amount": amount}, cat, sub, CATS)

    def test_ok(self):
        self.assertEqual(self.v("-5.00", "Food Out", "Lunch"), ("Food Out", "Lunch"))

    def test_unknown_category(self):
        self.assertEqual(self.v("-5.00", "Pizza", "Lunch"), ("", ""))

    def test_wrong_sign(self):
        self.assertEqual(self.v("-5.00", "Salary", "Monthly"), ("", ""))
        self.assertEqual(self.v("5.00", "Food Out", "Lunch"), ("", ""))

    def test_bad_subcategory_only_dropped(self):
        self.assertEqual(self.v("-5.00", "Food Out", "Monthly"), ("Food Out", ""))

    def test_friend_settlement_both_ways(self):
        self.assertEqual(self.v("-5.00", "Friend Settlement", "Split Paid"), ("Friend Settlement", "Split Paid"))
        self.assertEqual(self.v("5.00", "Friend Settlement", "Lent"), ("Friend Settlement", "Split Paid"))

    def test_uncategorized_is_no_guess(self):
        self.assertEqual(self.v("-5.00", "Uncategorized", "Unknown"), ("", ""))

    def test_extract_json_tolerant(self):
        self.assertEqual(g.extract_json('sure: ```{"a":1}```'), {"a": 1})
        self.assertEqual(g.extract_json("nope"), {})


class StatePassThrough(unittest.TestCase):
    def test_guess_prefs_survive_load_state(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "s.json"
            f.write_text(json.dumps({"version": 1, "guess": {"workers": 2, "onlyUncategorized": False}}))
            st = g.cashew.load_state(f)
        self.assertEqual(st["guess"], {"workers": 2, "onlyUncategorized": False})


class Prompt(unittest.TestCase):
    def test_prompt_has_everything(self):
        r = [{"id": "x", "title": "Zomato", "merchant": "UPI-ZOMATO-9", "notes": "dinner", "amount": "-250.00",
              "bank": "HDFC", "accountType": "checking"}]
        p = g.build_prompt(r, CATS, {"Zomato": {"category": "Food Out", "subcategory": "Delivery"}})
        for s in ("Food Out: Breakfast", "UPI-ZOMATO-9", "dinner", "DEBIT 250.00", "HDFC checking",
                  '"Zomato" -> Food Out / Delivery', "Friend Settlement", "Uncategorized"):
            self.assertIn(s, p)
        debit_part = p.split("Money in")[0]
        self.assertNotIn("Salary", debit_part)

    def test_taught_max_20(self):
        t = {f"k{i}": {"category": "Food Out", "subcategory": ""} for i in range(30)}
        self.assertEqual(len(g.taught_lines(t).splitlines()), 20)


class Cli(unittest.TestCase):
    def test_batches_ndjson_and_validation(self):
        reps = lambda p: reply((1, "Food Out", "Lunch"), (2, "Pizza", "x"), (3, "Salary", ""))
        fk = Fake(reps)
        self.addCleanup(fk.close)
        p, lines = cli({"rows": rows(5)}, "--batch", "3", "--workers", "1", url=fk.url)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(fk.calls, 2)
        res = [x for x in lines if "results" in x]
        self.assertEqual([x["done"] for x in res], [3, 5])
        self.assertTrue(all(x["total"] == 5 for x in res))
        first = res[0]["results"]
        self.assertEqual(first[0], {"id": "r0", "category": "Food Out", "subcategory": "Lunch"})
        self.assertEqual(first[1]["category"], "")
        self.assertEqual(first[2]["category"], "")
        # the second batch has 2 rows: row 3 of the canned reply is not used
        self.assertEqual(len(res[1]["results"]), 2)
        fin = lines[-1]
        self.assertTrue(fin["finished"])
        self.assertEqual((fin["done"], fin["total"], fin["model"]), (5, 5, "gemma4:e2b"))
        self.assertIn("seconds", fin)

    def test_parallel_is_faster(self):
        fk = Fake([reply((1, "Food Out", "Lunch"))], delay=0.5)
        self.addCleanup(fk.close)
        t = time.monotonic()
        p, lines = cli({"rows": rows(3)}, "--batch", "1", "--workers", "3", url=fk.url)
        # interpreter start is not part of the claim: use the reported seconds
        self.assertLess(lines[-1]["seconds"], 1.2)
        self.assertEqual(fk.calls, 3)
        t = time.monotonic()
        p, lines = cli({"rows": rows(3)}, "--batch", "1", "--workers", "1", url=fk.url)
        self.assertGreater(lines[-1]["seconds"], 1.4)

    def test_retry_on_malformed_reply(self):
        fk = Fake(["this is not json", reply((1, "Food Out", "Dinner"))])
        self.addCleanup(fk.close)
        p, lines = cli({"rows": rows(1)}, url=fk.url)
        self.assertEqual(fk.calls, 2)
        self.assertEqual(lines[0]["results"][0]["subcategory"], "Dinner")
        self.assertFalse(any("error" in x for x in lines))

    def test_two_failures_give_error_and_no_guess(self):
        fk = Fake(["junk"])
        self.addCleanup(fk.close)
        p, lines = cli({"rows": rows(2)}, url=fk.url)
        self.assertEqual(p.returncode, 0)
        self.assertTrue(any("error" in x for x in lines))
        res = [x for x in lines if "results" in x][0]
        self.assertEqual([r["category"] for r in res["results"]], ["", ""])
        self.assertEqual(lines[-1]["done"], 2)

    def test_ollama_down(self):
        p, lines = cli({"rows": rows(2)}, url="http://127.0.0.1:9")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(lines, [{"error": "Ollama is not reachable at http://127.0.0.1:9"}])

    def test_invalid_input_exits_2(self):
        p = subprocess.run([sys.executable, str(ROOT / "bin" / "txdb"), "cashew-guess", "-"],
                           input="not json", capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)

    def test_sigterm_exits_fast(self):
        fk = Fake([reply((1, "Food Out", "Lunch"))], delay=5)
        self.addCleanup(fk.close)
        proc = subprocess.Popen([sys.executable, str(ROOT / "bin" / "txdb"), "cashew-guess", "-", "--url", fk.url],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        proc.stdin.write(json.dumps({"rows": rows(4)}))
        proc.stdin.close()
        time.sleep(1.0)
        t = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=3)
        self.assertLess(time.monotonic() - t, 1.5)


if __name__ == "__main__":
    unittest.main()


class NotesInPrompt(unittest.TestCase):
    def test_every_note_reaches_the_prompt(self):
        rows = [{"id": str(i), "title": "T", "merchant": "M", "notes": f"remark number {i}", "amount": "-5.00"} for i in range(3)]
        p = g.build_prompt(rows, [{"name": "Food Out", "type": "expense", "subcategories": []}])
        for i in range(3):
            self.assertIn(f'notes: "remark number {i}"', p)


class StreamingTests(unittest.TestCase):
    def test_empty_reply_at_the_token_budget_is_split_not_repeated(self):
        from txdb import cashew_guess as cg
        calls = []

        def fake_generate(url, model, prompt, timeout, num_predict=cg.DEFAULT_NUM_PREDICT, on_progress=None):
            calls.append((prompt.count("\n- ") , num_predict))
            if num_predict == cg.DEFAULT_NUM_PREDICT:
                raise cg.Capped("capped")
            return reply((1, "Food Out", "Lunch"))

        orig = cg.generate
        cg.generate = fake_generate
        try:
            out = cg.guess_batch(rows(2), __import__("txdb.cashew", fromlist=["x"]).load_categories(), {}, "http://x", "m", 5)
        finally:
            cg.generate = orig
        self.assertEqual([c[1] for c in calls], [cg.DEFAULT_NUM_PREDICT, cg.CAPPED_NUM_PREDICT, cg.CAPPED_NUM_PREDICT])
        self.assertEqual(len(out), 2)


class WhatTheModelIsToldAboutARow(unittest.TestCase):
    """The prompt carries the UPI remark, the owner's note and the linked bill (with the meal)."""

    def setUp(self):
        import tempfile
        from txdb import db, ingest
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.conn = db.connect(self.path)
        aid = ingest.ensure_account(self.conn, "HDFC", "credit", "0220")
        ingest.upsert_rows(self.conn, aid, [{"id": "t1", "date": "2026-11-05", "merchant": "UPI-CAKE WORLD-x@ybl-ICIC0-1-Birthday cake",
                                             "amount": -149.0, "seq": 1, "status": "settled"}])
        self.tid = self.conn.execute("SELECT id FROM transactions").fetchone()[0]
        self.conn.execute("INSERT INTO txn_notes (transaction_id, note, updated_at) VALUES (?, 'for Anu', 'now')", (self.tid,))
        self.conn.execute("INSERT INTO receipts (id, image_sha256, stored_path, merchant, time, total_paise, parsed_at, imported_at) "
                          "VALUES ('rcpt-1', 'sha', 'p', 'CAKE WORLD', '15:09:26', 14900, 'now', 'now')")
        self.conn.execute("INSERT INTO receipt_items (receipt_id, line_no, description) VALUES ('rcpt-1', 1, 'MILK BROWNIE BOX')")
        self.conn.execute("INSERT INTO receipt_links (receipt_id, transaction_id, state, linked_at) VALUES ('rcpt-1', ?, 'linked', 'now')", (self.tid,))
        self.conn.execute("INSERT INTO receipt_categories (receipt_id, category, subcategory, source, updated_at) "
                          "VALUES ('rcpt-1', 'Food Out', 'Lunch', 'user', 'now')")
        self.conn.commit()

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def test_the_meal_follows_the_time_of_day(self):
        for clock, meal in (("06:00", "breakfast"), ("10:45", "brunch"), ("13:10", "lunch"), ("16:40", "evening snack"),
                            ("20:15", "dinner"), ("01:30", "late night"), ("15:09:26", "lunch")):
            self.assertEqual(g.meal_period(clock), meal, clock)
        self.assertEqual(g.meal_period(""), "")
        self.assertEqual(g.meal_period("soon"), "")

    def test_enrich_adds_the_remark_the_note_and_the_bill(self):
        row = {"id": self.tid, "amount": "-149.00", "title": "Cake World", "merchant": "m", "notes": "glued", "bank": "HDFC",
               "accountType": "credit"}
        out = g.enrich([row], self.path)[0]
        self.assertEqual(out["userNote"], "for Anu")
        self.assertEqual(out["bill"]["merchant"], "CAKE WORLD")
        self.assertEqual(out["bill"]["items"], ["MILK BROWNIE BOX"])
        self.assertEqual(out["bill"]["categoryChosen"], "Food Out / Lunch")
        line = g.row_line(1, out)
        self.assertIn('my note: "for Anu"', line)
        self.assertIn("made at 3:09 PM (lunch time)", line)
        self.assertIn("items: MILK BROWNIE BOX", line)
        self.assertIn('bill category I chose: "Food Out / Lunch"', line)
        self.assertNotIn("glued", line)        # the glued `notes` would only repeat these facts

    def test_a_row_with_no_extra_facts_keeps_its_notes_and_a_missing_database_changes_nothing(self):
        plain = {"id": "nope", "amount": "-10", "title": "x", "merchant": "m", "notes": "just notes", "bank": "SBI",
                 "accountType": "checking"}
        self.assertEqual(g.enrich([plain], self.path), [plain])
        self.assertIn('notes: "just notes"', g.row_line(1, plain))
        self.assertEqual(g.enrich([plain], Path(self.dir.name) / "missing.db"), [plain])

    def test_the_prompt_explains_the_new_fields(self):
        text = g.build_prompt([{"id": "a", "amount": "-1"}], CATS)
        self.assertIn("my note", text)
        self.assertIn("Breakfast, Brunch, Lunch or Dinner", text)
