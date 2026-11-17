"""Write straight into the Cashew web app kept in a separate Chromium profile (background only).

Cashew web (moor/drift) keeps its whole SQLite database as one Blob in IndexedDB:
database "moor_databases", object store "moor_databases", key "db". Chromium owns the IndexedDB files
(LevelDB), so this module never touches them on disk. It starts Chromium headless on the profile with
--remote-debugging-pipe (no network port), intercepts https://budget-track.web.app/ and serves an empty
page on that origin, so the Cashew app does not start and cannot overwrite the database meanwhile. In that
page JavaScript reads or writes the Blob.

push(): read the Blob, back it up, build the new database (cashew_file.build, the same builder as the sync
file), check it, write it back in one IndexedDB transaction, read it again and compare. Only after a write
that worked, load the real Cashew page headless for a while, so Cashew starts on the new data and can run
its own sync / Google Drive backup. Nothing changed: the browser is not opened.

Refuses while a Chromium window uses the profile (its SingletonLock), and holds a lock file of its own.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path

ORIGIN = "https://budget-track.web.app/"
HIDDEN_CLASS = "cashew-edge"
PROFILE = Path(os.environ.get("TXDB_CASHEW_CHROMIUM_PROFILE") or Path.home() / ".local" / "share" / "cashew-chromium")
STATE = Path.home() / ".local" / "state" / "omarchy"
MIRROR = STATE / "cashew-chromium.sqlite"        # the last database read from / written to Chromium
LOCK = STATE / "cashew-chromium.lock"
KEEP_BACKUPS = 30
OPEN_COMMAND = f'chromium --user-data-dir="{PROFILE}" --no-first-run {ORIGIN}'

_READ_JS = r"""(async () => {
 const db = await new Promise((res, rej) => { const r = indexedDB.open('moor_databases');
   r.onupgradeneeded = () => { r.transaction.abort(); rej(new Error('no Cashew database in this profile')); };
   r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
 if (![...db.objectStoreNames].includes('moor_databases')) { db.close(); throw new Error('unknown layout: no store moor_databases'); }
 const v = await new Promise((res, rej) => { const q = db.transaction('moor_databases').objectStore('moor_databases').get('db');
   q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error); });
 db.close();
 if (!(v instanceof Blob)) throw new Error('unknown layout: the value of key db is not a Blob');
 const b = new Uint8Array(await v.arrayBuffer()); let s = '';
 for (let i = 0; i < b.length; i += 32768) s += String.fromCharCode.apply(null, b.subarray(i, i + 32768));
 return btoa(s); })()"""

_WRITE_JS = r"""(async (b64) => {
 const s = atob(b64); const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i);
 const db = await new Promise((res, rej) => { const r = indexedDB.open('moor_databases');
   r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
 await new Promise((res, rej) => { const tx = db.transaction('moor_databases', 'readwrite');
   tx.objectStore('moor_databases').put(new Blob([b]), 'db'); tx.oncomplete = res; tx.onerror = () => rej(tx.error); tx.onabort = () => rej(tx.error); });
 db.close(); return b.length; })"""


class Chromium:
    """A headless Chromium on `profile`, driven over --remote-debugging-pipe (fd 3 in, fd 4 out)."""

    def __init__(self, profile: Path, block_app: bool = True, visible: bool = False, hidden: bool = False):
        r1, w1 = os.pipe()
        r2, w2 = os.pipe()

        def child():
            os.dup2(r1, 3)
            os.dup2(w2, 4)
        mode = ["--disable-popup-blocking"] if visible or hidden else ["--headless=new"]
        if hidden:
            # a normal window, out of sight: Hyprland puts this class on a special workspace, silently
            # out of sight but still "visible" to the page (a hidden workspace or a tiny window stops Flutter's
            # frames): full size, pushed off the bottom-right edge (4 px left on screen), almost fully
            # transparent, pinned, never focused. The Google popup has the same class, so it goes there too.
            subprocess.run(["hyprctl", "eval", 'hl.window_rule({ match = { class = "%s" }, float = true, pin = true, '
                            'size = { 580, 900 }, move = { "(monitor_w-4)", "(monitor_h-4)" }, '
                            'opacity = "0.01 override 0.01 override", no_focus = true, no_initial_focus = true, '
                            'no_anim = true, no_shadow = true, no_border = true, border_size = 0 })'
                            % HIDDEN_CLASS], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            mode += [f"--class={HIDDEN_CLASS}", "--disable-backgrounding-occluded-windows",
                     "--disable-renderer-backgrounding", "--disable-background-timer-throttling"]   # draw although unseen
            visible = True
        self.proc = subprocess.Popen(
            ["chromium", *mode, f"--user-data-dir={profile}", "--remote-debugging-pipe", "--no-first-run",
             "--no-default-browser-check", "about:blank"],
            pass_fds=(3, 4), preexec_fn=child, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(r1)
        os.close(w2)
        self._out, self._in = w1, r2
        self._buf, self._n, self.events = b"", 0, []
        pages = [t for t in self.call("Target.getTargets")["targetInfos"] if t["type"] == "page"]
        target = pages[0]["targetId"] if visible and pages else self.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        self.sid = self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        self.block_app = block_app

    def _send(self, method, params=None, sid=None) -> int:
        self._n += 1
        m = {"id": self._n, "method": method, "params": params or {}}
        if sid:
            m["sessionId"] = sid
        os.write(self._out, json.dumps(m).encode() + b"\0")
        return self._n

    def _recv(self, deadline: float) -> dict:
        while b"\0" not in self._buf:
            if time.time() > deadline:
                raise TimeoutError("Chromium did not answer")
            import select
            ready, _, _ = select.select([self._in], [], [], max(0.0, deadline - time.time()))
            if not ready:
                continue
            chunk = os.read(self._in, 1 << 20)
            if not chunk:
                raise RuntimeError("Chromium closed")
            self._buf += chunk
        msg, self._buf = self._buf.split(b"\0", 1)
        return json.loads(msg)

    def call(self, method, params=None, sid=None, timeout: float = 60.0) -> dict:
        i = self._send(method, params, sid)
        deadline = time.time() + timeout
        while True:
            m = self._recv(deadline)
            if m.get("id") == i:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error'].get('message')}")
                return m.get("result", {})
            self._event(m)

    def _event(self, m: dict):
        if m.get("method") == "Fetch.requestPaused":
            self._send("Fetch.fulfillRequest", {
                "requestId": m["params"]["requestId"], "responseCode": 200,
                "responseHeaders": [{"name": "Content-Type", "value": "text/html"}],
                "body": base64.b64encode(b"<!doctype html><title>txdb</title>").decode()}, self.sid)
        else:
            self.events.append(m)

    def open_blank_origin(self):
        """An empty page on Cashew's origin: the app does not start."""
        self.call("Fetch.enable", {"patterns": [{"urlPattern": ORIGIN + "*"}]}, self.sid)
        self.call("Page.navigate", {"url": ORIGIN + "__txdb__"}, self.sid)
        self.wait_js("location.href.endsWith('__txdb__') && document.readyState === 'complete'")

    def wait_js(self, expr: str, timeout: float = 20.0):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if self.eval(expr, timeout=5):
                    return
            except RuntimeError:
                pass
            time.sleep(0.2)
        raise TimeoutError("the page did not load")

    def eval(self, expr: str, timeout: float = 60.0):
        r = self.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True},
                      self.sid, timeout=timeout)
        if r.get("exceptionDetails"):
            d = r["exceptionDetails"]
            raise RuntimeError((d.get("exception") or {}).get("description") or d.get("text") or "script error")
        return (r.get("result") or {}).get("value")

    def close(self):
        try:
            self._send("Browser.close")
            self.proc.wait(timeout=15)
        except Exception:                          # noqa: BLE001
            self.proc.kill()
        for fd in (self._out, self._in):
            try:
                os.close(fd)
            except OSError:
                pass


