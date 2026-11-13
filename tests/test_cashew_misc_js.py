"""Uncategorized > Miscellaneous is a deliberate choice: not a missing category, no warning."""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

from txdb import cashew

ROOT = Path(__file__).resolve().parent.parent
NODE = shutil.which("node")
SCRIPT = """
const fs = require("fs"), vm = require("vm");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), ctx);
ctx.input = JSON.parse(process.argv[2]);
console.log(JSON.stringify(vm.runInContext(process.argv[3], ctx)));
"""


def js(expr, **values):
    out = subprocess.run([NODE, "-e", SCRIPT, str(ROOT / "Model.js"), json.dumps(values), expr],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def draft(sub):
    return {"id": "d1", "include": True, "date": "2026-11-11", "title": "Laptop Repair", "amount": "-5100.00",
            "category": "Uncategorized", "subcategory": sub, "account": "SBI ₹", "notes": "", "kind": "spend", "pairId": ""}


class MiscellaneousTests(unittest.TestCase):
    def test_python_links_do_not_warn_for_miscellaneous(self):
        self.assertEqual(cashew.build_links([draft("Miscellaneous")])["warnings"], [])
        self.assertTrue(any("no category" in w for w in cashew.build_links([draft("Unknown")])["warnings"]))

    @unittest.skipUnless(NODE, "node is not installed")
    def test_widget_does_not_count_it_as_needing_a_category(self):
        self.assertFalse(js("cashewNeedsCategory(input.d)", d=draft("Miscellaneous")))
        self.assertTrue(js("cashewNeedsCategory(input.d)", d=draft("Unknown")))
        self.assertTrue(js("cashewNeedsCategory(input.d)", d=draft("")))

    @unittest.skipUnless(NODE, "node is not installed")
    def test_widget_links_do_not_warn(self):
        r = js("cashewBuildLinks(input.d, [0], 6000, input.c, 'app')", d=[draft("Miscellaneous")],
               c=cashew.load_categories())
        self.assertEqual(r["warnings"], [])


if __name__ == "__main__":
    unittest.main()
