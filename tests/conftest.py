"""Shared test setup: no test reads the real browser's Cashew (a test that needs a fake one sets
TXDB_BROWSER_HOME and removes TXDB_NO_BROWSER_COPY for its own subprocess)."""
import os

os.environ.setdefault("TXDB_NO_BROWSER_COPY", "1")