def in_use(profile: Path = PROFILE) -> int | None:
    """The pid of a Chromium that has the profile open, or None."""
    lock = profile / "SingletonLock"
    try:
        target = os.readlink(lock)                 # "<host>-<pid>"
    except OSError:
        return None
    try:
        pid = int(target.rsplit("-", 1)[1])
        os.kill(pid, 0)
        return pid
    except (ValueError, IndexError, ProcessLookupError):
        return None
    except PermissionError:
        return pid


class _Lock:
    def __enter__(self):
        LOCK.parent.mkdir(parents=True, exist_ok=True)
        self.f = open(LOCK, "w")
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("another Cashew Chromium write runs")
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def _check(path: Path) -> int:
    c = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)
    try:
        if c.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("the database fails its integrity check")
        return c.execute("SELECT count(*) FROM transactions").fetchone()[0]
    finally:
        c.close()


def read(profile: Path = PROFILE) -> bytes:
    """The Cashew database bytes from the profile (headless, app blocked)."""
    if not profile.exists():
        raise ValueError(f"no Cashew Chromium profile at {profile}: open it once with: {OPEN_COMMAND}")
    pid = in_use(profile)
    if pid:
        raise ValueError(f"the Cashew Chromium window is open (pid {pid}): close it first")
    ch = Chromium(profile)
    try:
        ch.open_blank_origin()
        return base64.b64decode(ch.eval(_READ_JS))
    finally:
        ch.close()


