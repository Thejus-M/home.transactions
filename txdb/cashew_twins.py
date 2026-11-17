"""Income twins of the expense categories, so a refund can be income in "the same category". NOT NEEDED any
more: links carry categoryPolarity=false (txdb/cashew.py), so a refund is income in the real category and
txdb/cashew.py no longer looks a twin up. `find_browser_copy` and `read_backup` are still used by cashew-fix.

History: by default (categoryPolarity=true) Cashew (6.7.2) takes income or expense ONLY from a category's type and ignores the sign in a link (tested on
screen, 2026-11-15). A refund therefore cannot be income under the expense category "Shopping". What Cashew can
do is hold a second category named "Shopping" whose type is INCOME (with the same icon and colour). The refund
goes there, by the twin's id (categoryPk / subcategoryPk in the link: a name would find the expense one).

The ids are read from a Cashew backup (Settings > Backup > export): the `categories` table has category_pk, name,
income (0/1) and main_category_pk. They are saved to ~/.local/state/omarchy/transactions-cashew-twins.json:
    {"Shopping": {"pk": "<id>", "subs": {"Footwear": "<id>"}}}
`txdb cashew-twins` lists which twins the linked refunds need; `--backup FILE` reads the ids.
"""
from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path


def default_path() -> Path:
    env = os.environ.get("TXDB_CASHEW_TWINS")
    return Path(env) if env else Path.home() / ".local" / "state" / "omarchy" / "transactions-cashew-twins.json"


