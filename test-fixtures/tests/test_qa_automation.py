import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test-fixtures"
sys.path.insert(0, str(FIXTURES))

from qa_support import (
    Rect,
    cancellation_probe,
    load_dispatch_cases,
    parse_window_rects,
    recorder_command,
    union_rects,
)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SharedDispatchCaseTests(unittest.TestCase):
    def test_cases_are_shared_and_cover_positive_and_negative_routes(self):
        cases = load_dispatch_cases()
        self.assertEqual([case["id"] for case in cases], [f"LD-{index:02d}" for index in range(1, 13)])
        self.assertTrue(any(case["expect_matched"] for case in cases))
        self.assertTrue(any(not case["expect_matched"] for case in cases))
        windows_runner = (FIXTURES / "windows-qa-kit" / "run_qa_windows.py").read_text(encoding="utf-8")
        self.assertIn("for case in load_dispatch_cases()", windows_runner)
        self.assertNotIn('dispatch("LD-01"', windows_runner)
        self.assertIn('p.get("skill") == expect_skill', windows_runner)
        self.assertIn('not p.get("outputs")', windows_runner)

    def test_mac_report_includes_hash_digest_evidence(self):
        mac_runner = (FIXTURES / "run_qa_macos.py").read_text(encoding="utf-8")
        self.assertIn('"digests": digests', mac_runner)


class RecorderTests(unittest.TestCase):
    def test_crop_is_union_of_only_finder_and_folderis_windows(self):
        rects = parse_window_rects(
            "Finder\t100\t50\t900\t700\n"
            "Folderis\t40\t50\t60\t700\n"
            "Safari\t0\t0\t2000\t1200\n"
        )
        crop = union_rects(rects, margin=8)
        self.assertEqual(crop, Rect(32, 42, 976, 716))
        command = recorder_command(Path("/tmp/evidence.mp4"), crop)
        self.assertEqual(command[1:3], ["-v", "-R32,42,976,716"])
        self.assertNotIn("Safari", " ".join(command))


class CancellationTests(unittest.TestCase):
    def test_probe_detects_residue_and_cleans_entire_test_process_group(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            script = (
                "import pathlib,subprocess,sys,time;"
                "pathlib.Path('partial.mp4').write_bytes(b'partial');"
                "subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);"
                "time.sleep(60)"
            )
            result = cancellation_probe(
                [sys.executable, "-c", script],
                work,
                work,
                settle_seconds=0.2,
            )
            self.assertFalse(result["process_group_alive"])
            self.assertEqual(result["residual_outputs"], [str((work / "partial.mp4").resolve())])


class VersionBumpTests(unittest.TestCase):
    FILES = [
        "version.json",
        "01-finder-sidebar/make_release.sh",
        "01-finder-sidebar/build_app.sh",
        "01-finder-sidebar/FinderSidebar.xcodeproj/project.pbxproj",
        "win-explorer-sidebar/src/Sider/Sider.csproj",
        "win-explorer-sidebar/src/Setup/Setup.csproj",
    ]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for relative in self.FILES:
            source = ROOT / relative
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        self.bump = load_module("folderis_bump_version_test", ROOT / "scripts" / "bump_version.py")

    def tearDown(self):
        self.temp.cleanup()

    def test_invalid_input_changes_nothing(self):
        before = {path: (self.root / path).read_bytes() for path in self.FILES}
        with self.assertRaises(self.bump.VersionError):
            self.bump.validate("1.bad", "20260731.1")
        self.assertEqual(before, {path: (self.root / path).read_bytes() for path in self.FILES})

    def test_apply_is_atomic_and_idempotent(self):
        rendered = self.bump.render(self.root, "1.2.3", "20260731.4")
        changes = {path: content for path, content in rendered.items() if path.read_text() != content}
        self.bump.atomic_write(changes)
        first = {path: path.read_bytes() for path in rendered}
        rerendered = self.bump.render(self.root, "1.2.3", "20260731.4")
        self.assertTrue(all(path.read_text() == content for path, content in rerendered.items()))
        self.assertEqual(first, {path: path.read_bytes() for path in rendered})

    def test_failed_commit_rolls_back_every_target(self):
        rendered = self.bump.render(self.root, "1.2.3", "20260731.4")
        changes = {path: content for path, content in rendered.items() if path.read_text() != content}
        before = {path: path.read_bytes() for path in changes}
        real_replace = os.replace
        calls = 0

        def fail_second(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected commit failure")
            return real_replace(source, destination)

        with mock.patch.object(self.bump.os, "replace", side_effect=fail_second):
            with self.assertRaises(OSError):
                self.bump.atomic_write(changes)
        self.assertEqual(before, {path: path.read_bytes() for path in changes})


if __name__ == "__main__":
    unittest.main()