def pull(profile: Path = PROFILE, mirror: Path = MIRROR) -> Path:
    """Refresh the mirror file from Chromium and return it."""
    with _Lock():
        data = read(profile)
    mirror.parent.mkdir(parents=True, exist_ok=True)
    tmp = mirror.with_suffix(".part")
    tmp.write_bytes(data)
    _check(tmp)
    tmp.replace(mirror)
    return mirror


def backup_dir() -> Path:
    drive = Path("/run/media/pc/MY Drive")
    if not os.path.ismount(drive):
        raise ValueError("the external drive is not mounted: no backup, nothing written")
    return drive / "Backup" / "cashew-chromium"


def push(drafts: list[dict], note_drafts: list[dict] | None = None, balances: list[dict] | None = None,
         profile: Path = PROFILE, backups: Path | None = None, dry_run: bool = False,
         mirror: Path = MIRROR, open_after: bool = True) -> dict:
    """Write the ready drafts Cashew does not have into the Chromium profile. Returns the build result plus
    {written, backup, before, after, opened}. Raises ValueError and keeps the old database on any doubt."""
    from . import cashew_file
    with _Lock():
        pid = in_use(profile)
        if pid:
            raise ValueError(f"the Cashew Chromium window is open (pid {pid}): close it first")
        with tempfile.TemporaryDirectory(prefix="cashew-chromium-") as tmp:
            base = Path(tmp) / "base.sqlite"
            ch = Chromium(profile)
            try:
                ch.open_blank_origin()
                old = base64.b64decode(ch.eval(_READ_JS))
                base.write_bytes(old)
                before = _check(base)
                new = Path(tmp) / "new.sqlite"
                r = cashew_file.build(base, new, drafts, dry_run=dry_run, note_drafts=note_drafts or [],
                                      balances=balances or [])
                result = dict(r, written=0, backup="", before=before, after=before, opened=False)
                if dry_run or r.get("changes", r["added"]) == 0:
                    mirror.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(base, mirror)
                    return result
                after = _check(new)
                if after < before:
                    raise ValueError(f"the new database has fewer rows ({after} < {before}): nothing written")
                # back up the database in use, right before the write
                bdir = backups or backup_dir()
                bdir.mkdir(parents=True, exist_ok=True)
                bfile = bdir / (time.strftime("%Y%m%d-%H%M%S") + ".sqlite")
                shutil.copyfile(base, bfile)
                for f in sorted(bdir.glob("*.sqlite"))[:-KEEP_BACKUPS]:
                    f.unlink(missing_ok=True)
                data = new.read_bytes()
                n = ch.eval(f"({_WRITE_JS})('{base64.b64encode(data).decode()}')", timeout=120)
                check = base64.b64decode(ch.eval(_READ_JS))
                if n != len(data) or hashlib.sha256(check).digest() != hashlib.sha256(data).digest():
                    raise ValueError(f"the write could not be checked; restore from {bfile}")
                mirror.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(new, mirror)
                result.update(written=r["added"], backup=str(bfile), after=after)
            finally:
                ch.close()
    # only after a write that worked: open the Cashew window on the new data. Cashew's Google sync needs a
    # visible, signed-in window (a headless start makes no Drive calls, checked 2026-11-17).
    if open_after:
        open_window(profile)
        result["opened"] = True
    return result


