"""Tests for the Cashew link builder (stdlib unittest, temporary database)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from txdb import cashew, db, ingest  # noqa: E402

BASE = cashew.BASE_URL
SBI_OUT = "UPI- TRANSFER TO 4897692162094 UPI/DR/125045259403/THEJUS M/HDFC/8921768575/NO RE"
HDFC_IN = "UPI-THEJUS M-THEJUSM@OKSBI-SBIN0070528-125045259403-UPI"


def row(i, date, amount, merchant="SHOP", **extra):
    return {"id": f"t-{i}", "date": date, "merchant": merchant, "amount": amount, "currency": "INR",
            "rawStatementRowId": str(i), **extra}


def decode(url):
    assert url.startswith(BASE)
    return json.loads(urllib.parse.unquote(url[len(BASE):]))


def draft(i, **kw):
    d = {"id": f"d{i}", "include": True, "date": "2026-10-01", "title": f"T{i}", "amount": "-10.00",
         "category": "Food Out", "subcategory": "Others", "account": "HDFC", "notes": "n", "kind": "spend",
         "pairId": ""}
    d.update(kw)
    return d


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "t.db"
        self.state_path = Path(self.dir.name) / "state.json"
        self.conn = db.connect(self.path)
        self.hdfc = ingest.ensure_account(self.conn, "HDFC", "checking", "7367")
        self.card = ingest.ensure_account(self.conn, "HDFC", "credit", "0220")
        self.sbi = ingest.ensure_account(self.conn, "SBI", "checking", "9373")

    def tearDown(self):
        self.conn.close()
        self.dir.cleanup()

    def add(self, aid, *rows):
        ingest.upsert_rows(self.conn, aid, list(rows))

    def drafts(self, state=None):
        ro = cashew.open_readonly(self.path)
        try:
            return cashew.drafts(ro, state)
        finally:
            ro.close()

    def cli(self, *args, stdin=None):
        env = {**os.environ, "TXDB_DB": str(self.path), "TXDB_CASHEW_STATE": str(self.state_path)}
        return subprocess.run([sys.executable, str(ROOT / "bin/txdb"), *args], env=env, input=stdin,
                              capture_output=True, text=True, check=True)


class LinkTests(unittest.TestCase):
    def test_escape_percent(self):
        self.assertEqual(cashew.escape_percent("100% sure %25"), "100%25 sure %2525")

    def test_link_round_trip(self):
        notes = "A&B +c #d 100% ₹ \U0001F333\nline2"
        res = cashew.build_links([draft(1, title="Tea & Co 50%", notes=notes, account="ICICI \U0001F333")])
        url = res["links"][0]["url"]
        self.assertTrue(url.startswith(BASE))
        self.assertNotIn("\n", url)
        raw = urllib.parse.unquote(url[len(BASE):])
        self.assertIn("\\n", raw)                         # newline is backslash-n in the JSON text
        entry = json.loads(raw)["transactions"][0]
        self.assertEqual(urllib.parse.unquote(entry["notes"]), notes)   # Cashew's second decode
        self.assertEqual(urllib.parse.unquote(entry["title"]), "Tea & Co 50%")
        self.assertEqual(entry["account"], "ICICI \U0001F333")
        self.assertEqual(entry["amount"], "-10.00")
        self.assertEqual(urllib.parse.quote(raw, safe=""), url[len(BASE):])  # encoded once only

    def test_optional_keys_omitted_and_include(self):
        res = cashew.build_links([draft(1, subcategory="", account=""), draft(2, include=False)])
        self.assertEqual(res["links"][0]["count"], 1)
        e = decode(res["links"][0]["url"])["transactions"][0]
        self.assertNotIn("subcategory", e)
        self.assertNotIn("account", e)
        self.assertTrue(all(isinstance(v, str) for v in e.values()))

    def test_chunking_and_sort(self):
        ds = [draft(i, date=f"2026-10-{30 - i:02d}") for i in range(12)]
        res = cashew.build_links(ds, max_chars=900)
        self.assertGreater(len(res["links"]), 1)
        self.assertEqual(sum(l["count"] for l in res["links"]), 12)
        for l in res["links"]:
            self.assertLessEqual(l["chars"], 900)
            dates = [t["date"] for t in decode(l["url"])["transactions"]]
            self.assertEqual(dates, sorted(dates))

    def test_pair_stays_together(self):
        ds = [draft(i, date="2026-10-01") for i in range(6)]
        ds += [draft(10, pairId="p", kind="transfer", amount="-5.00"),
               draft(11, pairId="p", kind="transfer", amount="5.00")]
        for limit in range(500, 1500, 37):
            res = cashew.build_links(ds, max_chars=limit)
            homes = [i for i, l in enumerate(res["links"]) if "d10" in l["ids"] or "d11" in l["ids"]]
            self.assertEqual(len(set(homes)), 1, limit)

    def test_oversize_single_warns(self):
        res = cashew.build_links([draft(1)], max_chars=50)
        self.assertEqual(len(res["links"]), 1)
        self.assertTrue(any("over the 50" in w for w in res["warnings"]))

    def test_notes_cut_and_warnings(self):
        res = cashew.build_links([draft(1, notes="x" * 700), draft(2, category="Uncategorized", subcategory="Unknown"),
                                  draft(3, kind="transfer", pairId="q"),
                                  draft(4, amount="25.00", category="Food Out")])
        notes = decode(res["links"][0]["url"])["transactions"][0]["notes"]
        self.assertEqual(len(notes), 500)
        text = "\n".join(res["warnings"])
        for needle in ("notes cut", "no category", "without partner", "does not fit"):
            self.assertIn(needle, text)


class DraftTests(Base):
    def test_basic_draft_fields(self):
        self.add(self.hdfc, row(1, "2026-10-02", -250.0, "SWIGGY ORDER 123"),
                 row(2, "2026-10-01", 40.0, "Mystery Co"), row(3, "2026-10-03", -5.0, "X", status="unsettled"),
                 row(4, "2026-10-03", -7.0, "Tracked"))
        ingest.upsert_rows(self.conn, self.card, [row(5, "2026-10-04", -9.99, "Card shop")])
        self.conn.execute("INSERT INTO tracked VALUES ('t-4', 'now')")
        ds = {d["id"]: d for d in self.drafts()}
        self.assertEqual(set(ds), {"t-1", "t-2", "t-5"})          # tracked and unsettled left out
        d = ds["t-1"]
        self.assertEqual((d["amount"], d["date"], d["kind"], d["include"]), ("-250.00", "2026-10-02", "spend", True))
        self.assertEqual((d["category"], d["subcategory"], d["account"]), ("Food Out", "Delivery", "HDFC"))
        self.assertTrue(d["notes"].startswith("HDFC ••67".replace("•67", "••7367")[:0] + "HDFC "))
        self.assertIn("••7367", d["notes"])
        self.assertEqual(ds["t-5"]["account"], "HDFC ₹")
        self.assertEqual(ds["t-2"]["kind"], "income")
        self.assertEqual((ds["t-2"]["amount"], ds["t-2"]["category"], ds["t-2"]["subcategory"]),
                         ("40.00", "Uncategorized", "Unknown"))

    def test_sign_rule_and_fallback(self):
        # a debit that a credit-only rule would hit stays a debit rule: "interest" credit rule is skipped
        self.add(self.hdfc, row(1, "2026-10-02", -9.0, "OTHER- CREDIT INTEREST"),
                 row(2, "2026-10-02", 9.0, "OTHER- CREDIT INTEREST"))
        ds = {d["id"]: d for d in self.drafts()}
        self.assertEqual(ds["t-1"]["category"], "Uncategorized")
        self.assertEqual(ds["t-2"]["category"], "Returns & Interest")
        # a taught income category on a debit falls back with a warning
        gk = ds["t-1"]["groupKey"]
        st = cashew.empty_state()
        st["categories"][gk] = {"category": "Salary", "subcategory": "Monthly"}
        ds = {d["id"]: d for d in self.drafts(st)}
        self.assertEqual(ds["t-1"]["category"], "Uncategorized")
        self.assertIn("does not fit", ds["t-1"]["warn"])
        self.assertEqual(ds["t-2"]["category"], "Salary")        # fits the credit
        st["categories"][gk] = {"category": "Nope"}
        self.assertIn("unknown category", {d["id"]: d for d in self.drafts(st)}["t-1"]["warn"])

    def test_state_overrides(self):
        self.add(self.hdfc, row(1, "2026-10-02", -3.0, "Corner Shop"))
        d0 = self.drafts()[0]
        st = cashew.empty_state()
        st["categories"][d0["groupKey"]] = {"category": "Groceries", "subcategory": "Provisions"}
        st["accounts"][self.hdfc] = "Main \U0001F333"
        d = self.drafts(st)[0]
        self.assertEqual((d["category"], d["subcategory"], d["account"]), ("Groceries", "Provisions", "Main \U0001F333"))
        self.assertIn("Main \U0001F333", cashew.account_names(st))

    def test_rename_override_title(self):
        self.add(self.hdfc, row(1, "2026-10-02", -3.0, "Corner  Shop 77"))
        gk = self.drafts()[0]["groupKey"]
        self.conn.execute("INSERT INTO merchant_names VALUES (?, ?, 'now')", (gk, "  My   shop " + "z" * 300))
        t = self.drafts()[0]["title"]
        self.assertTrue(t.startswith("My shop z"))
        self.assertEqual(len(t), 250)

    def test_notes_cut_at_500(self):
        self.add(self.hdfc, row(1, "2026-10-02", -3.0, "M" * 700))
        self.assertEqual(len(self.drafts()[0]["notes"]), 500)

    def test_transfer_pair_and_one_sided(self):
        self.add(self.sbi, row(1, "2026-10-02", -500.0, SBI_OUT))
        self.add(self.hdfc, row(2, "2026-10-02", 500.0, HDFC_IN))
        ds = {d["id"]: d for d in self.drafts()}
        out, inn = ds["t-1"], ds["t-2"]
        self.assertEqual((out["kind"], out["category"], out["subcategory"]), ("transfer", "Balance Correction", ""))
        self.assertEqual((out["title"], inn["title"]), ("Transfer to HDFC", "Transfer from SBI"))
        self.assertTrue(out["pairId"] and out["pairId"] == inn["pairId"])
        res = cashew.build_links(list(ds.values()), max_chars=800)
        homes = {i for i, l in enumerate(res["links"]) for x in l["ids"] if x in ("t-1", "t-2")}
        self.assertEqual(len(homes), 1)
        self.assertEqual(res["warnings"], [])
        # a tracked partner leaves a lone leg that is still a transfer but warns
        self.conn.execute("INSERT INTO tracked VALUES ('t-2', 'now')")
        lone = self.drafts()
        self.assertEqual([d["id"] for d in lone], ["t-1"])
        self.assertEqual(lone[0]["kind"], "transfer")
        self.assertTrue(any("without partner" in w for w in cashew.build_links(lone)["warnings"]))

    def test_one_sided_own_name_leg(self):
        # the pair teaches the own name; a second row with that name and no partner is one-sided
        self.add(self.sbi, row(1, "2026-10-02", -500.0, SBI_OUT))
        self.add(self.hdfc, row(2, "2026-10-02", 500.0, HDFC_IN),
                 row(3, "2026-10-09", 70.0, "UPI-THEJUS M-THEJUSM@OKSBI-SBIN0070528-125099999999-UPI"))
        d = {x["id"]: x for x in self.drafts()}["t-3"]
        self.assertEqual((d["kind"], d["pairId"], d["category"]), ("transfer", "", "Balance Correction"))
        self.assertEqual(d["title"], "Transfer from SBI")
        self.conn.execute("INSERT INTO transfer_splits VALUES ('t-3', 'now')")
        self.assertEqual({x["id"]: x for x in self.drafts()}["t-3"]["kind"], "income")   # split = not a transfer


class CliTests(Base):
    def test_cashew_draft_shape(self):
        self.add(self.hdfc, row(1, "2026-10-02", -250.0, "SWIGGY ORDER"))
        self.state_path.write_text("{ not json")                       # corrupt state = empty state
        out = json.loads(self.cli("cashew-draft").stdout)
        self.assertEqual(set(out), {"categories", "accountNames", "drafts", "state"})
        self.assertEqual(len(out["categories"]), 24)
        self.assertEqual(out["state"], {"version": 1, "categories": {}, "accounts": {}})
        self.assertIn("HDFC ₹", out["accountNames"])
        self.assertEqual(set(out["drafts"][0]), {
            "id", "include", "date", "title", "amount", "category", "subcategory", "account", "notes", "kind",
            "bank", "last4", "accountId", "groupKey", "pairId", "warn"})
        self.assertEqual(set(out["categories"][0]), {"name", "type", "subcategories", "icon", "color"})
        for c in out["categories"]:
            self.assertRegex(c["color"], r"^#[0-9A-Fa-f]{6}$")
            self.assertTrue(c["icon"])

    def test_cashew_draft_state_file(self):
        self.add(self.hdfc, row(1, "2026-10-02", -250.0, "Plain Shop"))
        gk = json.loads(self.cli("cashew-draft").stdout)["drafts"][0]["groupKey"]
        st = Path(self.dir.name) / "s2.json"
        st.write_text(json.dumps({"version": 1, "categories": {gk: {"category": "Shopping", "subcategory": "Others"}},
                                  "accounts": {}}))
        out = json.loads(self.cli("cashew-draft", "--state", str(st)).stdout)
        self.assertEqual(out["drafts"][0]["category"], "Shopping")
        self.assertEqual(out["state"]["categories"][gk]["category"], "Shopping")

    def test_links_stdin_and_file(self):
        payload = json.dumps({"drafts": [draft(i) for i in range(5)], "maxChars": 700}, ensure_ascii=False)
        res = json.loads(self.cli("cashew-links", "-", stdin=payload).stdout)
        self.assertEqual(set(res), {"links", "warnings"})
        self.assertGreater(len(res["links"]), 1)
        self.assertEqual(sum(l["count"] for l in res["links"]), 5)
        f = Path(self.dir.name) / "d.json"
        f.write_text(payload, encoding="utf-8")
        self.assertEqual(json.loads(self.cli("cashew-links", str(f)).stdout), res)
        self.assertEqual(set(res["links"][0]), {"url", "count", "chars", "ids", "json"})

    def test_untracked_lines(self):
        self.add(self.hdfc, *[row(i, "2026-10-02", -10.0 - i, f"Shop {i}" + "y" * 80) for i in range(60)])
        p = self.cli("cashew-links", "--untracked")
        lines = p.stdout.splitlines()
        self.assertGreater(len(lines), 1)
        self.assertTrue(all(l.startswith(BASE) for l in lines))
        self.assertIn(f"60 transactions in {len(lines)} links; 60 need a category", p.stderr)

    def test_read_only(self):
        self.add(self.hdfc, row(1, "2026-10-02", -10.0))
        before = self.conn.execute("PRAGMA data_version").fetchone()[0]
        self.cli("cashew-draft")
        self.cli("cashew-links", "--untracked")
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM tracked").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("PRAGMA data_version").fetchone()[0], before)


if __name__ == "__main__":
    unittest.main()
