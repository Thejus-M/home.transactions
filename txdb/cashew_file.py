"""Write the selected rows straight into a copy of the Cashew database, for Cashew's own import.

No browser window and no link: the file is the Cashew web database (the version Zen uses now, see
cashew_twins.find_browser_copy) plus the rows that are missing, and the person imports it in Cashew
(Settings > Backup > Import). Rows Cashew already has are not added (cashew_dedupe, checked again against the
same copy). A transfer pair is written the way Cashew's own transfer page writes it: two Balance Correction
rows (category "0"), the incoming one 1 s after the outgoing one, the outgoing one pointing to it
(paired_transaction_fk), note "Transferred Balance\\n<from> → <to>". A row whose category or account Cashew
does not know is skipped and listed, never written half.

The file replaces the whole Cashew database when imported: import it right away, in the only open Cashew tab,
and do not change anything in Cashew between making the file and importing it.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import time
import uuid
from datetime import datetime
from pathlib import Path

from . import cashew_dedupe
from .cashew_fix import Index

BALANCE_PK = "0"


def _midnight(iso: str) -> int:
    """Cashew keeps a day as the epoch second of local midnight."""
    return int(datetime.strptime(iso, "%Y-%m-%d").timestamp())


def _pairs(drafts: list[dict]) -> tuple[list[tuple[dict, dict]], list[dict]]:
    """(transfer pairs (out, in) with both legs selected, every other selected draft)."""
    by_pair: dict[str, list[dict]] = {}
    for d in drafts:
        if d.get("kind") == "transfer" and d.get("pairId"):
            by_pair.setdefault(d["pairId"], []).append(d)
    pairs, used = [], set()
    for legs in by_pair.values():
        outs = [d for d in legs if str(d.get("amount") or "").startswith("-")]
        ins = [d for d in legs if not str(d.get("amount") or "").startswith("-")]
        if len(legs) == 2 and len(outs) == 1 and len(ins) == 1:
            pairs.append((outs[0], ins[0]))
            used.update((id(outs[0]), id(ins[0])))
    return pairs, [d for d in drafts if id(d) not in used]


def build(base: Path | str, out: Path | str, drafts: list[dict], dry_run: bool = False) -> dict:
    """Copy `base` to `out` and add the selected drafts Cashew does not have yet.
    Returns {path, base, added, rows, transfers, already, skipped: [{id, title, reason}], ids, dryRun}."""
    out = Path(out)
    tmp = out.with_name(out.name + ".tmp")
    shutil.copyfile(base, tmp)
    try:
        conn = sqlite3.connect(tmp)
        conn.row_factory = sqlite3.Row
        base_count = conn.execute("SELECT count(*) FROM transactions").fetchone()[0]
        idx = Index(conn)
        chosen = [dict(d) for d in drafts if d.get("include", True) and not d.get("inCashew")]
        already = cashew_dedupe.mark(chosen, conn)["found"]          # the window's view can be minutes old
        chosen = [d for d in chosen if not d.get("inCashew")]
        template = conn.execute("SELECT * FROM transactions WHERE method_added = 4 ORDER BY date_time_modified DESC LIMIT 1"
                                ).fetchone() or conn.execute("SELECT * FROM transactions LIMIT 1").fetchone()
        if template is None:
            raise ValueError("the Cashew database has no transaction to copy the column layout from")
        cols = list(template.keys())
        now = int(time.time())
        skipped, ids, rows_added, transfers = [], [], 0, 0

        def insert(**values):
            row = {c: template[c] for c in cols}
            row.update(date_time_modified=now, paid=1, skip_paid=0, period_length=None, reoccurrence=None,
                       end_date=None, objective_fk=None, objective_loan_fk=None, budget_fks_exclude=None,
                       shared_key=None, shared_old_key=None, shared_status=None, shared_date_updated=None,
                       shared_reference_budget_pk=None)
            row.update(values)
            conn.execute(f"INSERT INTO transactions ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
                         [row.get(c) for c in cols])

        def wallet(d):
            return idx.wallets.get(str(d.get("account") or ""))

        pairs, singles = _pairs(chosen)
        for o, i in pairs:
            wo, wi = wallet(o), wallet(i)
            if wo is None or wi is None:
                for d, w in ((o, wo), (i, wi)):
                    skipped.append({"id": d.get("id"), "title": d.get("title"),
                                    "reason": "" if w is not None else f"Cashew has no account '{d.get('account')}'"})
                continue
            title = str(o.get("title") or "Transfer")
            note = "Transferred Balance\n" + title
            in_pk = str(uuid.uuid4())
            day = _midnight(str(o.get("date")))
            insert(transaction_pk=in_pk, paired_transaction_fk=None, name=title, amount=round(float(i["amount"]), 2),
                   note=note, category_fk=BALANCE_PK, sub_category_fk=None, wallet_fk=wi,
                   date_created=_midnight(str(i.get("date"))) + 1, income=1, method_added=None)
            insert(transaction_pk=str(uuid.uuid4()), paired_transaction_fk=in_pk, name=title,
                   amount=round(float(o["amount"]), 2), note=note, category_fk=BALANCE_PK, sub_category_fk=None,
                   wallet_fk=wo, date_created=day, income=0, method_added=None)
            transfers += 1
            rows_added += 2
            ids += [o.get("id"), i.get("id")]
        for d in singles:
            w = wallet(d)
            amount = round(float(d.get("amount") or 0), 2)
            if d.get("kind") == "transfer":
                cat_pk, sub_pk = BALANCE_PK, None
            else:
                got = idx.category(str(d.get("category") or ""), str(d.get("subcategory") or ""))
                if got is None:
                    skipped.append({"id": d.get("id"), "title": d.get("title"),
                                    "reason": f"Cashew has no category '{d.get('category')}'"})
                    continue
                cat_pk, sub_pk = got[0], (got[1] or None)
            if w is None:
                skipped.append({"id": d.get("id"), "title": d.get("title"), "reason": f"Cashew has no account '{d.get('account')}'"})
                continue
            insert(transaction_pk=str(uuid.uuid4()), paired_transaction_fk=None, name=str(d.get("title") or ""),
                   amount=amount, note=str(d.get("notes") or ""), category_fk=cat_pk, sub_category_fk=sub_pk,
                   wallet_fk=w, date_created=_midnight(str(d.get("date"))), income=1 if amount > 0 else 0,
                   method_added=template["method_added"])
            rows_added += 1
            ids.append(d.get("id"))
        skipped = [s for s in skipped if s["reason"]]
        conn.commit()
        if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("the new database failed its integrity check; nothing was written")
        conn.close()
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    result = {"path": "" if dry_run else str(out), "base": base_count, "added": rows_added, "transfers": transfers,
              "already": already, "skipped": skipped, "ids": ids, "dryRun": dry_run}
    if dry_run or rows_added == 0:
        tmp.unlink(missing_ok=True)
        result["path"] = ""
        return result
    os.replace(tmp, out)
    os.chmod(out, 0o600)
    return result


def default_dir() -> Path:
    """Where the files go: TXDB_CASHEW_IMPORT_DIR, else the external drive (Backup/cashew-import)."""
    env = os.environ.get("TXDB_CASHEW_IMPORT_DIR")
    if env:
        return Path(env)
    drive = Path("/run/media/pc/MY Drive")
    if not os.path.ismount(drive):
        raise ValueError("the external drive is not mounted (/run/media/pc/MY Drive)")
    return drive / "Backup" / "cashew-import"