def open_window(profile: Path = PROFILE):
    """Open the visible Cashew window on the profile (no wait)."""
    if in_use(profile):
        return
    # the window with the automatic login (login_window), in its own process that lives as long as the window
    import sys as _sys
    env = dict(os.environ, TXDB_CASHEW_CHROMIUM_PROFILE=str(profile))
    subprocess.Popen([_sys.executable, str(Path(__file__).resolve().parents[1] / "bin" / "txdb"), "cashew-chromium", "login"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=env)


def stale(profile: Path = PROFILE, mirror: Path = MIRROR) -> bool:
    """True when the profile's Cashew storage changed after the mirror was made (or there is no mirror)."""
    store = profile / "Default" / "IndexedDB"
    if not store.exists():
        return False
    newest = max((f.stat().st_mtime for f in store.rglob("*") if "budget-track" in str(f)), default=0)
    return not mirror.exists() or newest > mirror.stat().st_mtime


def status(profile: Path = PROFILE) -> dict:
    out = {"profile": str(profile), "exists": profile.exists(), "open": in_use(profile),
           "mirror": str(MIRROR) if MIRROR.exists() else "", "openCommand": OPEN_COMMAND}
    if MIRROR.exists():
        out["rows"] = _check(MIRROR)
        out["mirrorTime"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(MIRROR.stat().st_mtime))
    return out


def restore(backup: Path, profile: Path = PROFILE, mirror: Path = MIRROR) -> dict:
    """Put a backup database back into the profile (the window must be closed). The current one is backed
    up first. Returns {rows, backup}."""
    data = Path(backup).read_bytes()
    with tempfile.TemporaryDirectory(prefix="cashew-chromium-") as tmp:
        probe = Path(tmp) / "r.sqlite"
        probe.write_bytes(data)
        rows = _check(probe)
    with _Lock():
        pid = in_use(profile)
        if pid:
            raise ValueError(f"the Cashew Chromium window is open (pid {pid}): close it first")
        ch = Chromium(profile)
        try:
            ch.open_blank_origin()
            old = base64.b64decode(ch.eval(_READ_JS))
            bdir = backup_dir()
            bdir.mkdir(parents=True, exist_ok=True)
            saved = bdir / (time.strftime("%Y%m%d-%H%M%S") + "-before-restore.sqlite")
            saved.write_bytes(old)
            ch.eval(f"({_WRITE_JS})('{base64.b64encode(data).decode()}')", timeout=120)
            if hashlib.sha256(base64.b64decode(ch.eval(_READ_JS))).digest() != hashlib.sha256(data).digest():
                raise ValueError(f"the restore could not be checked; the old one is in {saved}")
        finally:
            ch.close()
    mirror.parent.mkdir(parents=True, exist_ok=True)
    mirror.write_bytes(data)
    return {"rows": rows, "backup": str(saved)}


# ---- the visible window with the automatic Google login (Cashew web cannot stay signed in)

_PLACEHOLDER = "(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); return 1 })()"
_BUTTONS = ("JSON.stringify([...document.querySelectorAll('flt-semantics[role=button], flt-semantics [role=button]')]"
            ".map(e => { const r = e.getBoundingClientRect(); return [(e.getAttribute('aria-label') || e.textContent || '')"
            ".split('\\n')[0].trim(), r.x + r.width / 2, r.y + r.height / 2] }).filter(x => x[0]))")


def _click(ch: Chromium, x: float, y: float, sid: str):
    ch.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y}, sid)
    for t in ("mousePressed", "mouseReleased"):
        ch.call("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1}, sid)


def _buttons(ch: Chromium) -> list:
    ch.eval(_PLACEHOLDER)                      # Flutter builds its accessibility tree after this
    time.sleep(0.8)
    return json.loads(ch.eval(_BUTTONS) or "[]")


def _tap(ch: Chromium, label: str, wait: float = 20.0) -> bool:
    end = time.time() + wait
    while time.time() < end:
        for name, x, y in _buttons(ch):
            if name.lower() == label.lower():
                _click(ch, x, y, ch.sid)
                return True
        time.sleep(1)
    return False


def _login(ch: Chromium, log=print) -> bool:
    """Load Cashew (with the sql.js hook) and sign in: More > Login > the first account. True when signed in."""
    ok = False
    try:
        ch.call("Page.enable", {}, ch.sid)
        ch.call("Page.addScriptToEvaluateOnNewDocument", {"source": HOOK}, ch.sid)   # before Cashew loads
        ch.call("Page.navigate", {"url": ORIGIN}, ch.sid)
        log("loading Cashew…")
        if not _tap(ch, "More", wait=40):
            raise RuntimeError("Cashew did not load")
        time.sleep(1.5)
        names = [b[0].lower() for b in _buttons(ch)]
        log("Cashew loaded")
        if "logout" in names or "login" not in names:
            ok = True                          # already signed in
        elif _tap(ch, "Login", wait=10):
            log("pressed Login, waiting for the Google popup…")
            for _ in range(30):               # the Google account chooser popup
                time.sleep(1)
                pops = [t for t in ch.call("Target.getTargets")["targetInfos"]
                        if t["type"] == "page" and "accounts.google.com" in t["url"]]
                if pops:
                    break
            else:
                raise RuntimeError("the Google login popup did not open")
            sid = ch.call("Target.attachToTarget", {"targetId": pops[0]["targetId"], "flatten": True})["sessionId"]
            ch.call("Page.bringToFront", {}, sid)
            # the popup window can be small: give its page a fixed size so the buttons fit, whatever the window
            ch.call("Emulation.setDeviceMetricsOverride", {"width": 600, "height": 800, "deviceScaleFactor": 1, "mobile": False}, sid)
            for _ in range(20):
                time.sleep(1)
                try:
                    r = ch.call("Runtime.evaluate", {"returnByValue": True, "expression":
                        "(() => { const e = document.querySelector('[data-identifier]') || [...document.querySelectorAll('button')]"
                        ".find(b => /^(continue|allow)$/i.test(b.innerText.trim())); if (!e) return ''; e.scrollIntoView({block: 'center', inline: 'center'}); const b = e.getBoundingClientRect();"
                        " return JSON.stringify([b.x + b.width / 2, b.y + b.height / 2]) })()"}, sid, timeout=5)
                except RuntimeError:
                    ok = True                  # the popup closed: signed in
                    break
                v = (r.get("result") or {}).get("value")
                log(f"Google popup: {'click at ' + v if v else 'waiting'}")
                if v:
                    x, y = json.loads(v)
                    _click(ch, x, y, sid)
                    time.sleep(2)
        if not ok:
            # the popup may close on its own (Google remembers the choice): ask Cashew itself
            time.sleep(3)
            _tap(ch, "More", wait=10)
            time.sleep(1.5)
            ok = "logout" in [b[0].lower() for b in _buttons(ch)]
        if ok:
            log("signed in to Google")
        else:
            log("the automatic login did not finish: log in by hand")
    except (RuntimeError, TimeoutError) as e:
        log(f"automatic login failed: {e}: log in by hand")
    return ok


def login_window(profile: Path = PROFILE, log=print, test_row: str = "") -> int:
    """Open the visible Cashew window and sign in: More > Login > the first Google account. Stays until the
    window is closed (it holds the debug pipe). Returns 0, or 1 when the login could not be done."""
    if in_use(profile):
        log("the Cashew window is already open")
        return 0
    ch = Chromium(profile, block_app=False, visible=True)
    ok = _login(ch, log)
    try:
        if ok:
            live_loop(ch, log, test_row=test_row)   # signed in: now the edits, inside the page, until the window closes
        ch.proc.wait()
    finally:
        for fd in (ch._out, ch._in):
            try:
                os.close(fd)
            except OSError:
                pass
    return 0 if ok else 1


# ---- live edits inside the open, signed-in Cashew page (no database upload)

# Wraps sql.js before Cashew loads, to keep the Database objects drift makes (Cashew itself is not changed).
HOOK = r"""(() => { window.__txdbDbs = []; let real;
 const wrap = f => function (...a) { return f.apply(this, a).then(SQL => { const D = SQL.Database;
   function W(...b) { const d = new D(...b); window.__txdbDbs.push(d); return d; } W.prototype = D.prototype;
   Object.setPrototypeOf(W, D); SQL.Database = W; return SQL; }); };
 Object.defineProperty(window, 'initSqlJs', { configurable: true, get() { return real; }, set(f) { real = wrap(f); } }); })()"""

_LIVE_DB = ("(() => { const ds = (window.__txdbDbs || []).filter(d => { try { d.exec('select 1 from transactions limit 1');"
            " return true } catch (e) { return false } }); if (ds.length !== 1) throw new Error('found ' + ds.length +"
            " ' live Cashew databases'); return ds[0] })()")

_SAVE_JS = r"""(async () => { const d = %s; const b = d.export();
 const db = await new Promise((res, rej) => { const r = indexedDB.open('moor_databases'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
 await new Promise((res, rej) => { const tx = db.transaction('moor_databases', 'readwrite');
   tx.objectStore('moor_databases').put(new Blob([b]), 'db'); tx.oncomplete = res; tx.onerror = () => rej(tx.error); });
 db.close(); return b.length; })()""" % _LIVE_DB


def live_export(ch: Chromium) -> bytes:
    """The live database of the open Cashew page."""
    js = ("(() => { const b = %s.export(); let s = ''; for (let i = 0; i < b.length; i += 32768)"
          " s += String.fromCharCode.apply(null, b.subarray(i, i + 32768)); return btoa(s) })()") % _LIVE_DB
    return base64.b64decode(ch.eval(js))


def live_run(ch: Chromium, stmts: list[str]) -> int:
    """Run the statements on the live database in one transaction, then save it as drift does. Returns the
    row count of transactions after."""
    js = ("((stmts) => { const d = %s; d.run('BEGIN'); try { for (const s of stmts) d.run(s); d.run('COMMIT') }"
          " catch (e) { d.run('ROLLBACK'); throw e } return d.exec('select count(*) from transactions')[0].values[0][0] })"
          ) % _LIVE_DB
    n = ch.eval(f"({js})({json.dumps(stmts)})", timeout=120)
    ch.eval(_SAVE_JS, timeout=120)
    return n


def live_push(ch: Chromium, drafts: list[dict], note_drafts: list[dict] | None = None,
              backups: Path | None = None) -> dict:
    """Build the update on the live data and apply only the difference. Returns the build result plus
    {statements, before, after, backup}. Raises ValueError and changes nothing on any doubt."""
    from . import cashew_diff, cashew_file
    with tempfile.TemporaryDirectory(prefix="cashew-live-") as tmp:
        base = Path(tmp) / "base.sqlite"
        base.write_bytes(live_export(ch))
        before = _check(base)
        new = Path(tmp) / "new.sqlite"
        r = cashew_file.build(base, new, drafts, note_drafts=note_drafts or [], balances=[])
        result = dict(r, statements=0, before=before, after=before, backup="")
        if r.get("changes", r["added"]) == 0:
            return result
        b, n = sqlite3.connect(base), sqlite3.connect(new)
        try:
            stmts = cashew_diff.statements(b, n)
        finally:
            b.close()
            n.close()
        if not stmts:
            return result
        bdir = backups or backup_dir()
        bdir.mkdir(parents=True, exist_ok=True)
        bfile = bdir / (time.strftime("%Y%m%d-%H%M%S") + "-live.sqlite")
        shutil.copyfile(base, bfile)
        for f in sorted(bdir.glob("*.sqlite"))[:-KEEP_BACKUPS]:
            f.unlink(missing_ok=True)
        after = live_run(ch, stmts)
        if after != before + r["added"]:
            raise ValueError(f"row count {after} is not {before} + {r['added']}; backup in {bfile}")
        result.update(statements=len(stmts), after=after, backup=str(bfile))
        return result


LIVE_STATE = STATE / "cashew-chromium-live.json"


def _notify(text: str):
    try:
        subprocess.Popen(["notify-send", "-a", "Cashew", "Cashew", text], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def live_loop(ch: Chromium, log=print, every: float = 20.0, test_row: str = ""):
    """While the window is open: when the widget DB changed, apply the ready rows inside the page."""
    from . import cashew, cli
    db_path = Path(cli.DB_PATH)
    seen = None
    while ch.proc.poll() is None:
        try:
            stamp = (db_path.stat().st_mtime, cashew.default_state_path().stat().st_mtime
                     if cashew.default_state_path().exists() else 0)
        except OSError:
            stamp = None
        if stamp != seen:
            seen = stamp
            try:
                conn = cashew.open_readonly(db_path)
                ready, waiting, every_rows, _, _ = cli.cashew_ready(conn, cashew.load_state())
                conn.close()
                if test_row:                   # only one test row (₹test_row, HDFC), once; nothing else is sent
                    src = [d for d in every_rows if d.get("account") == "HDFC" and d.get("kind") != "transfer"
                           and d.get("category") not in (None, "", cashew.UNCATEGORIZED[0])][0]
                    ready = [dict(src, id="txdb-live-test-" + test_row, date=time.strftime("%Y-%m-%d"), amount=f"-{float(test_row):.2f}",
                                  title="TXDB TEST", notes="test row from the widget, delete me", include=True)]
                    every_rows = []
                    every = 10 ** 9
                r = live_push(ch, ready, note_drafts=every_rows)
                info = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "added": r["added"], "notes": r.get("notesUpdated", 0),
                        "statements": r["statements"], "rows": r["after"], "waitingCategory": len(waiting),
                        "backup": r["backup"], "error": ""}
                if r["statements"]:
                    log(f"Cashew: {r['added']} rows, {r.get('notesUpdated', 0)} notes added")
                    _notify(f"{r['added']} rows and {r.get('notesUpdated', 0)} notes added. Pull down in Cashew to sync.")
            except (ValueError, RuntimeError, TimeoutError, OSError, sqlite3.Error) as e:
                if ch.proc.poll() is not None:
                    break
                info = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "error": str(e)}
                log(f"Cashew live update failed: {e}")
            try:
                LIVE_STATE.parent.mkdir(parents=True, exist_ok=True)
                LIVE_STATE.write_text(json.dumps(info, ensure_ascii=False), encoding="utf-8")
            except OSError:
                pass
        end = time.time() + every
        while time.time() < end and ch.proc.poll() is None:
            time.sleep(1)



