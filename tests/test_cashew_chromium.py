"""txdb/cashew_chromium.py: the parts that need no browser."""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import cashew_chromium as cc  # noqa: E402


class Chromium(unittest.TestCase):
    def test_in_use_reads_the_singleton_lock(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            self.assertIsNone(cc.in_use(p))
            os.symlink(f"host-{os.getpid()}", p / "SingletonLock")
            self.assertEqual(cc.in_use(p), os.getpid())
            (p / "SingletonLock").unlink()
            os.symlink("host-999999999", p / "SingletonLock")      # a dead pid: not in use
            self.assertIsNone(cc.in_use(p))

    def test_stale_when_the_storage_is_newer_than_the_mirror(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            store = p / "Default" / "IndexedDB" / "https_budget-track.web.app_0.indexeddb.leveldb"
            store.mkdir(parents=True)
            (store / "000001.log").write_text("x")
            mirror = p / "mirror.sqlite"
            self.assertTrue(cc.stale(p, mirror))
            mirror.write_text("m")
            self.assertFalse(cc.stale(p, mirror))
            later = time.time() + 5
            os.utime(store / "000001.log", (later, later))
            self.assertTrue(cc.stale(p, mirror))

    def test_no_profile_no_read(self):
        with self.assertRaises(ValueError):
            cc.read(Path("/nonexistent/cashew-profile"))


if __name__ == "__main__":
    unittest.main()
