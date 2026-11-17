"""EXPERIMENTAL: put a Cashew database straight into the storage Zen keeps for the Cashew web app.

Only while no Zen process uses that profile: Zen keeps its IndexedDB files open, and an open Cashew tab holds
its own copy of the database and writes it back. Proven on a throwaway profile before any real use.

How Zen (Firefox) keeps it, for the origin https://budget-track.web.app, IndexedDB "moor_databases":
  idb/<name>.sqlite      the index: object_data (key 'db', file_ids '<n>', data = a snappy-compressed
                         structured clone of 32 bytes: a Blob reference whose 8-byte size sits at byte 16),
                         file (id, refcount)
  idb/<name>.files/<n>   the blob: the SQLite file of Cashew itself
A write adds a new blob <max id + 1>, points the record at it with the new size, and moves the refcount.
"""
from __future__ import annotations

import shutil
import sqlite3
from pathlib import Path

SIZE_AT = 16


def _varint(b: bytes, i: int) -> tuple[int, int]:
    r = s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7F) << s
        s += 7
        if x < 0x80:
            return r, i


def snappy_decompress(b: bytes) -> bytes:
    n, i = _varint(b, 0)
    out = bytearray()
    while i < len(b):
        t = b[i]
        i += 1
        kind = t & 3
        if kind == 0:
            ln = t >> 2
            if ln >= 60:
                k = ln - 59
                ln = int.from_bytes(b[i:i + k], "little")
                i += k
            ln += 1
            out += b[i:i + ln]
            i += ln
        else:
            if kind == 1:
                ln, off = ((t >> 2) & 7) + 4, ((t >> 5) << 8) | b[i]
                i += 1
            elif kind == 2:
                ln, off = (t >> 2) + 1, int.from_bytes(b[i:i + 2], "little")
                i += 2
            else:
                ln, off = (t >> 2) + 1, int.from_bytes(b[i:i + 4], "little")
                i += 4
            for _ in range(ln):
                out.append(out[-off])
    if len(out) != n:
        raise ValueError("bad snappy data")
    return bytes(out)


def snappy_literal(raw: bytes) -> bytes:
    """`raw` as one snappy literal (valid snappy, no compression; fine for 32 bytes)."""
    n = len(raw)
    head = bytearray()
    v = n
    while True:
        b = v & 0x7F
        v >>= 7
        head.append(b | (0x80 if v else 0))
        if not v:
            break
    if n <= 60:
        return bytes(head) + bytes([(n - 1) << 2]) + raw
    return bytes(head) + bytes([60 << 2, n - 1]) + raw      # up to 256 bytes


def index_files(storage: Path) -> tuple[Path, Path]:
    """(index .sqlite, blob folder) of the Cashew web app's IndexedDB inside an origin storage folder."""
    for index in sorted((storage / "idb").glob("*.sqlite")):
        conn = sqlite3.connect(index)
        try:
            ok = conn.execute("SELECT 1 FROM object_store WHERE name = 'moor_databases'").fetchone()
        finally:
            conn.close()
        if ok:
            return index, index.with_suffix(".files")
    raise ValueError("no moor_databases IndexedDB in " + str(storage))


def current(storage: Path) -> tuple[Path, int]:
    """(the blob in use, the size the record says)."""
    index, folder = index_files(storage)
    conn = sqlite3.connect(index)
    try:
        fid, data = conn.execute("SELECT file_ids, data FROM object_data").fetchone()
    finally:
        conn.close()
    raw = snappy_decompress(bytes(data))
    return folder / str(int(str(fid).strip())), int.from_bytes(raw[SIZE_AT:SIZE_AT + 8], "little")


def write(storage: Path, new_db: Path) -> Path:
    """Put the SQLite file `new_db` in as the Cashew database. Returns the new blob path."""
    index, folder = index_files(storage)
    data_bytes = Path(new_db).read_bytes()
    conn = sqlite3.connect(index)
    # Firefox's triggers call update_refcount (its own C++ function); the file table is kept by hand below.
    conn.create_function("update_refcount", 2, lambda old, new: None)
    try:
        (fid, data), = conn.execute("SELECT file_ids, data FROM object_data").fetchall()
        old_id = int(str(fid).strip())
        raw = bytearray(snappy_decompress(bytes(data)))
        if int.from_bytes(raw[SIZE_AT:SIZE_AT + 8], "little") != (folder / str(old_id)).stat().st_size:
            raise ValueError("the record's size does not match its blob: unknown layout, nothing written")
        raw[SIZE_AT:SIZE_AT + 8] = len(data_bytes).to_bytes(8, "little")
        new_id = max(r[0] for r in conn.execute("SELECT id FROM file")) + 1
        blob = folder / str(new_id)
        blob.write_bytes(data_bytes)
        with conn:
            conn.execute("INSERT INTO file (id, refcount) VALUES (?, 1)", (new_id,))
            conn.execute("UPDATE object_data SET file_ids = ?, data = ?", (str(new_id), snappy_literal(bytes(raw))))
            conn.execute("DELETE FROM file WHERE id = ?", (old_id,))
    finally:
        conn.close()
    return blob


