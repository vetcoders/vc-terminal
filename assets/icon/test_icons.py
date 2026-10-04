"""Regression checks for the static product mark and its carriers."""

import hashlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MASTER = ROOT / "assets/icon/vc-terminal-icon.png"
REFERENCE = ROOT / "assets/icon/terminal.png"
ICNS = ROOT / "extra/osx/vc-terminal.app/Contents/Resources/alacritty.icns"
MASTER_SHA256 = "94f21388aa5ed358503294a543db80a8a74d7b114137e12e9f854114cc7599d3"


def png_size(path):
    header = path.read_bytes()[:24]
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise AssertionError(f"not a PNG: {path}")
    return struct.unpack(">II", header[16:24])


class ProductIconTests(unittest.TestCase):
    def test_master_is_the_pinned_static_dock_tile(self):
        self.assertEqual(png_size(MASTER), (1254, 1254))
        self.assertEqual(
            hashlib.sha256(MASTER.read_bytes()).hexdigest(), MASTER_SHA256
        )

    def test_generic_reference_has_the_expected_size(self):
        self.assertEqual(png_size(REFERENCE), (128, 128))

    @unittest.skipUnless(shutil.which("sips"), "macOS raster generator required")
    def test_reference_is_derived_from_the_pinned_master(self):
        with tempfile.TemporaryDirectory(prefix="vc-terminal-icon-test-") as work:
            expected = Path(work) / "reference.png"
            subprocess.run(
                ["sips", "-z", "128", "128", str(MASTER), "--out", str(expected)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            self.assertEqual(REFERENCE.read_bytes(), expected.read_bytes())

    @unittest.skipUnless(shutil.which("iconutil"), "macOS icon carrier tools required")
    def test_mac_carrier_includes_hires_and_small_representations(self):
        data = ICNS.read_bytes()
        self.assertEqual(data[:4], b"icns")
        self.assertEqual(struct.unpack(">I", data[4:8])[0], len(data))
        with tempfile.TemporaryDirectory(prefix="vc-terminal-icns-test-") as work:
            iconset = Path(work) / "product.iconset"
            subprocess.run(
                ["iconutil", "-c", "iconset", str(ICNS), "-o", str(iconset)],
                check=True,
            )
            sizes = {png_size(path) for path in iconset.glob("*.png")}
            self.assertTrue(
                {(size, size) for size in (16, 32, 64, 128, 256, 512, 1024)} <= sizes
            )
            expected = Path(work) / "expected-1024.png"
            subprocess.run(
                ["sips", "-z", "1024", "1024", str(MASTER), "--out", str(expected)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            self.assertEqual(
                (iconset / "icon_512x512@2x.png").read_bytes(), expected.read_bytes()
            )


if __name__ == "__main__":
    unittest.main()
