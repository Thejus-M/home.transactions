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
    home = home or Path.home()
    found = []
    for pattern in (".config/*/*/storage/default/https+++budget-track.web.app/idb/*.files/*",
                    ".mozilla/firefox/*/storage/default/https+++budget-track.web.app/idb/*.files/*"):
        found += [p for p in home.glob(pattern) if p.is_file() and p.stat().st_size > 4096]
    for path in sorted(found, key=lambda p: p.stat().st_mtime, reverse=True):
        copy = Path(tempfile.mkdtemp(prefix="cashew-web-")) / "cashew.sqlite"
        shutil.copyfile(path, copy)
        try:
            with open(copy, "rb") as fh:
                if not fh.read(16).startswith(b"SQLite format 3"):
                    continue
            conn = sqlite3.connect(f"{copy.as_uri()}?mode=ro", uri=True)
            ok = conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'categories'").fetchone()
            conn.close()
        except (sqlite3.Error, OSError):
            continue
        if ok:
            return copy
    return None


def lookup(twins: dict, category: str, subcategory: str) -> tuple[str, str] | None:
    """(categoryPk, subcategoryPk) of the income twin of an expense category, or None when there is none.
    subcategoryPk is "" when the twin has no sub-category of that name."""
    t = twins.get(category)
    if not t:
        return None
    return t["pk"], (t["subs"].get(subcategory, "") if subcategory else "")
