"""Guess a Cashew category for transactions with a local Ollama model.

Reads {"rows":[...], "taught":{...}} (see `run`), cuts the rows into batches,
asks the model about several batches at the same time and prints one NDJSON
line per finished batch, so the widget can fill rows in as they arrive:

  {"results":[{"id","category","subcategory"}...],"done":n,"total":N}
  {"finished":true,"done":N,"total":N,"seconds":S,"model":M}
  {"error":"message"}

A row the model could not place gets category "" (no guess). Every answer is
checked against the category list: unknown category or wrong sign -> no
guess; a subcategory of another category -> only the subcategory is dropped.
Nothing here writes to the database; the standard library only."""
from __future__ import annotations

import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

from . import cashew

DEFAULT_URL = "http://127.0.0.1:11434"
# qwen2.5:3b was dropped (2026-11-12): it answered every batch with the same
# hallucinated boilerplate list of categories regardless of the actual row,
# and separately echoed the prompt's own "DEBIT"/"CREDIT" section labels back
# as the category itself. gemma4:e2b is the one model already proven
# reliable in this project (also the default bill reader), so it is the
# default here too - one less model Ollama ever has to load.
DEFAULT_MODEL = "gemma4:e2b"
DEFAULT_WORKERS = 3
DEFAULT_BATCH = 8
# gemma4:e2b thinks before answering (see _thinks below); generous enough
# for an 8-row batch's reasoning plus JSON answer on a CPU-only machine.
DEFAULT_TIMEOUT = 300
DEFAULT_NUM_PREDICT = 3000
TAUGHT_MAX = 20
FIELD_MAX = 300

_THINKS: dict[str, bool] = {}


