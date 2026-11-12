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

    def test_pair_leaves_the_bulk_links(self):
        ds = [draft(i, date="2026-10-01") for i in range(6)]
        ds += [draft(10, pairId="p", kind="transfer", amount="-5.00"),
               draft(11, pairId="p", kind="transfer", amount="5.00")]
        for limit in range(500, 1500, 37):
            res = cashew.build_links(ds, max_chars=limit)
            self.assertFalse([l for l in res["links"] if "d10" in l["ids"] or "d11" in l["ids"]], limit)
            self.assertEqual(sum(l["count"] for l in res["links"]), 6)
            self.assertEqual([t["ids"] for t in res["transfers"]], [["d10", "d11"]])

    def test_every_bulk_entry_has_a_fallback_category(self):
        res = cashew.build_links([draft(1), draft(2, category="Uncategorized", subcategory="", account="")])
        for e in decode(res["links"][0]["url"])["transactions"]:
            self.assertEqual(e["fallbackCategory"], "Uncategorized")

    def test_transfer_link(self):
        out = draft(1, pairId="p", kind="transfer", amount="-1.00", account="HDFC", title="Transfer to SBI 100%",
                    date="2026-11-07", category="Balance Correction")
        inn = draft(2, pairId="p", kind="transfer", amount="1.50", account="SBI \u20b9", title="Transfer from HDFC",
                    date="2026-11-08", category="Balance Correction")
        res = cashew.build_links([inn, out])
        self.assertEqual(res["links"], [])
        self.assertEqual(res["warnings"], [])
        t = res["transfers"][0]
        self.assertEqual((t["pairId"], t["title"], t["date"], t["amount"], t["accountFrom"], t["accountTo"], t["ids"]),
                         ("p", "Transfer to SBI 100%", "2026-11-07", "1.00", "HDFC", "SBI \u20b9", ["d1", "d2"]))
        self.assertTrue(t["url"].startswith("https://cashewapp.web.app/addTransferRoute?"))
        q = t["url"].split("?", 1)[1]
        self.assertEqual(q, "amountFrom=1.00&amountTo=1.50&accountFrom=HDFC&accountTo=SBI%20%E2%82%B9"
                            "&title=Transfer%20to%20SBI%20100%2525&date=2026-11-07")
        self.assertEqual(cashew.build_links([inn, out], base="web")["transfers"][0]["url"][:48],
                         "https://budget-track.web.app/addTransferRoute?am")

    def test_base_option(self):
        web = cashew.build_links([draft(1)], base="web")
        self.assertTrue(web["links"][0]["url"].startswith("https://budget-track.web.app/addTransaction?JSON="))
        self.assertTrue(cashew.build_links([draft(1)], base="app")["links"][0]["url"].startswith(BASE))
        self.assertTrue(cashew.build_links([draft(1)], base="junk")["links"][0]["url"].startswith(BASE))

    def test_pair_with_one_leg_included_is_a_lone_leg(self):
        ds = [draft(10, pairId="p", kind="transfer", amount="-5.00", category="Balance Correction"),
              draft(11, pairId="p", kind="transfer", amount="5.00", include=False, category="Balance Correction")]
        res = cashew.build_links(ds)
        self.assertEqual(res["transfers"], [])
        self.assertEqual(res["links"][0]["ids"], ["d10"])
        self.assertTrue(any("without partner" in w for w in res["warnings"]))

    def test_pair_with_two_debits_is_not_a_transfer_page(self):
        ds = [draft(10, pairId="p", kind="transfer", amount="-5.00"), draft(11, pairId="p", kind="transfer",
                                                                            amount="-5.00")]
        res = cashew.build_links(ds)
        self.assertEqual(res["transfers"], [])
        self.assertEqual(res["links"][0]["count"], 2)

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
        self.assertEqual(set(ds), {"t-1", "t-2", "t-3", "t-5"})   # tracked left out; unsettled shown like any other row
        self.assertEqual((ds["t-3"]["pending"], ds["t-3"]["include"]), (True, True))
        d = ds["t-1"]
        self.assertEqual((d["amount"], d["date"], d["kind"], d["include"]), ("-250.00", "2026-10-02", "spend", True))
        self.assertEqual((d["category"], d["subcategory"], d["account"]), ("Food Out", "Delivery", "HDFC"))
        self.assertEqual(d["notes"], "")                          # no remark, no bill: no note
        self.assertEqual(ds["t-5"]["account"], "HDFC ₹")
        self.assertEqual(ds["t-2"]["kind"], "income")
        self.assertEqual((ds["t-2"]["amount"], ds["t-2"]["category"], ds["t-2"]["subcategory"]),
                         ("40.00", "Friend Settlement", "Split Paid"))   # HDFC savings default, was Uncategorized

    def test_sign_rule_and_fallback(self):
        # a debit that a credit-only rule would hit stays a debit rule: "interest" credit rule is skipped
        self.add(self.hdfc, row(1, "2026-10-02", -9.0, "OTHER- CREDIT INTEREST"),
                 row(2, "2026-10-02", 9.0, "OTHER- CREDIT INTEREST"))
        ds = {d["id"]: d for d in self.drafts()}
        self.assertEqual(ds["t-1"]["category"], "Friend Settlement")   # HDFC savings default (was Uncategorized)
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
        self.conn.execute("UPDATE transactions SET note = ?", ("x" * 700,))
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
        self.assertEqual(res["links"], [])
        self.assertEqual([t["ids"] for t in res["transfers"]], [["t-1", "t-2"]])
        self.assertEqual((res["transfers"][0]["accountFrom"], res["transfers"][0]["accountTo"]), ("SBI", "HDFC"))
        self.assertEqual(res["warnings"], [])
        # a tracked partner leaves a lone leg that is still a transfer; it starts unticked, so no warning
        self.conn.execute("INSERT INTO tracked VALUES ('t-2', 'now')")
        lone = self.drafts()
        self.assertEqual([d["id"] for d in lone], ["t-1"])
        self.assertEqual(lone[0]["kind"], "transfer")
        lone_res = cashew.build_links(lone)
        self.assertFalse(lone[0]["include"])
        self.assertEqual(lone_res["warnings"], [])
        ticked = cashew.build_links([dict(lone[0], include=True)])      # ticking it again brings the warning back
        self.assertTrue(any("without partner" in w for w in ticked["warnings"]))
        self.assertEqual((lone_res["transfers"], lone_res["links"][0]["ids"]), ([], ["t-1"]))

    def test_transfer_titles_use_the_names_the_user_assigned(self):
        self.add(self.sbi, row(1, "2026-10-02", -500.0, SBI_OUT))
        self.add(self.hdfc, row(2, "2026-10-02", 500.0, HDFC_IN))
        first = {d["id"]: d for d in self.drafts()}
        # a name saved for the OUT leg's payee group wins over "Transfer to HDFC"
        self.conn.execute("INSERT INTO merchant_names VALUES (?, ?, 'now')", (first["t-1"]["groupKey"], "HDFC <-> SBI"))
        ds = {d["id"]: d for d in self.drafts()}
        self.assertEqual((ds["t-1"]["title"], ds["t-2"]["title"]), ("HDFC <-> SBI", "Transfer from SBI"))
        res = cashew.build_links(list(ds.values()))
        self.assertEqual(res["transfers"][0]["title"], "HDFC <-> SBI")   # the transfer page carries the user's name

    def test_category_from_the_name_the_user_gave(self):
        f = cashew.category_from_name
        self.assertEqual(f("Petrol-TIMBER FUELS"), ("Transport", "Petrol"))
        self.assertEqual(f("petrol - Manakattil"), ("Transport", "Petrol"))
        self.assertEqual(f("RD"), ("Investments", "RD"))
        self.assertEqual(f("Groceries: Kunnil"), ("Groceries", ""))
        self.assertEqual(f("Medicine-Apollo"), ("Health", "Medicine"))
        for none in ("Dessi Cuppa", "UPI-MR BIJIN J-12", "Others-x", "Rent-flat", "HDFC <-> SBI", "", None):
            self.assertIsNone(f(none), none)

    def test_a_name_with_a_category_in_it_sets_the_category(self):
        self.add(self.hdfc, row(1, "2026-10-02", -400.0, "UPI-ZEBRA TRADERS-X@OKAXIS-123456789012"))
        gk = self.drafts()[0]["groupKey"]
        self.assertNotEqual(self.drafts()[0]["subcategory"], "Petrol")
        self.conn.execute("INSERT INTO merchant_names VALUES (?, ?, 'now')", (gk, "Petrol-MANAKATTIL FUELS"))
        d = self.drafts()[0]
        self.assertEqual((d["title"], d["category"], d["subcategory"]), ("Petrol-MANAKATTIL FUELS", "Transport", "Petrol"))
        # the category you taught for the merchant still wins over the name
        st = {"version": 1, "categories": {gk: {"category": "Shopping", "subcategory": "Others"}}, "accounts": {}}
        self.assertEqual(cashew.drafts(self.conn, st)[0]["category"], "Shopping")
        # a credit cannot take an expense category from a name: it falls through to the normal rules
        self.add(self.hdfc, row(2, "2026-10-03", 400.0, "UPI-ZEBRA TRADERS-X@OKAXIS-123456789013"))
        cr = {x["id"]: x for x in self.drafts()}["t-2"]
        self.assertNotEqual(cr["subcategory"], "Petrol")

    def test_leg_whose_partner_is_tracked_starts_unticked(self):
        self.add(self.sbi, row(1, "2026-10-02", -500.0, SBI_OUT))
        self.add(self.hdfc, row(2, "2026-10-02", 500.0, HDFC_IN))
        self.conn.execute("INSERT INTO tracked VALUES ('t-1', 'now')")     # the out side is already in Cashew
        d = {x["id"]: x for x in self.drafts()}["t-2"]
        self.assertEqual((d["kind"], d["partnerTracked"], d["include"]), ("transfer", True, False))

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
            "bank", "last4", "accountId", "groupKey", "merchant", "pairId", "warn", "pending", "partnerTracked"})
        self.assertEqual(set(out["categories"][0]), {"name", "type", "subcategories", "icon", "color", "subIcons"})
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
        self.assertEqual(set(res), {"links", "transfers", "warnings"})
        self.assertGreater(len(res["links"]), 1)
        self.assertEqual(sum(l["count"] for l in res["links"]), 5)
        f = Path(self.dir.name) / "d.json"
        f.write_text(payload, encoding="utf-8")
        self.assertEqual(json.loads(self.cli("cashew-links", str(f)).stdout), res)
        self.assertEqual(set(res["links"][0]), {"url", "count", "chars", "ids", "json"})
        web = json.loads(self.cli("cashew-links", "-", stdin=json.dumps({"drafts": [draft(1)], "base": "web"})).stdout)
        self.assertTrue(web["links"][0]["url"].startswith("https://budget-track.web.app/addTransaction?JSON="))

    def test_untracked_prints_transfer_pages_after_bulk(self):
        self.add(self.sbi, row(1, "2026-10-02", -500.0, SBI_OUT))
        self.add(self.hdfc, row(2, "2026-10-02", 500.0, HDFC_IN), row(3, "2026-10-03", -10.0, "Tea shop"))
        p = self.cli("cashew-links", "--untracked")
        lines = p.stdout.splitlines()
        i = lines.index("# transfer pages (tap Save in Cashew for each):")
        self.assertTrue(all(l.startswith(BASE) for l in lines[:i]))
        self.assertEqual(len(lines) - i - 1, 1)
        self.assertTrue(lines[i + 1].startswith("https://cashewapp.web.app/addTransferRoute?amountFrom=500.00&"))
        self.assertIn("1 transfer pages", p.stderr)
        self.state_path.write_text(json.dumps({"version": 1, "categories": {}, "accounts": {}, "base": "web"}))
        lines = self.cli("cashew-links", "--untracked").stdout.splitlines()
        self.assertTrue(lines[0].startswith("https://budget-track.web.app/addTransaction?JSON="))
        self.assertTrue(lines[-1].startswith("https://budget-track.web.app/addTransferRoute?"))

    def test_untracked_lines(self):
        self.add(self.sbi, *[row(i, "2026-10-02", -10.0 - i, f"Shop {i}" + "y" * 80) for i in range(60)])
        p = self.cli("cashew-links", "--untracked")
        lines = p.stdout.splitlines()
        self.assertGreater(len(lines), 1)
        self.assertTrue(all(l.startswith(BASE) for l in lines))
        self.assertIn(f"60 transactions in {len(lines)} links and 0 transfer pages; 60 need a category", p.stderr)

    def test_read_only(self):
        self.add(self.hdfc, row(1, "2026-10-02", -10.0))
        before = self.conn.execute("PRAGMA data_version").fetchone()[0]
        self.cli("cashew-draft")
        self.cli("cashew-links", "--untracked")
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM tracked").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("PRAGMA data_version").fetchone()[0], before)