def _drive_calls(ch: Chromium) -> list[str]:
    out = []
    for m in ch.events:
        if m.get("method") == "Network.requestWillBeSent":
            r = m["params"]["request"]
            if "googleapis.com" in r["url"] and "drive" in r["url"]:
                out.append(r["method"] + " " + r["url"].split("?")[0][:90])
    return out


def pull_to_refresh(ch: Chromium):
    """Cashew's sync gesture: on Home, drag down from the top of the list."""
    _tap(ch, "Home", wait=10)
    time.sleep(1.5)
    w, h = json.loads(ch.eval("JSON.stringify([innerWidth, innerHeight])"))
    x, y0 = w * 0.6, h * 0.2
    ch.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y0}, ch.sid)
    ch.call("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y0, "button": "left", "buttons": 1, "clickCount": 1}, ch.sid)
    for i in range(1, 26):
        ch.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y0 + i * h * 0.02, "button": "left", "buttons": 1}, ch.sid)
        time.sleep(0.03)
    ch.call("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x, "y": y0 + 25 * h * 0.02, "button": "left", "buttons": 1, "clickCount": 1}, ch.sid)


def sync_window(profile: Path = PROFILE, log=print, wait: float = 45.0, keep_open: bool = False, hidden: bool = True) -> dict:
    """Open the window, log in, send the waiting rows inside the page, pull down to sync, wait for Cashew's
    Drive calls, then close the window. Returns {signedIn, added, driveCalls}."""
    if in_use(profile):
        raise ValueError("the Cashew window is already open: pull down in it to sync")
    log("starting Chromium in a window off the screen edge…" if hidden else "starting Chromium…")
    ch = Chromium(profile, block_app=False, visible=not hidden, hidden=hidden)
    if hidden:
        ch.call("Emulation.setDeviceMetricsOverride", {"width": 580, "height": 900, "deviceScaleFactor": 1, "mobile": False}, ch.sid)
    out = {"signedIn": False, "added": 0, "driveCalls": []}
    try:
        ch.call("Network.enable", {}, ch.sid)
        if not _login(ch, log):
            raise ValueError("the login did not work: nothing synced")
        out["signedIn"] = True
        from . import cashew, cli
        conn = cashew.open_readonly(Path(cli.DB_PATH))
        ready, _, every_rows, _, _ = cli.cashew_ready(conn, cashew.load_state())
        conn.close()
        log(f"database: {_count_live(ch)} transactions in Cashew")
        if os.environ.get("TXDB_CASHEW_SYNC_ONLY") != "1":
            log(f"{len(ready)} rows are ready to send")
            r = live_push(ch, ready, note_drafts=every_rows)
            out["added"] = r["added"]
            log(f"sent {r['added']} rows and {r.get('notesUpdated', 0)} notes ({r['statements']} statements)"
                + (f", backup {r['backup']}" if r["backup"] else ""))
        else:
            log("only syncing: no rows are sent (TXDB_CASHEW_SYNC_ONLY=1)")
        time.sleep(2)
        ch.events.clear()
        pull_to_refresh(ch)
        log("pulled down: Cashew syncs")
        end = time.time() + wait
        while time.time() < end:
            try:
                ch._event(ch._recv(time.time() + 1))
            except TimeoutError:
                pass
        out["driveCalls"] = _drive_calls(ch)
        calls = [c for c in out["driveCalls"] if not c.startswith("OPTIONS")]
        ups = sum(1 for c in calls if "/upload/" in c)
        if calls:
            log(f"synced with Google Drive: {len(calls)} calls, {ups} uploads")
        else:
            log("no Google Drive calls: the sync did not run")
        if keep_open:
            ch.proc.wait()
    finally:
        if not keep_open:
            ch.close()
            log("closed the hidden Cashew window")
    return out


def _count_live(ch: Chromium) -> int:
    return ch.eval("%s.exec('select count(*) from transactions')[0].values[0][0]" % _LIVE_DB)