def _thinks(url: str, model: str) -> bool:
    """Whether `model` thinks before answering (ollama capability
    "thinking") - asked once per model via POST /api/show, cached, False
    when it cannot be asked. gemma4:e2b has it; thinking is requested
    explicitly ("think": true) rather than relied on as ollama's default."""
    if model not in _THINKS:
        req = urllib.request.Request(
            url.rstrip("/") + "/api/show", data=json.dumps({"model": model}).encode("utf-8"),
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                info = json.loads(r.read())
            _THINKS[model] = "thinking" in (info.get("capabilities") or [])
        except (urllib.error.URLError, OSError, ValueError):
            _THINKS[model] = False
    return _THINKS[model]

SYSTEM = (
    "You label Indian bank transactions (UPI, debit and credit cards, net banking). "
    "For each numbered row choose ONE Cashew category and subcategory from THIS list only. "
    "Money-out rows must use a category from the \"Money out\" list below; money-in rows "
    "must use a category from the \"Money in\" list below. "
    'The words "Money out" and "Money in" are only section labels, never answers: '
    'your "category" value must always be one of the exact category names written in '
    'those lists (for example "Food Out" or "Friend Settlement"), never the words '
    '"Money out", "Money in", "DEBIT" or "CREDIT" themselves. '
    "A UPI payment to or from a person (a personal name, no shop) is Friend Settlement. "
    "Use the merchant text, the UPI remark and the notes as clues. "
    "A row may also carry: \"UPI remark\" (the free text the payer typed), \"my note\" (written by the "
    "account owner, so trust it), and \"bill\" (the itemised receipt photographed for this very payment: its "
    "merchant, what was bought, the time of day and the total). The bill and my note are the strongest clues, "
    "stronger than the bank's merchant text. If the owner already chose a category for the bill (\"bill "
    "category I chose\"), use it. For a Food Out meal, pick Breakfast, Brunch, Lunch or Dinner from the time "
    "of day on the bill; Delivery is for an app delivery order, Others for a snack or a drink. "
    "If you are not sure use Uncategorized / Unknown. Never invent a category."
)

_JSON_OBJECT = re.compile(r"\{.*\}", re.S)


class GuessError(Exception):
    """A batch failed in a way a second try can fix (timeout, unreadable reply)."""


def extract_json(text: str) -> dict:
    """The JSON object inside a model reply; {} when nothing can be read. Never raises."""
    if not text:
        return {}
    stripped = text.strip()
    cands = [stripped]
    m = _JSON_OBJECT.search(stripped)
    if m:
        cands.append(m.group(0))
    for c in cands:
        try:
            v = json.loads(c)
        except (ValueError, TypeError):
            continue
        if isinstance(v, dict):
            return v
    return {}


# ------------------------------------------------------------------ prompt

def category_lines(categories: list[dict], debit: bool) -> str:
    """One line per category that fits the sign: `Food Out: Breakfast, Brunch`."""
    lines = []
    for c in categories:
        if cashew._fits(c["type"], debit):
            subs = ", ".join(c.get("subcategories") or [])
            lines.append(f"{c['name']}: {subs}" if subs else c["name"])
    return "\n".join(lines)


def _clip(v) -> str:
    s = " ".join(str(v or "").split())
    return s[:FIELD_MAX]


def meal_period(clock) -> str:
    """The meal a HH:MM (24 hour) time of day points to ("" when unknown). Same windows as the
    receipt-ledger-stitcher's bill prompt (src/meta.py meal_period): keep the two in step."""
    try:
        hh, mm = str(clock).split(":")[:2]
        minutes = int(hh) * 60 + int(mm)
    except (ValueError, TypeError):
        return ""
    if not 0 <= minutes < 24 * 60:
        return ""
    for limit, name in ((5 * 60, "late night"), (10 * 60 + 30, "breakfast"), (11 * 60 + 30, "brunch"),
                        (15 * 60 + 30, "lunch"), (18 * 60 + 30, "evening snack")):
        if minutes < limit:
            return name
    return "dinner"


def _clock12(clock) -> str:
    try:
        hh, mm = str(clock).split(":")[:2]
        h = int(hh)
        return f"{(h % 12) or 12}:{int(mm):02d} {'AM' if h < 12 else 'PM'}"
    except (ValueError, TypeError):
        return ""


def bill_text(bill) -> str:
    """One prompt segment for the bill linked to a payment, or ''."""
    if not isinstance(bill, dict):
        return ""
    bits = []
    if bill.get("merchant"):
        bits.append(f'merchant "{_clip(bill["merchant"])}"')
    if bill.get("platform"):
        bits.append(f'via {_clip(bill["platform"])}')
    clock = bill.get("time")
    if clock:
        meal = meal_period(clock)
        bits.append(f"made at {_clock12(clock)}" + (f" ({meal} time)" if meal else ""))
    items = [_clip(i)[:80] for i in (bill.get("items") or []) if _clip(i)]   # a long item name must not eat the prompt
    if items:
        more = int(bill.get("moreItems") or 0)
        bits.append("items: " + "; ".join(items) + (f"; +{more} more" if more else ""))
    if bill.get("total"):
        bits.append(f"bill total {bill['total']}")
    out = "bill: " + ", ".join(bits) if bits else ""
    chosen = bill.get("categoryChosen")
    if chosen:
        out += (" | " if out else "") + f'bill category I chose: "{_clip(chosen)}"'
    return out


BILL_ITEMS = 12


def enrich(rows: list[dict], db_path=None) -> list[dict]:
    """Add what the database knows about each row: the UPI remark, the owner's own note and the
    bill linked to the payment (merchant, time of day, items, the category the owner gave it).
    Read only. A missing or unreadable database leaves the rows as they came."""
    from . import db as _db
    try:
        conn = cashew.open_readonly(db_path or _db.DB_PATH)
    except Exception:
        return rows
    out = []
    try:
        for r in rows:
            r = dict(r)
            tid = r.get("id")
            try:
                t = conn.execute("SELECT t.merchant, a.bank FROM transactions t JOIN accounts a ON a.id = t.account_id "
                                 "WHERE t.id = ?", (tid,)).fetchone()
                if t:
                    remark = cashew.upi_remark(t["merchant"], t["bank"])
                    if remark and not r.get("upi"):
                        r["upi"] = remark
                n = conn.execute("SELECT note FROM txn_notes WHERE transaction_id = ?", (tid,)).fetchone()
                if n and n["note"].strip() and not r.get("userNote"):
                    r["userNote"] = n["note"].strip()
                b = conn.execute(
                    "SELECT r.id, r.merchant, r.platform, r.time, r.total_paise, r.printed_total_paise, r.currency "
                    "FROM receipt_links l JOIN receipts r ON r.id = l.receipt_id "
                    "WHERE l.transaction_id = ? AND l.state = 'linked'", (tid,)).fetchone()
                if b and not r.get("bill"):
                    items = [x[0] for x in conn.execute(
                        "SELECT description FROM receipt_items WHERE receipt_id = ? ORDER BY line_no", (b["id"],))
                        if (x[0] or "").strip()]
                    paise = b["printed_total_paise"] if b["printed_total_paise"] is not None else b["total_paise"]
                    cat = conn.execute("SELECT category, subcategory FROM receipt_categories "
                                       "WHERE receipt_id = ? AND source = 'user'", (b["id"],)).fetchone()
                    r["bill"] = {
                        "merchant": b["merchant"] or "", "platform": b["platform"] or "", "time": b["time"] or "",
                        "items": items[:BILL_ITEMS], "moreItems": max(0, len(items) - BILL_ITEMS),
                        "total": (f"{(paise or 0) / 100:.2f}" if paise else ""),
                        "categoryChosen": (cat["category"] + (f" / {cat['subcategory']}" if cat["subcategory"] else ""))
                                          if cat and cat["category"] else ""}
            except Exception:
                pass                                   # one odd row never stops the batch
            out.append(r)
    finally:
        conn.close()
    return out


def row_line(n: int, row: dict) -> str:
    amount = str(row.get("amount") or "")
    neg = amount.startswith("-")
    size = amount.lstrip("-+")
    parts = [f"{n}. {'DEBIT' if neg else 'CREDIT'} {size}"]
    detailed = bool(row.get("upi") or row.get("userNote") or row.get("bill"))
    # `notes` is those same facts glued into one string for Cashew; once they are
    # given separately it would only repeat them.
    for key, label in (("title", "title"), ("merchant", "merchant text"),
                       ("upi", "UPI remark"), ("userNote", "my note")) + (() if detailed else (("notes", "notes"),)):
        val = _clip(row.get(key))
        if val:
            parts.append(f'{label}: "{val}"')
    bill = bill_text(row.get("bill"))
    if bill:
        parts.append(bill)
    acct = " ".join(x for x in (_clip(row.get("bank")), _clip(row.get("accountType"))) if x)
    if acct:
        parts.append(f"account: {acct}")
    return " | ".join(parts)


def taught_lines(taught: dict | None) -> str:
    out = []
    for key, v in list((taught or {}).items())[:TAUGHT_MAX]:
        if isinstance(v, dict) and v.get("category"):
            sub = v.get("subcategory") or ""
            out.append(f'"{_clip(key)}" -> {v["category"]}' + (f" / {sub}" if sub else ""))
    return "\n".join(out)


def build_prompt(rows: list[dict], categories: list[dict], taught: dict | None = None) -> str:
    """One prompt for one batch of rows."""
    parts = [SYSTEM, "", "Money out (category: subcategories):", category_lines(categories, True),
             "", "Money in (category: subcategories):", category_lines(categories, False)]
    shots = taught_lines(taught)
    if shots:
        parts += ["", "Examples the user already confirmed:", shots]
    parts += ["", "Rows:"] + [row_line(i + 1, r) for i, r in enumerate(rows)]
    parts += ["", 'Reply with JSON only: {"results":[{"i":<row number>,"category":"...","subcategory":"..."}]}',
              'One result for each row. Example for a money-out row with merchant text '
              '"SWIGGY BANGALORE": {"results":[{"i":1,"category":"Food Out","subcategory":"Lunch"}]} '
              '- note "category" is a real name from the lists above, never "Money out"/"Money in".']
    return "\n".join(parts)


# -------------------------------------------------------------- validation

def validate(row: dict, category, subcategory, categories: list[dict]) -> tuple[str, str]:
    """(category, subcategory) when usable, else ("", "")."""
    cat = str(category or "").strip()
    sub = str(subcategory or "").strip()
    by_name = {c["name"]: c for c in categories}
    if cat not in by_name or cat in cashew.UNCATEGORIZED:
        return "", ""
    negative = str(row.get("amount") or "").startswith("-")
    if cat == cashew.FRIEND and not negative:
        sub = cashew.FRIEND_SUB          # the one credit form of Friend Settlement
    if not (cashew._fits(by_name[cat]["type"], negative) or cashew._friend_fits(cat, sub, negative)):
        return "", ""
    if sub and sub not in (by_name[cat].get("subcategories") or []):
        sub = ""
    return cat, sub


def parse_results(text: str, rows: list[dict], categories: list[dict]) -> list[dict]:
    """One {"id","category","subcategory"} per row; raises GuessError on an unreadable reply."""
    data = extract_json(text)
    items = data.get("results") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise GuessError("the model reply has no results list")
    by_i: dict[int, dict] = {}
    for it in items:
        if isinstance(it, dict):
            try:
                by_i[int(it.get("i"))] = it
            except (TypeError, ValueError):
                continue
    if not by_i:
        raise GuessError("the model reply has no usable rows")
    out = []
    for n, row in enumerate(rows, 1):
        it = by_i.get(n) or {}
        cat, sub = validate(row, it.get("category"), it.get("subcategory"), categories)
        out.append({"id": row.get("id"), "category": cat, "subcategory": sub})
    return out


# ------------------------------------------------------------------ ollama

PROGRESS_EVERY = 2.0      # seconds between progress lines while a batch is running
CAPPED_NUM_PREDICT = 6000  # budget of the retry that follows a reply cut off while thinking


class Capped(GuessError):
    """The reply ended at the token budget with no answer: thinking used it all."""


def generate(url: str, model: str, prompt: str, timeout: float, num_predict: int = DEFAULT_NUM_PREDICT,
             on_progress=None) -> str:
    """Streams /api/generate. While it runs, `on_progress(phase, tokens, elapsed)` is called
    about every PROGRESS_EVERY seconds, phase "thinking" until the answer starts."""
    payload = {"model": model, "prompt": prompt, "format": "json", "stream": True,
              "options": {"temperature": 0, "num_predict": num_predict}}
    if _thinks(url, model):
        payload["think"] = True
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url.rstrip("/") + "/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    started = last = time.monotonic()
    answer, tokens, done_reason = [], 0, ""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                raw = raw.strip()
                if not raw:
                    continue
                chunk = json.loads(raw.decode("utf-8"))
                if chunk.get("response"):
                    answer.append(chunk["response"])
                tokens += 1 if (chunk.get("response") or chunk.get("thinking")) else 0
                if chunk.get("done"):
                    done_reason = chunk.get("done_reason") or ""
                    tokens = chunk.get("eval_count") or tokens
                now = time.monotonic()
                if on_progress and now - last >= PROGRESS_EVERY:
                    last = now
                    on_progress("answer" if answer else "thinking", tokens, now - started)
    except urllib.error.HTTPError as e:
        if e.code in (404, 400):
            raise RuntimeError(f"Ollama refused the request ({e.code}); is the model {model!r} installed?")
        raise GuessError(f"Ollama answered HTTP {e.code}")
    except (TimeoutError, OSError, ValueError) as e:      # includes socket.timeout, URLError
        raise GuessError(f"Ollama call failed: {e}")
    text = "".join(answer)
    if not text.strip() and done_reason == "length":
        raise Capped(f"the model used all {num_predict} tokens thinking and gave no answer")
    return text


def reachable(url: str, timeout: float = 5) -> bool:
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/api/tags", timeout=timeout):
            return True
    except urllib.error.HTTPError:
        return True
    except (OSError, ValueError):
        return False


def guess_batch(rows: list[dict], categories: list[dict], taught: dict | None, url: str,
                model: str, timeout: float, on_progress=None) -> list[dict]:
    """One batch. A timeout or an unreadable reply gets one retry. A reply cut off while thinking
    is never retried as it was (same request, same result): the batch is split in two and each
    half gets a bigger budget."""
    prompt = build_prompt(rows, categories, taught)
    last: Exception | None = None
    for _ in range(2):
        try:
            return parse_results(generate(url, model, prompt, timeout, on_progress=on_progress), rows, categories)
        except Capped as e:
            last = e
            break
        except GuessError as e:
            last = e
    if isinstance(last, Capped):
        half = max(1, (len(rows) + 1) // 2)
        parts = [rows[:half], rows[half:]] if len(rows) > 1 else [rows]
        out: list[dict] = []
        for part in parts:
            if not part:
                continue
            part_prompt = build_prompt(part, categories, taught)
            try:
                out += parse_results(generate(url, model, part_prompt, timeout, CAPPED_NUM_PREDICT, on_progress),
                                     part, categories)
            except GuessError:
                out += [{"id": r.get("id"), "category": "", "subcategory": ""} for r in part]
        return out
    raise GuessError(str(last))


# --------------------------------------------------------------------- run

def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _log_run(entry: dict) -> None:
    """One JSON line per run, so a slow or empty run can be explained later. Never fails a run."""
    try:
        path = os.path.join(os.environ.get("HOME", "."), ".local", "state", "omarchy", "transactions-guess-runs.jsonl")
        if os.environ.get("TXDB_NO_RUN_LOG"):
            return
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _die(*_a) -> None:
    os._exit(143)            # SIGTERM: no waiting for threads that sit in a socket read


def run(payload: dict, model: str = DEFAULT_MODEL, workers: int = DEFAULT_WORKERS,
        batch: int = DEFAULT_BATCH, url: str = DEFAULT_URL, timeout: float = DEFAULT_TIMEOUT) -> int:
    rows = [r for r in (payload.get("rows") or []) if isinstance(r, dict) and r.get("id") is not None]
    taught = payload.get("taught") if isinstance(payload.get("taught"), dict) else {}
    rows = enrich(rows)
    total = len(rows)
    started = time.monotonic()
    categories = cashew.load_categories()
    if total and not reachable(url):
        _emit({"error": f"Ollama is not reachable at {url}"})
        return 0
    batches = [rows[i:i + batch] for i in range(0, total, max(1, batch))]
    done = 0
    answered = 0
    batch_seconds: list[float] = []
    if batches:
        pool = ThreadPoolExecutor(max_workers=max(1, workers))
        counter = {"n": 0}

        def work(b):
            counter["n"] += 1
            number = counter["n"]
            batch_started = time.monotonic()
            _emit({"progress": {"batch": number, "of": len(batches), "phase": "reading prompt", "tokens": 0, "elapsed": 0}})

            def progress(phase, tokens, elapsed):
                _emit({"progress": {"batch": number, "of": len(batches), "phase": phase, "tokens": tokens,
                                    "elapsed": round(elapsed)}})
            try:
                return guess_batch(b, categories, taught, url, model, timeout, progress)
            finally:
                batch_seconds.append(round(time.monotonic() - batch_started, 1))
        futures = {pool.submit(work, b): b for b in batches}
        for fut in as_completed(futures):
            b = futures[fut]
            try:
                results = fut.result()
            except Exception as e:                          # GuessError or RuntimeError
                _emit({"error": str(e)})
                results = [{"id": r.get("id"), "category": "", "subcategory": ""} for r in b]
            done += len(b)
            answered += sum(1 for r in results if r.get("category"))
            _emit({"results": results, "done": done, "total": total})
        pool.shutdown(wait=False)
    seconds = round(time.monotonic() - started, 2)
    _emit({"finished": True, "done": done, "total": total, "seconds": seconds, "model": model,
           "answered": answered})
    _log_run({"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "model": model, "rows": total, "batches": len(batches),
              "answered": answered, "seconds": seconds, "batch_seconds": batch_seconds if batches else []})
    return 0


def main(args: list[str]) -> int:
    opts = {"--model": DEFAULT_MODEL, "--workers": DEFAULT_WORKERS, "--batch": DEFAULT_BATCH,
            "--url": DEFAULT_URL, "--timeout": DEFAULT_TIMEOUT}
    src = "-"
    i = 0
    try:
        while i < len(args):
            a = args[i]
            if a in opts:
                kind = type(opts[a])
                opts[a] = kind(args[i + 1])
                i += 2
            else:
                src = a
                i += 1
        if src == "-":
            # one line is enough (the widget keeps the pipe open); a pretty-printed file reads on to the end
            raw = sys.stdin.readline()
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = json.loads(raw + sys.stdin.read())
        else:
            payload = json.loads(open(src, encoding="utf-8").read())
        if not isinstance(payload, dict):
            raise ValueError("the input must be a JSON object")
    except (ValueError, IndexError, OSError) as e:
        print(f"cashew-guess: invalid input: {e}", file=sys.stderr)
        return 2
    signal.signal(signal.SIGTERM, _die)
    try:
        return run(payload, opts["--model"], opts["--workers"], opts["--batch"], opts["--url"], opts["--timeout"])
    except BrokenPipeError:
        os._exit(0)