if __name__ == "__main__":
    unittest.main()


class NoteTests(Base):
    def test_upi_remark_per_bank(self):
        r = cashew.upi_remark
        self.assertEqual(r("UPI/P2A/111/THEJUS M /HDFC/MF and F/", "AXIS"), "MF and F")       # cut short, kept
        self.assertEqual(r("UPI/P2A/153/THEJUS M MANOJ /For Cc/HDFC BANK LTD", "AXIS"), "For Cc")
        self.assertEqual(r("UPI/P2A/174/LAKSHMI MOHAN /NO REM/State Bank Of India", "AXIS"), "")
        self.assertEqual(r("UPI/P2M/103/ICCL GROW/HDFC BANK/Indian C//P2V/", "AXIS"), "")
        self.assertEqual(r("UPI/P2M/101/ICCL GROW/HDFC BANK/UPI Auto//P2V/", "AXIS"), "")
        self.assertEqual(r("UPI/P2A/533/THEJUS M /HDFC/MF/", "AXIS"), "")                   # under 3 characters
        self.assertEqual(r("UPI- TRANSFER FROM 4897735162098 UPI/CR/184/THEJUSMM/HDFC/8921768575/Savin", "SBI"), "Savin")
        for junk in ("NA", "NO R", "UPI", "Paid", "Sent", "paym", "Payin", "Pay", "183", "Gpay"):
            self.assertEqual(r(f"UPI- TRANSFER TO 4897690162095 UPI/DR/519/CRED/UTIB/cred.club@/{junk}", "SBI"), "", junk)
        self.assertEqual(r("UPI-THEJUS M-8921768575@UPI-SBIN0001000-125045259403-FOR CC BILLS", "HDFC"), "FOR CC BILLS")
        for junk in ("NO REMARK", "NO REMARKS", "UPI", "PAY", "1139", "Payment from PhonePe", "Paid via CRED", "Sent from Paytm",
                     "x@oksbi", "ab"):
            self.assertEqual(r(f"UPI-RAHUL A R-*******7306@OKHDFCBANK-FDRL0001401-132316904164-{junk}", "HDFC"), "", junk)
        self.assertEqual(r("UPI-SAVINGS-x@oksbi-SBIN0001000-125045259403-Savings", "HDFC"), "")   # same as the name
        self.assertEqual(r("Upi-swiggy", "HDFC"), "")                                         # card row

    def test_notes_are_empty_by_default_and_hold_the_remark(self):
        self.add(self.hdfc, row(1, "2026-10-02", -250.0, "UPI-SHOP A-a@oksbi-SBIN0001000-125045259403-MF and RD"),
                 row(2, "2026-10-03", -50.0, "UPI-SHOP B-b@oksbi-SBIN0001000-125045259404-NO REMARKS"))
        ds = {d["id"]: d for d in self.drafts()}
        self.assertEqual(ds["t-1"]["notes"], "MF and RD")
        self.assertEqual(ds["t-2"]["notes"], "")

    def test_widget_note_is_kept_and_not_doubled(self):
        self.add(self.hdfc, row(1, "2026-10-02", -250.0, "UPI-SHOP A-a@oksbi-SBIN0001000-125045259403-MF and RD"))
        self.assertEqual(self.drafts()[0]["notes"], "MF and RD")
        self.conn.execute("UPDATE transactions SET note = 'lunch with Sam' WHERE id = 't-1'")
        self.assertEqual(self.drafts()[0]["notes"], "MF and RD\nlunch with Sam")

    def link_bill(self, txn, merchant="Cake World", items=3, total=14900, tax=1500):
        from txdb import receipts
        rid = receipts.save_parse(self.conn, {
            "image_sha256": "a" * 64, "stored_path": "x.jpg", "merchant": merchant, "date": "2026-09-15",
            "total_paise": total, "tax_paise": tax,
            "items": [{"description": f"Item {i}", "qty": 1 + i, "amount": 10 + i} for i in range(items)]})
        receipts.set_link(self.conn, rid, txn)

    def test_linked_bill_note(self):
        self.add(self.hdfc, row(1, "2026-10-02", -149.0, "UPI-SHOP A-a@oksbi-SBIN0001000-125045259403-CC BILL"))
        self.link_bill("t-1")
        n = self.drafts()[0]["notes"]
        lines = n.split("\n")
        self.assertEqual(lines[0], "CC BILL")                                  # remark first
        self.assertEqual(lines[1], "Cake World · 2026-09-15")
        self.assertEqual(lines[2], "• 1 × Item 0 — ₹10")
        self.assertEqual(lines[-2:], ["Total ₹149", "GST ₹15"])

    def test_bill_with_many_items_is_cut(self):
        self.add(self.hdfc, row(1, "2026-10-02", -149.0, "SHOP"))
        self.link_bill("t-1", merchant="SHOP", items=20)
        n = self.drafts()[0]["notes"]
        lines = n.split("\n")
        self.assertEqual(len([x for x in lines if x.startswith("• ")]), 13)    # 12 items and the "more" line
        self.assertIn("• +8 more items", lines)
        self.assertTrue(lines[0].startswith("• 1 × Item 0"))                    # merchant equals title: no header
        self.assertLessEqual(len(n), 500)

    def test_bill_without_items_gives_no_note(self):
        self.add(self.hdfc, row(1, "2026-10-02", -149.0, "SHOP"))
        self.link_bill("t-1", items=0)
        self.assertEqual(self.drafts()[0]["notes"], "")