def storages(home: Path | None = None) -> list[Path]:
    """The origin folders (https+++budget-track.web.app) of the Zen / Firefox profiles."""
    import os
    home = Path(home or os.environ.get("TXDB_BROWSER_HOME") or Path.home())
    out = []
    for pattern in (".config/*/*/storage/default/https+++budget-track.web.app",
                    ".mozilla/firefox/*/storage/default/https+++budget-track.web.app"):
        out += [p for p in home.glob(pattern) if (p / "idb").is_dir()]
    return out


def profile_lock_pid(storage: Path) -> int | None:
    """The PID in the profile's `lock` link ("<ip>:+<pid>", made by a running Zen / Firefox) when that process
    is alive; None when there is no lock or it is stale (a crash)."""
    import os
    lock = storage.parent.parent.parent / "lock"
    try:
        target = os.readlink(lock)
    except OSError:
        return None
    try:
        pid = int(target.rsplit("+", 1)[1])
    except (IndexError, ValueError):
        return -1                                 # a lock we cannot read: treat as in use
    return pid if Path(f"/proc/{pid}").exists() else None


def in_use(storage: Path) -> list[int]:
    """PIDs that keep this profile busy: the running Zen from the profile lock (it may not have the Cashew
    storage open right now, but it caches it), and any process with a file of this IndexedDB open."""
    import os
    idb = str((storage / "idb").resolve())
    lock_pid = profile_lock_pid(storage)
    pids = [lock_pid] if lock_pid is not None else []
    me = os.getpid()
    for proc in Path("/proc").glob("[0-9]*"):
        if proc.name == str(me):
            continue                              # this script itself is never Zen
        try:
            for fd in (proc / "fd").iterdir():
                try:
                    if os.readlink(fd).startswith(idb):
                        pids.append(int(proc.name))
                        break
                except OSError:
                    continue
        except OSError:
            continue
    return pids


def apply(storage: Path, drafts: list[dict], backup_root: Path, dry_run: bool = False) -> dict:
    """Write the ready drafts Cashew does not have straight into `storage` (Zen must be closed).
    Backs up the index (+ WAL) and the current blob to backup_root/<time>/ first. Returns
    {written, transfers, already, skipped, ids, backup, base} or raises ValueError."""
    import shutil as _sh
    import time as _t
    from . import cashew_file
    pids = in_use(storage)
    if pids:
        raise ValueError(f"Zen is running (pid {pids[0]}): Cashew's storage is in use")
    index, folder = index_files(storage)
    blob, size = current(storage)
    if blob.stat().st_size != size:
        raise ValueError("the record's size does not match its blob: unknown layout, nothing written")
    import tempfile as _tf
    with _tf.TemporaryDirectory(prefix="cashew-direct-") as tmp:
        base = Path(tmp) / "base.sqlite"
        _sh.copyfile(blob, base)
        new = Path(tmp) / "new.sqlite"
        r = cashew_file.build(base, new, drafts, dry_run=dry_run)
        result = {"written": 0, "would": r["added"], "transfers": r["transfers"], "already": r["already"],
                  "skipped": r["skipped"], "ids": r["ids"], "base": r["base"], "backup": ""}
        if dry_run or r["added"] == 0:
            return result                             # nothing to write: no backup, nothing kept
        # a backup only right before a real write: the index, its WAL and the database in use
        work = backup_root / _t.strftime("%Y%m%d-%H%M%S")
        work.mkdir(parents=True, exist_ok=True)
        _sh.copyfile(blob, work / ("db-" + blob.name + ".sqlite"))
        for f in (index, index.with_name(index.name + "-wal")):
            if f.exists():
                _sh.copyfile(f, work / f.name)
        result["backup"] = str(work)
        result["written"] = r["added"]
        return _finish(storage, new, blob, work, result)


def _finish(storage: Path, new: Path, blob: Path, work: Path, result: dict) -> dict:
    if in_use(storage):                                      # Zen started meanwhile: do not touch it
        raise ValueError("Zen started while the file was made: nothing written")
    new_blob = write(storage, new)
    check_blob, check_size = current(storage)
    if check_blob != new_blob or check_size != new_blob.stat().st_size:
        raise ValueError("the write could not be checked; restore from " + str(work))
    blob.unlink(missing_ok=True)                             # the old database is in the backup
    return result

