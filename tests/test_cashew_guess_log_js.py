"""The guess results log helpers in Model.js, run through node."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NODE = shutil.which("node")

SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


def run(expr, data=None):
    out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(data), expr],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def draft(id, **kw):
    d = {"id": id, "title": "T" + id, "amount": "-10.00", "category": "Uncategorized",
         "subcategory": "Unknown", "warn": "", "groupKey": "g" + id, "touched": False, "guessed": False}
    d.update(kw)
    return d


@unittest.skipUnless(NODE, "node not installed")
class GuessLogTests(unittest.TestCase):
    def setUp(self):
        self.drafts = [draft("a"), draft("b"), draft("c"), draft("d", warn="no category")]
        self.rows = [{"id": i, "title": "x", "amount": "-1"} for i in "abcd"]

    def new(self):
        return run("cashewGuessLogNew(input.rows, input.drafts)", {"rows": self.rows, "drafts": self.drafts})

    def test_new_log_is_pending_with_before(self):
        log = self.new()
        self.assertEqual([e["state"] for e in log], ["pending"] * 4)
        self.assertEqual(log[0]["before"]["category"], "Uncategorized")
        self.assertEqual(log[3]["before"]["warn"], "no category")
        self.assertTrue(all(e["sent"] and e["guess"] is None for e in log))

    def test_apply_states(self):
        log = self.new()
        self.drafts[1]["touched"] = True
        res = [{"id": "a", "category": "Food Out", "subcategory": "Delivery"},
               {"id": "b", "category": "Food Out", "subcategory": ""},
               {"id": "c", "category": "", "subcategory": ""}]
        out = run("cashewGuessLogApply(input.log, input.drafts, input.res)",
                  {"log": log, "drafts": self.drafts, "res": res})
        self.assertEqual([e["state"] for e in out], ["guessed", "skipped-touched", "no-guess", "pending"])
        self.assertEqual(out[0]["guess"], {"category": "Food Out", "subcategory": "Delivery"})
        fin = run("cashewGuessLogFinish(input)", out)
        self.assertEqual(fin[3]["state"], "no-guess")
        counts = run("cashewGuessLogCounts(input)", fin)
        self.assertEqual(counts, {"guessed": 1, "sent": 4})

    def test_accept_one_and_revert(self):
        log = self.new()
        log = run("cashewGuessLogApply(input.log, input.drafts, input.res)",
                  {"log": log, "drafts": self.drafts,
                   "res": [{"id": "a", "category": "Food Out", "subcategory": "Delivery"},
                           {"id": "d", "category": "Shopping", "subcategory": ""}]})
        drafts = run("cashewApplyGuesses(input.drafts, [{id:'a',category:'Food Out',subcategory:'Delivery'},"
                     "{id:'d',category:'Shopping',subcategory:''}])", {"drafts": self.drafts})
        live = run("cashewGuessLogLive(input.log, input.drafts)", {"log": log, "drafts": drafts})
        self.assertEqual(live, ["a", "d"])
        rev = run("cashewRevertGuesses(input.drafts, input.log, ['d'])", {"drafts": drafts, "log": log})
        self.assertEqual(rev[3]["category"], "Uncategorized")
        self.assertEqual(rev[3]["warn"], "no category")
        self.assertFalse(rev[3]["guessed"])
        self.assertEqual(rev[0]["category"], "Food Out")
        acc = run("cashewAcceptOne(input.drafts, {version:1,categories:{},accounts:{}}, 'a')", {"drafts": drafts})
        self.assertFalse(acc["drafts"][0]["guessed"])
        self.assertTrue(acc["drafts"][3]["guessed"])
        self.assertIn("ga", acc["state"]["categories"])

    def test_view_filters_and_edited(self):
        log = self.new()
        log = run("cashewGuessLogApply(input.log, input.drafts, input.res)",
                  {"log": log, "drafts": self.drafts, "res": [{"id": "a", "category": "Food Out", "subcategory": ""},
                                                              {"id": "b", "category": "", "subcategory": ""}]})
        drafts = self.drafts  # draft "a" is not marked guessed: the user changed it
        v = run("cashewGuessLogView(input.log, input.drafts, 'all')", {"log": log, "drafts": drafts})
        self.assertEqual(v[0]["st"], "skipped-touched")
        v = run("cashewGuessLogView(input.log, input.drafts, 'none')", {"log": log, "drafts": drafts})
        self.assertEqual([r["gid"] for r in v], ["x:b"])
        v = run("cashewGuessLogView(input.log, input.drafts, 'guessed')", {"log": log, "drafts": drafts})
        self.assertEqual([r["gid"] for r in v], ["x:a"])

    def test_raw_cap_and_summary(self):
        lines = run("(function(){var l=[];for(var i=0;i<250;i++) l=cashewGuessRawPush(l,'x'+i,200);return l})()")
        self.assertEqual(len(lines), 200)
        self.assertEqual(lines[-1], "x249")
        self.assertEqual(run("cashewGuessSummary(81, 11, 91.2, 'gemma4:e2b')"), "81 rows in 11 batches · 91 s · gemma4:e2b")
        self.assertEqual(run("cashewGuessSummary(1, 1, 0, '')"), "1 row in 1 batch · running")


if __name__ == "__main__":
    unittest.main()


def _d(id, **kw):
    d = {"id": id, "title": "T" + id, "amount": "-10.00", "category": "Uncategorized", "subcategory": "Unknown",
         "warn": "", "kind": "spend", "notes": "", "touched": False, "guessed": False}
    d.update(kw)
    return d


@unittest.skipUnless(NODE, "node not installed")
class GuessScopeTests(unittest.TestCase):
    def ids(self, drafts):
        rows = run("cashewGuessRows(input, input.map((d, i) => i))", drafts)
        return [r["id"] for r in rows]

    def test_only_noted_uncategorised_rows_are_sent(self):
        # A row with a real title/merchant but no note is sent too (fixed
        # 2026-11-12): cashew_guess.py's own prompt already treats merchant
        # text as its own clue, so requiring a note on top of that excluded
        # most real "needs category" rows, which are bare card/POS
        # transactions with a merchant name and no UPI remark.
        drafts = [
            _d("a", notes="dinner with Ravi"),                       # sent: has a note
            _d("b", notes="   "),                                    # blank note, but a real title: sent
            _d("c", category="Food Out", subcategory="", notes="x"),  # has a category: never sent
            _d("d", category="Food Out", notes="x", warn="no category"),  # warn: sent
            _d("e", notes="x", kind="transfer"),
            _d("f", notes="x", touched=True),
            _d("g", notes="x", guessed=True, category="Food Out"),
            _d("h", category="Friend Settlement", subcategory="Friend", notes="rent"),
            _d("i", title="", notes="   "),                          # title, merchant and notes all blank: not sent
        ]
        self.assertEqual(self.ids(drafts), ["a", "b", "d"])

    def test_note_is_trimmed_in_the_row(self):
        rows = run("cashewGuessRows(input, [0])", [_d("a", notes="  hi  ")])
        self.assertEqual(rows[0]["notes"], "hi")

    def test_need_category_and_next(self):
        drafts = [_d("a"), _d("b", category="Food Out", warn=""), _d("c", kind="transfer"), _d("d", warn="x")]
        self.assertEqual(run("cashewNeedIdxs(input, [0,1,2,3])", drafts), [0, 3])
        order = [{"idx": i, "partner": -1} for i in range(4)]
        nxt = lambda frm: run("cashewNextNeed(input.d, input.o, %d)" % frm, {"d": drafts, "o": order})
        self.assertEqual(nxt(-1), 0)
        self.assertEqual(nxt(0), 3)
        self.assertEqual(nxt(3), 0)   # wraps
        self.assertEqual(run("cashewNextNeed(input.d, input.o, 0)", {"d": [_d("a", category="Food Out")], "o": order[:1]}), -1)

    def test_closed_account_rows_are_not_shown(self):
        drafts = [_d("a"), _d("b")]
        self.assertEqual(run("cashewShownIndexes(input, false, null, {b: true})", drafts), [0])


@unittest.skipUnless(NODE, "node not installed")
class GuessProgressTextTests(unittest.TestCase):
    def test_progress_and_done_text(self):
        self.assertEqual(run("cashewGuessProgressText({batch:2,of:3,phase:'thinking',tokens:480,elapsed:72}, 8, 21)"),
                         "Batch 2 / 3 · thinking · 480 tokens · 1:12  (8 / 21 rows done)")
        self.assertEqual(run("cashewGuessProgressText({}, 0, 21)"), "Starting · 0 / 21")
        self.assertEqual(run("cashewGuessDoneText(19, 21, 370)"), "Done · 19 of 21 got a category · 2 had no answer · 6 min 10 s")
        self.assertEqual(run("cashewGuessDoneText(3, 3, 41)"), "Done · 3 of 3 got a category · 41 s")