class CategoryPriorityTests(Base):
    """Bill category > taught merchant > bill LLM category > keyword rule >
    HDFC-savings Friend Settlement > Uncategorized."""

    def bill(self, txn, category=None, source="llm", fees=None, sha="b" * 64):
        from txdb import receipts
        rid = receipts.save_parse(self.conn, {
            "image_sha256": sha, "stored_path": "x.jpg", "merchant": "Kottayam Kitchen", "date": "2026-10-02",
            "total_paise": 16000, "printed_total_paise": 16000, "tax_paise": 675, "discount_paise": 4400,
            "items": [{"description": "Biryani", "qty": 1, "amount": 179.0}], "fees": fees or [],
            "category": {"category": category[0], "subcategory": category[1]} if category and source == "llm" else None})
        if category and source == "user":
            receipts.set_category(self.conn, rid, *category)
        receipts.set_link(self.conn, rid, txn)
        return rid

    def cat(self, tid="t-1", state=None):
        d = {x["id"]: x for x in self.drafts(state)}[tid]
        return d["category"], d["subcategory"], d["warn"]

    def test_llm_bill_category_beats_rules_but_not_taught(self):
        self.add(self.sbi, row(1, "2026-10-02", -160.0, "SWIGGY ORDER 1"))
        self.bill("t-1", ("Groceries", "Provisions"))
        self.assertEqual(self.cat()[:2], ("Groceries", "Provisions"))
        gk = self.drafts()[0]["groupKey"]
        st = cashew.empty_state()
        st["categories"][gk] = {"category": "Food Out", "subcategory": "Delivery"}
        self.assertEqual(self.cat(state=st)[:2], ("Food Out", "Delivery"))

    def test_user_bill_category_beats_taught(self):
        self.add(self.sbi, row(1, "2026-10-02", -160.0, "Corner Shop"))
        self.bill("t-1", ("Groceries", "Provisions"), source="user")
        gk = self.drafts()[0]["groupKey"]
        st = cashew.empty_state()
        st["categories"][gk] = {"category": "Food Out", "subcategory": "Delivery"}
        self.assertEqual(self.cat(state=st)[:2], ("Groceries", "Provisions"))

    def test_llm_category_that_is_unknown_or_does_not_fit_is_ignored(self):
        self.add(self.sbi, row(1, "2026-10-02", -160.0, "SWIGGY ORDER 1"))
        self.bill("t-1", ("Nope", ""))
        self.assertEqual(self.cat()[:2], ("Food Out", "Delivery"))        # the keyword rule
        self.conn.execute("DELETE FROM receipt_links")
        self.bill("t-1", ("Salary", "Monthly"), sha="c" * 64)              # income on a debit
        self.assertEqual(self.cat()[:2], ("Food Out", "Delivery"))

    def test_llm_category_needs_a_linked_bill(self):
        from txdb import receipts
        self.add(self.sbi, row(1, "2026-10-02", -160.0, "Corner Shop"))
        rid = self.bill("t-1", ("Groceries", "Provisions"))
        receipts.clear_link(self.conn, rid)
        self.assertEqual(self.cat()[0], "Uncategorized")

    def test_bill_note_lists_charges_discount_tax_and_paid_total(self):
        self.add(self.sbi, row(1, "2026-10-02", -160.0, "Kottayam"))
        self.bill("t-1", fees=[{"label": "Packaging", "amount": 0, "original": 9, "waived": True},
                               {"label": "Platform fee", "amount": 17.98}])
        n = self.drafts()[0]["notes"]
        self.assertIn("• Packaging — FREE", n)
        self.assertIn("• Platform fee — ₹17.98", n)
        self.assertIn("Discount -₹44", n)
        self.assertIn("Total ₹160", n)
        self.assertLessEqual(len(n), 500)

    def test_hdfc_savings_default_is_friend_settlement_split_paid_both_ways(self):
        self.add(self.hdfc, row(1, "2026-10-02", -75.0, "Mystery Co"), row(2, "2026-10-02", 75.0, "Other Co"))
        self.assertEqual(self.cat("t-1"), ("Friend Settlement", "Split Paid", ""))
        self.assertEqual(self.cat("t-2"), ("Friend Settlement", "Split Paid", ""))
        res = cashew.build_links(self.drafts())
        self.assertEqual(res["warnings"], [])               # no "no category", no sign warning

    def test_friend_default_only_for_hdfc_savings_without_a_bill(self):
        self.add(self.hdfc, row(1, "2026-10-02", -75.0, "Mystery Co"), row(2, "2026-10-03", -5.0, "SWIGGY X"))
        ingest.upsert_rows(self.conn, self.card, [row(3, "2026-10-04", -9.0, "Card shop")])
        self.add(self.sbi, row(4, "2026-10-04", -9.0, "Other shop"))
        self.bill("t-1", None)
        self.assertEqual(self.cat("t-1")[0], "Uncategorized")                 # has a bill
        self.assertEqual(self.cat("t-2")[:2], ("Food Out", "Delivery"))        # a rule wins
        self.assertEqual(self.cat("t-3")[0], "Uncategorized")                 # card
        self.assertEqual(self.cat("t-4")[0], "Uncategorized")                 # other bank
        gk = {d["id"]: d for d in self.drafts()}["t-1"]["groupKey"]
        st = cashew.empty_state()
        st["categories"][gk] = {"category": "Groceries", "subcategory": "Provisions"}
        self.assertEqual(self.cat("t-1", st)[:2], ("Groceries", "Provisions"))   # taught wins

    def test_friend_default_is_not_used_for_transfer_legs(self):
        self.add(self.sbi, row(1, "2026-10-02", -500.0, SBI_OUT))
        self.add(self.hdfc, row(2, "2026-10-02", 500.0, HDFC_IN))
        ds = {d["id"]: d for d in self.drafts()}
        self.assertEqual((ds["t-1"]["category"], ds["t-2"]["category"]), ("Balance Correction",) * 2)

