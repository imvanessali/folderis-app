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
    parse_named_window_rects,
    parse_window_rects,
    recording_crop_from_windows,
    recorder_command,
    union_rects,
)
from qa_structural_cases import structural_cases


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
    def test_crop_is_gap_free_union_of_exact_docked_pair(self):
        windows = parse_named_window_rects(
            "Finder\t100\t50\t900\t700\n"
            "Folderis\t40\t50\t60\t700\n"
        )
        crop = recording_crop_from_windows(windows)
        self.assertEqual(crop, Rect(40, 50, 960, 700))
        command = recorder_command(Path("/tmp/evidence.mp4"), crop)
        self.assertEqual(command[1:3], ["-v", "-R40,50,960,700"])

    def test_separated_windows_fail_before_recording(self):
        windows = parse_named_window_rects(
            "Finder\t200\t50\t900\t700\n"
            "Folderis\t40\t50\t100\t700\n"
        )
        with self.assertRaisesRegex(ValueError, "gap-free rectangle"):
            recording_crop_from_windows(windows)

    def test_extra_finder_or_folderis_window_fails_before_recording(self):
        for output in (
            "Finder\t100\t50\t900\t700\nFinder\t120\t80\t400\t300\nFolderis\t40\t50\t60\t700\n",
            "Finder\t100\t50\t900\t700\nFolderis\t40\t50\t60\t700\nFolderis\t50\t80\t500\t400\n",
        ):
            with self.subTest(output=output):
                with self.assertRaisesRegex(ValueError, "exactly one visible"):
                    recording_crop_from_windows(parse_named_window_rects(output))


class StructuralValidationTests(unittest.TestCase):
    def test_established_round_has_47_genuine_stable_workflows(self):
        cases = structural_cases()
        self.assertEqual(len(cases), 47)
        self.assertEqual([case["id"] for case in cases], [f"W-{index:02d}" for index in range(1, 48)])
        self.assertTrue(all(case["args"] and case["parameters"] for case in cases))
        validator = (FIXTURES / "qa_semantic_validators.py").read_text(encoding="utf-8")
        for case in cases:
            self.assertIn(f'id_ == "{case["id"]}"', validator)


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
        "win-explorer-sidebar/build_release.sh",
        "01-finder-sidebar/make_release_matrix.sh",
        "announce/public/announce.json",
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

    def test_cli_dry_run_and_check_do_not_write(self):
        command = [
            sys.executable,
            str(ROOT / "scripts" / "bump_version.py"),
            "1.2.3",
            "20260731.4",
            "--dry-run",
            "--root",
            str(self.root),
        ]
        before = {path: (self.root / path).read_bytes() for path in self.FILES}
        dry_run = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
        self.assertIn("Dry run:", dry_run.stdout)
        self.assertEqual(before, {path: (self.root / path).read_bytes() for path in self.FILES})
        self.assertEqual(
            (self.root / "announce/public/announce.json").read_bytes(),
            before["announce/public/announce.json"],
        )

        check = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "bump_version.py"),
                "--check",
                "--root",
                str(self.root),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(check.returncode, 0, check.stderr)


if __name__ == "__main__":
    unittest.main()
