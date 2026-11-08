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
    p = subprocess.run(cmd, input=json.dumps(payload), capture_output=True, text=True, timeout=timeout)
    lines = [json.loads(x) for x in p.stdout.splitlines() if x.strip()]
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
        debit_part = p.split("CREDIT categories")[0]
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
        self.assertEqual((fin["done"], fin["total"], fin["model"]), (5, 5, "qwen2.5:3b"))
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