def load(path: Path | str | None = None) -> dict:
    """{category name: {"pk": id, "subs": {sub name: id}}}; {} when nothing was imported."""
    try:
        data = json.loads(Path(path or default_path()).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out = {}
    for name, t in (data.items() if isinstance(data, dict) else []):
        if isinstance(t, dict) and isinstance(t.get("pk"), str) and t["pk"]:
            subs = {k: v for k, v in (t.get("subs") or {}).items() if isinstance(k, str) and isinstance(v, str) and v}
            out[name] = {"pk": t["pk"], "subs": subs}
    return out


def save(twins: dict, path: Path | str | None = None) -> Path:
    target = Path(path or default_path())
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".tmp")
    tmp.write_text(json.dumps(twins, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(target)
    return target


def read_backup(file: Path | str) -> dict:
    """The income categories of a Cashew backup (a sqlite file) with their sub-categories.
    Raises ValueError when the file is not a Cashew backup."""
    try:
        conn = sqlite3.connect(f"{Path(file).resolve().as_uri()}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT category_pk, name, income, main_category_pk FROM categories").fetchall()
        conn.close()
    except (sqlite3.Error, OSError) as e:
        raise ValueError(f"not a Cashew backup: {e}") from e
    income_mains = {r["category_pk"]: r["name"] for r in rows if r["income"] and not r["main_category_pk"]}
    twins: dict[str, dict] = {}
    for pk, name in income_mains.items():
        twins.setdefault(name, {"pk": pk, "subs": {}})
    for r in rows:
        parent = r["main_category_pk"]
        if parent in income_mains:
            twins[income_mains[parent]]["subs"][r["name"]] = r["category_pk"]
    return twins


def find_browser_copy(home: Path | None = None) -> Path | None:
    """A copy of the Cashew web app's database that the browser keeps for https://budget-track.web.app (an
    IndexedDB blob that is the sqlite file itself). The newest one that has a categories table, or None.
    Read only: the file is copied to a temp folder first and the browser's own file is never opened."""
    import shutil
    import tempfile

    if home is None and os.environ.get("TXDB_NO_BROWSER_COPY"):
        return None                       # tests and scripts switch the lookup off
    if home is None:
        # the option chromiumSync: Cashew lives in its own Chromium profile; the last database read from it
        from . import cashew, cashew_chromium
        on = os.environ.get("TXDB_CASHEW_CHROMIUM") == "1" or cashew.load_state().get("chromiumSync") is True
        if on and cashew_chromium.MIRROR.exists():
            folder = tempfile.mkdtemp(prefix="cashew-web-")
            import atexit
            atexit.register(shutil.rmtree, folder, True)
            copy = Path(folder) / "cashew.sqlite"
            shutil.copyfile(cashew_chromium.MIRROR, copy)
            return copy
    for path in _browser_blobs(home):
        # One temp folder per process, removed when the process ends (each run used to leave a 1.8 MB
        # copy in /tmp, which is held in memory).
        folder = tempfile.mkdtemp(prefix="cashew-web-")
        import atexit
        atexit.register(shutil.rmtree, folder, True)
        copy = Path(folder) / "cashew.sqlite"
        try:
            shutil.copyfile(path, copy)
        except OSError:
            continue
        if _is_cashew_db(copy):
            return copy
    return None


def _pointed_blobs(home: Path) -> list[Path]:
    """The blob(s) the IndexedDB index of the Cashew web app points to now (object_data.file_ids of the
    moor_databases store). Old blobs stay on disk for a while, and the newest file is not always the one in
    use: when two Cashew tabs closed 39 ms apart, the older database was written last and won."""
    import shutil
    import tempfile
    out = []
    for pattern in (".config/*/*/storage/default/https+++budget-track.web.app/idb/*.sqlite",
                    ".mozilla/firefox/*/storage/default/https+++budget-track.web.app/idb/*.sqlite"):
        for index in home.glob(pattern):
            with tempfile.TemporaryDirectory(prefix="cashew-idb-") as tmp:
                try:
                    shutil.copyfile(index, Path(tmp) / "i.sqlite")
                    wal = index.with_name(index.name + "-wal")
                    if wal.exists():
                        shutil.copyfile(wal, Path(tmp) / "i.sqlite-wal")
                    conn = sqlite3.connect(Path(tmp) / "i.sqlite")
                    ids = [r[0] for r in conn.execute(
                        "SELECT d.file_ids FROM object_data d JOIN object_store s ON s.id = d.object_store_id "
                        "WHERE s.name = 'moor_databases' AND d.file_ids IS NOT NULL")]
                    conn.close()
                except (sqlite3.Error, OSError):
                    continue
            folder = index.with_suffix(".files")
            for text in ids:
                for token in str(text).replace(".", " ").split():
                    num = token.lstrip("-")
                    if num.isdigit() and (folder / num).is_file():
                        out.append(folder / num)
    return out


def _browser_blobs(home: Path | None = None) -> list[Path]:
    """The files the browser keeps for the Cashew web app's IndexedDB: the one the index points to first,
    then the others, newest first. TXDB_BROWSER_HOME names another home folder (tests)."""
    home = Path(home or os.environ.get("TXDB_BROWSER_HOME") or Path.home())
    pointed = _pointed_blobs(home)
    found = []
    for pattern in (".config/*/*/storage/default/https+++budget-track.web.app/idb/*.files/*",
                    ".mozilla/firefox/*/storage/default/https+++budget-track.web.app/idb/*.files/*"):
        for p in home.glob(pattern):
            try:
                if p.is_file() and p.stat().st_size > 4096:
                    found.append((p.stat().st_mtime, p))
            except OSError:                # the browser replaced the file while we looked
                continue
    rest = [p for _, p in sorted(found, key=lambda x: x[0], reverse=True) if p not in pointed]
    return pointed + rest


def _is_cashew_db(copy: Path) -> bool:
    try:
        with open(copy, "rb") as fh:
            if not fh.read(16).startswith(b"SQLite format 3"):
                return False
        conn = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
        ok = conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'categories'").fetchone()
        conn.close()
    except (sqlite3.Error, OSError):
        return False
    return bool(ok)


def browser_count(home: Path | None = None) -> int | None:
    """How many transactions the Cashew web app has, read from the copy the browser keeps (see
    find_browser_copy); None when there is no such copy. The browser's file is copied first and never opened;
    the copy is deleted again."""
    import shutil
    import tempfile

    if home is None and os.environ.get("TXDB_NO_BROWSER_COPY"):
        return None
    for path in _browser_blobs(home):
        with tempfile.TemporaryDirectory(prefix="cashew-count-") as tmp:
            copy = Path(tmp) / "cashew.sqlite"
            try:
                shutil.copyfile(path, copy)
            except OSError:
                continue
            if not _is_cashew_db(copy):
                continue
            try:
                conn = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
                n = conn.execute("SELECT count(*) FROM transactions").fetchone()[0]
                conn.close()
            except sqlite3.Error:
                continue
            return int(n)
    return None


def wait_added(expect: int, timeout: float = 60.0, poll: float = 1.0, emit=print, home: Path | None = None) -> int:
    """Wait until the Cashew web app has `expect` more transactions than now. Emits one JSON line when it
    is ready to start ({"ready": true, "base": n}: open the link NOW) and one per change
    ({"added": k, "of": expect}). Returns 0 when all are there, 2 on timeout, 3 when the browser keeps no copy."""
    import time

    base = browser_count(home)
    if base is None:
        return 3
    emit(json.dumps({"ready": True, "base": base}))
    added, end = 0, time.monotonic() + timeout
    while True:
        now = browser_count(home)
        if now is not None and now - base != added:
            added = now - base
            emit(json.dumps({"added": added, "of": expect}))
        if added >= expect:
            return 0
        if time.monotonic() >= end:
            return 2
        time.sleep(poll)


def lookup(twins: dict, category: str, subcategory: str) -> tuple[str, str] | None:
    """(categoryPk, subcategoryPk) of the income twin of an expense category, or None when there is none.
    subcategoryPk is "" when the twin has no sub-category of that name."""
    t = twins.get(category)
    if not t:
        return None
    return t["pk"], (t["subs"].get(subcategory, "") if subcategory else "")
