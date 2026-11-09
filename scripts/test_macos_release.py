"""Exercise local packaging with fake signing/build tools; never open a window."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build-vc-terminal-release.sh"


@unittest.skipUnless(sys.platform == "darwin", "macOS packaging")
class MacOSReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vc-terminal packaging ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.dist = self.root / "dist"
        self.log = self.root / "commands.jsonl"
        self.commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
        short = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True
        ).strip()
        metadata = json.loads(subprocess.check_output(
            ["cargo", "metadata", "--no-deps", "--format-version=1"], cwd=ROOT
        ))
        self.version = next(p["version"] for p in metadata["packages"] if p["name"] == "alacritty")
        metadata["target_directory"] = str(self.root / "target")
        self.metadata = self.root / "metadata.json"
        self.metadata.write_text(json.dumps(metadata))
        self.binary = self.root / "target/release/alacritty"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text(f"#!/bin/sh\nprintf '%s\\n' 'alacritty {self.version} ({short})'\n")
        self.binary.chmod(0o755)
        driver = self.tools / "driver"
        driver.write_text(f"#!{sys.executable}\n" + r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_COMMAND_LOG'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'cargo':
    print(pathlib.Path(os.environ['TEST_METADATA']).read_text())
elif name == 'security':
    print(os.environ.get('TEST_IDENTITIES', '0 valid identities found'))
elif name == 'file':
    print('Mach-O 64-bit executable arm64')
elif name == 'otool':
    print(args[-1] + ':\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)')
elif name == 'codesign' and os.environ.get('TEST_SIGN_FAIL'):
    sys.exit(1)
elif name == 'hdiutil':
    staging = pathlib.Path(args[args.index('-srcfolder') + 1])
    assert (staging / 'vc-terminal.app/Contents/MacOS/vc-terminal').is_file()
    assert (staging / 'Applications').is_symlink()
    pathlib.Path(args[-1]).write_text('fake dmg')
''')
        driver.chmod(0o755)
        for name in ("cargo", "make", "security", "file", "otool", "install_name_tool", "codesign", "hdiutil"):
            (self.tools / name).symlink_to(driver)
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        CARGO=str(self.tools / "cargo"), DIST_DIR=str(self.dist),
                        TEST_METADATA=str(self.metadata), TEST_COMMAND_LOG=str(self.log))

    def run_packaging(self, *args, success=True):
        result = subprocess.run(["bash", str(SCRIPT), *args], cwd=ROOT, env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_app_contains_private_resources_and_head_provenance(self):
        self.run_packaging("--skip-build", "--skip-dmg")
        app = self.dist / "vc-terminal.app"
        with (app / "Contents/Info.plist").open("rb") as f:
            plist = plistlib.load(f)
        self.assertEqual(plist["CFBundleExecutable"], "vc-terminal")
        self.assertEqual(plist["CFBundleIdentifier"], "io.vetcoders.vc-terminal")
        self.assertEqual(plist["CFBundleShortVersionString"], self.version)
        self.assertEqual(plist["VCTerminalBuildCommit"], self.commit)
        self.assertFalse(any(k.startswith("com.apple.security.") for k in plist))
        resources = app / "Contents/Resources"
        fonts = resources / plist["ATSApplicationFontsPath"]
        for source in (ROOT / "assets/fonts/source-code-pro").iterdir():
            if source.suffix == ".ttf" or source.name == "OFL.txt":
                self.assertEqual((fonts / source.name).read_bytes(), source.read_bytes())
        self.assertTrue((resources / "alacritty.1.gz").is_file())
        self.assertTrue((resources / "completions/_alacritty").is_file())
        self.assertEqual((app / "Contents/MacOS/vc-terminal").read_bytes(), self.binary.read_bytes())
        signs = [c for c in self.commands() if c[0] == "codesign" and "--sign" in c]
        self.assertTrue(signs)
        self.assertTrue(all(c[c.index("--sign") + 1] == "-" for c in signs))
        self.assertTrue(all("runtime" in c for c in signs))
        self.assertFalse(any(c[0] in ("make", "hdiutil") for c in self.commands()))
        self.assertFalse((self.dist / "vc-terminal.dmg").exists())

    def test_dmg_builds_binary_and_selects_only_expected_developer_id(self):
        self.env["TEST_IDENTITIES"] = (
            '1) ' + 'B' * 40 + ' "Apple Distribution: Someone (MW223P3NPX)"\n'
            '2) ' + 'C' * 40 + ' "Developer ID Application: Someone (OTHERTEAM)"\n'
            '3) ' + 'A' * 40 + ' "Developer ID Application: Someone (MW223P3NPX)"'
        )
        self.run_packaging()
        self.assertTrue((self.dist / "vc-terminal.dmg").is_file())
        self.assertTrue(any(c[0] == "make" and "release-bins" in c for c in self.commands()))
        for command in self.commands():
            if command[0] == "codesign" and "--sign" in command:
                self.assertEqual(command[command.index("--sign") + 1], "A" * 40)
                self.assertIn("--timestamp", command)

    def test_stale_binary_is_rejected(self):
        self.binary.write_text("#!/bin/sh\necho 'alacritty 0.0.0 (stale)'\n")
        result = self.run_packaging("--skip-build", "--skip-dmg", success=False)
        self.assertIn("does not match Cargo version and HEAD", result.stdout)
        self.assertFalse(self.dist.exists())

    def test_signing_failure_preserves_previous_app_and_cleans_staging(self):
        old = self.dist / "vc-terminal.app/previous"
        old.parent.mkdir(parents=True)
        old.write_text("keep")
        self.env["TEST_SIGN_FAIL"] = "1"
        self.run_packaging("--skip-build", "--skip-dmg", success=False)
        self.assertEqual(old.read_text(), "keep")
        self.assertEqual(list(self.dist.iterdir()), [old.parent])

    def test_install_and_notarize_flags_are_rejected(self):
        for flag in ("--install", "--notarize-only"):
            with self.subTest(flag=flag):
                self.assertIn("Unknown argument", self.run_packaging(flag, success=False).stdout)


if __name__ == "__main__":
    unittest.main()
