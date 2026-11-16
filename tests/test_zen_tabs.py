"""txdb/zen_tabs.py: the open Cashew tabs in Zen's saved session (mozlz4)."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from txdb import zen_tabs  # noqa: E402


def literal_block(data: bytes) -> bytes:
    """An LZ4 block of one literal run (valid LZ4; enough to test the decoder's literal path)."""
    n = len(data)
    if n < 15:
        return bytes([n << 4]) + data
    rest, out = n - 15, bytearray([0xF0])
    while rest >= 255:
        out.append(255)
        rest -= 255
    out.append(rest)
    return bytes(out) + data


def mozlz4(obj) -> bytes:
    data = json.dumps(obj).encode()
    return b"mozLz40\0" + len(data).to_bytes(4, "little") + literal_block(data)


SESSION = {"windows": [{"tabs": [
    {"entries": [{"url": "https://github.com/x"}], "index": 1},
    {"entries": [{"url": "https://budget-track.web.app/"}, {"url": "https://example.com/"}], "index": 2},   # moved away
    {"entries": [{"url": "https://example.com/"}, {"url": "https://budget-track.web.app/"}], "index": 2},
]}, {"tabs": [{"entries": [{"url": "https://budget-track.web.app/addTransaction?JSON=x"}]}],
     "_closedTabs": [{"state": {"entries": [{"url": "https://budget-track.web.app/"}]}}]}]}


class ZenTabs(unittest.TestCase):
    def test_decoder_with_literals_and_a_match(self):
        self.assertEqual(zen_tabs.lz4_block(literal_block(b"hello world, hello"), 0), b"hello world, hello")
        # "abcabcabcabc": 3 literals, then a match of 9 at offset 3 (overlapping copy)
        block = bytes([(3 << 4) | (9 - 4)]) + b"abc" + (3).to_bytes(2, "little")
        self.assertEqual(zen_tabs.lz4_block(block, 12), b"abcabcabcabc")

    def test_open_tabs_count_the_current_page_and_not_the_closed_ones(self):
        got = zen_tabs.open_cashew_tabs(SESSION)
        self.assertEqual([(t["window"], t["tab"]) for t in got], [(1, 3), (2, 1)])

    def test_check_reads_the_newest_session_file_of_the_cashew_profile(self):
        with tempfile.TemporaryDirectory() as home:
            prof = Path(home) / ".config" / "zen" / "abc.Default"
            (prof / "storage" / "default" / "https+++budget-track.web.app").mkdir(parents=True)
            (prof / "sessionstore-backups").mkdir()
            (prof / "sessionstore.jsonlz4").write_bytes(mozlz4({"windows": []}))
            os.utime(prof / "sessionstore.jsonlz4", (1, 1))
            (prof / "sessionstore-backups" / "recovery.jsonlz4").write_bytes(mozlz4(SESSION))
            got = zen_tabs.check(Path(home))
            self.assertEqual(got["open"], 2)
            self.assertTrue(got["session"].endswith("recovery.jsonlz4"))
            (prof / "sessionstore-backups" / "recovery.jsonlz4").write_bytes(b"junk")
            self.assertEqual(zen_tabs.check(Path(home))["open"], -1)
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(zen_tabs.check(Path(empty))["open"], -1)


if __name__ == "__main__":
    unittest.main()
