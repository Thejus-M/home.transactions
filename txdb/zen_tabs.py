"""Which Cashew web tabs are open in Zen, read from Zen's saved session (a copy; the browser's file is never
opened in place).

Cashew web keeps its whole database in every open tab and the last tab to save wins, so "Add all" must not
start while another Cashew tab is open: that tab would overwrite the rows the send adds. Zen writes the session
about every 15 s (sessionstore-backups/recovery.jsonlz4 while it runs, sessionstore.jsonlz4 when it quits), so
a tab closed a moment ago can still be listed. The file says which tabs exist, not which are loaded.
"""
from __future__ import annotations

import json
import os
import shutil
import tempfile
import time
from pathlib import Path

CASHEW = "https://budget-track.web.app"


def lz4_block(src: bytes, size: int) -> bytes:
    """Decompress one LZ4 block (the format inside a mozlz4 file); pure Python, no lz4 module needed."""
    dst = bytearray()
    i, n = 0, len(src)
    while i < n:
        token = src[i]
        i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        dst += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        ml = token & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        start = len(dst) - off
        if off >= ml:
            dst += dst[start:start + ml]
        else:
            for k in range(ml):
                dst.append(dst[start + k])
    return bytes(dst[:size]) if size else bytes(dst)


def read_mozlz4(path: Path | str) -> dict:
    raw = Path(path).read_bytes()
    if raw[:8] != b"mozLz40\0":
        raise ValueError("not a mozlz4 file")
    size = int.from_bytes(raw[8:12], "little")
    return json.loads(lz4_block(raw[12:], size))


def _profiles(home: Path) -> list[Path]:
    """The Zen / Firefox profiles that hold the Cashew web app's storage."""
    out = []
    for pattern in (".config/*/*/storage/default/https+++budget-track.web.app",
                    ".mozilla/firefox/*/storage/default/https+++budget-track.web.app"):
        for p in home.glob(pattern):
            out.append(p.parent.parent.parent)
    return out


def _session_file(profile: Path) -> Path | None:
    files = [p for p in (profile / "sessionstore-backups" / "recovery.jsonlz4", profile / "sessionstore.jsonlz4") if p.is_file()]
    return max(files, key=lambda p: p.stat().st_mtime) if files else None


def open_cashew_tabs(session: dict) -> list[dict]:
    """[{window, tab, url}] for every open tab whose current page is the Cashew web app (closed tabs are not
    counted)."""
    out = []
    for w, win in enumerate(session.get("windows") or []):
        for t, tab in enumerate(win.get("tabs") or []):
            entries = tab.get("entries") or []
            if not entries:
                continue
            idx = min(max(int(tab.get("index") or len(entries)), 1), len(entries)) - 1
            url = str(entries[idx].get("url") or "")
            if url.startswith(CASHEW):
                out.append({"window": w + 1, "tab": t + 1, "url": url[:80]})
    return out


def check(home: Path | None = None) -> dict:
    """{"open": n, "tabs": [...], "session": path, "age": seconds since Zen wrote it} or {"open": -1, "reason"}."""
    home = Path(home or os.environ.get("TXDB_BROWSER_HOME") or Path.home())
    for profile in _profiles(home):
        src = _session_file(profile)
        if src is None:
            continue
        with tempfile.TemporaryDirectory(prefix="zen-session-") as tmp:
            copy = Path(tmp) / "s.jsonlz4"
            shutil.copyfile(src, copy)
            try:
                tabs = open_cashew_tabs(read_mozlz4(copy))
            except (ValueError, OSError, IndexError) as e:
                return {"open": -1, "reason": f"Zen's session could not be read: {e}"}
        return {"open": len(tabs), "tabs": tabs, "session": str(src), "age": round(time.time() - src.stat().st_mtime)}
    return {"open": -1, "reason": "no Zen profile with the Cashew web app"}
