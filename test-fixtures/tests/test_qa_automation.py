import importlib.util
import json
import os
import plistlib
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


def layer_window(owner_pid, rect, owner, *, alpha=1):
    return {
        "owner_pid": owner_pid,
        "owner": owner,
        "name": "",
        "number": owner_pid,
        "layer": 0,
        "alpha": alpha,
        "bounds": {
            "X": rect.x,
            "Y": rect.y,
            "Width": rect.width,
            "Height": rect.height,
        },
    }


def coverage_snapshot(approved, *, occluder_position=None):
    finder = dict(approved)["Finder"]
    folderis = dict(approved)["Folderis"]
    target_windows = [
        layer_window(10, finder, "Finder"),
        layer_window(20, folderis, "Folderis"),
    ]
    occluder = layer_window(30, Rect(0, 0, 1200, 800), "Orca")
    if occluder_position is not None:
        target_windows.insert(occluder_position, occluder)
    else:
        target_windows.append(occluder)
    return {"finder_pid": 10, "folderis_pid": 20, "windows": target_windows}


class SharedDispatchCaseTests(unittest.TestCase):
    def test_cases_are_shared_and_cover_positive_and_negative_routes(self):
        cases = load_dispatch_cases()
        self.assertEqual([case["id"] for case in cases], [f"LD-{index:02d}" for index in range(1, 21)])
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

    def test_mac_qa_never_falls_back_to_signed_app_runtime(self):
        mac_runner = (FIXTURES / "run_qa_macos.py").read_text(encoding="utf-8")
        self.assertNotIn("/Applications/Folderis.app/Contents/Resources/runtime/python",
                         mac_runner)

    def test_mac_qa_disables_bytecode_writes_for_every_skill_process(self):
        runner = load_module("folderis_macos_qa_environment_tests",
                             FIXTURES / "run_qa_macos.py")
        with mock.patch.object(runner.subprocess, "run") as run:
            runner.run_command(Path("python"), Path("skills.py"), Path("."), [], {})
        self.assertEqual(run.call_args.kwargs["env"]["PYTHONDONTWRITEBYTECODE"], "1")


class RecorderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = load_module(
            "folderis_macos_qa_recorder_tests",
            FIXTURES / "run_qa_macos.py",
        )

    @unittest.skipUnless(sys.platform == "darwin", "real AppleScript smoke test requires macOS")
    def test_real_window_script_executes_when_finder_is_available(self):
        finder = subprocess.run(["pgrep", "-x", "Finder"], capture_output=True)
        if finder.returncode != 0:
            self.skipTest("Finder process is not available")
        runner = load_module(
            "folderis_macos_qa_window_script_test",
            FIXTURES / "run_qa_macos.py",
        )
        result = subprocess.run(
            ["osascript", "-e", runner.WINDOW_SCRIPT],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = parse_named_window_rects(result.stdout)
        self.assertTrue(all(name in {"Finder", "Folderis"} for name, _ in parsed))

    @unittest.skipUnless(sys.platform == "darwin", "real JXA parse test requires macOS")
    def test_real_core_graphics_jxa_compiles_and_returns_parseable_z_order(self):
        snapshot = self.runner.read_window_z_order()
        self.assertIsInstance(snapshot["finder_pid"], int)
        self.assertIsInstance(snapshot["folderis_pid"], int)
        self.assertIsInstance(snapshot["windows"], list)
        self.assertTrue(all(window["layer"] == 0 for window in snapshot["windows"]))
        self.assertTrue(all("bounds" in window for window in snapshot["windows"]))

    def test_help_describes_strict_gap_free_recording_area(self):
        result = subprocess.run(
            [sys.executable, str(FIXTURES / "run_qa_macos.py"), "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "strictly gap-free Finder + Folderis area",
            " ".join(result.stdout.split()),
        )
        self.assertIn("--recording-directory", result.stdout)

    def test_legacy_single_output_flag_has_actionable_rejection(self):
        result = subprocess.run(
            [
                sys.executable,
                str(FIXTURES / "run_qa_macos.py"),
                "--recording-output",
                "/tmp/old.mp4",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--recording-directory", result.stderr)
        self.assertIn("one MP4 per task", result.stderr)

    def test_recording_filename_is_stable_sanitized_and_readable(self):
        self.assertEqual(
            self.runner.recording_filename("W-01", ' 图片 水印:/?* '),
            "W-01-图片-水印.mp4",
        )
        self.assertEqual(
            self.runner.recording_filename("CANCEL-01", "视频压缩取消"),
            "CANCEL-01-视频压缩取消.mp4",
        )

    def test_manifest_contains_only_actual_tasks(self):
        tasks = self.runner.recording_tasks(
            load_dispatch_cases(), structural_cases(), True
        )
        self.assertEqual(len(tasks), 69)  # 20 dispatch + 47 structural + collision + cancel
        self.assertEqual(tasks[0][0], "LD-01")
        self.assertIn(("ART-COLLISION", "重复转换碰撞"), tasks)
        self.assertIn(("CANCEL-01", "视频压缩取消"), tasks)
        self.assertEqual(
            [task_id for task_id, _ in tasks if task_id.startswith("W-")],
            [f"W-{index:02d}" for index in range(1, 48)],
        )
        self.assertFalse(any(task_id in {"ART-CROP", "ART-HASH", "ORIGINALS"} for task_id, _ in tasks))

    def test_per_task_lifecycle_maps_video_into_result_and_preserves_failure(self):
        events = []

        class FakeRecorder:
            def __init__(fake, output, ffmpeg, crop):
                fake.output = output

            def start(fake):
                events.append("start")

            def stop(fake):
                events.append("stop")
                fake.output.write_bytes(b"playable")

            def cleanup(fake):
                events.append("cleanup")

        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            manager = self.runner.RecordingManager(
                directory,
                directory / "ffmpeg",
                window_preparer=lambda approved, crop: None,
            )
            manager.outputs = {"LD-01": directory / "LD-01-label.mp4"}
            manager.crop = Rect(0, 0, 100, 100)

            def failing_action():
                events.append("action")
                return subprocess.CompletedProcess([], 1)

            with mock.patch.object(self.runner, "ScreenRecorder", FakeRecorder):
                completed, recording = self.runner.run_recorded_action(
                    manager, "LD-01", failing_action
                )

            self.assertEqual(completed.returncode, 1)
            self.assertEqual(events[:3], ["start", "action", "stop"])
            self.assertEqual(recording["status"], "RECORDED")
            self.assertIsNone(recording["error"])
            self.assertEqual(recording["path"], str(directory / "LD-01-label.mp4"))
            self.assertTrue(Path(recording["path"]).is_file())

    def test_action_still_runs_and_json_gets_error_when_recorder_start_fails(self):
        events = []

        class FailingRecorder:
            def __init__(fake, output, ffmpeg, crop):
                pass

            def start(fake):
                events.append("start")
                raise RuntimeError("permission denied")

            def cleanup(fake):
                events.append("cleanup")

        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            manager = self.runner.RecordingManager(
                directory,
                directory / "ffmpeg",
                window_preparer=lambda approved, crop: None,
            )
            manager.outputs = {"W-01": directory / "W-01-label.mp4"}
            manager.crop = Rect(0, 0, 100, 100)
            with mock.patch.object(self.runner, "ScreenRecorder", FailingRecorder):
                value, recording = self.runner.run_recorded_action(
                    manager,
                    "W-01",
                    lambda: events.append("action") or "done",
                )
            self.assertEqual(value, "done")
            self.assertEqual(events, ["start", "cleanup", "action"])
            self.assertEqual(recording["status"], "ERROR")
            self.assertIn("permission denied", recording["error"])

    def test_each_task_reactivates_and_revalidates_before_recorder_start(self):
        events = []
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]

        class FakeRecorder:
            def __init__(fake, output, ffmpeg, crop):
                fake.output = output

            def start(fake):
                events.append(("recorder-start", fake.output.name))

            def stop(fake):
                pass

            def cleanup(fake):
                pass

        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)

            def prepare(current_approved, crop):
                events.append(("prepare", current_approved, crop))

            manager = self.runner.RecordingManager(
                directory, directory / "ffmpeg", window_preparer=prepare
            )
            manager.approved_windows = approved
            manager.crop = Rect(40, 50, 960, 700)
            manager.outputs = {
                "LD-01": directory / "LD-01-one.mp4",
                "W-24": directory / "W-24-two.mp4",
            }
            with mock.patch.object(self.runner, "ScreenRecorder", FakeRecorder):
                first = manager.start_task("LD-01")
                manager.stop_task(first)
                second = manager.start_task("W-24")
                manager.stop_task(second)

        self.assertEqual(
            [event[0] for event in events],
            ["prepare", "recorder-start", "prepare", "recorder-start"],
        )
        self.assertIs(events[0][1], approved)
        self.assertIs(events[2][1], approved)

    def test_exact_finder_activation_only_raises_window_without_touching_selection(self):
        selected_inputs = ["/fixtures/one.jpg", "/fixtures/two.jpg"]
        activated = subprocess.CompletedProcess([], 0, stdout="raised", stderr="")
        with mock.patch.object(
            self.runner.subprocess, "run", return_value=activated
        ) as run:
            self.runner.activate_exact_finder_window(Rect(100, 50, 900, 700))
        self.assertEqual(selected_inputs, ["/fixtures/one.jpg", "/fixtures/two.jpg"])
        command = run.call_args.args[0]
        self.assertEqual(command[-4:], ["100", "50", "900", "700"])
        self.assertIn("AXRaise", command[2])
        self.assertNotIn("click", command[2].lower())

    def test_task_window_helper_waits_for_panel_then_accepts_exact_geometry(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        reads = iter([
            [("Finder", Rect(100, 50, 900, 700))],
            approved,
        ])
        waits = []
        toggles = []
        self.runner.prepare_task_recording_windows(
            approved,
            Rect(40, 50, 960, 700),
            activate_finder=lambda finder: None,
            read_windows=lambda: next(reads),
            toggle_panel=lambda: toggles.append("toggle"),
            read_z_order=lambda: coverage_snapshot(approved),
            wait=waits.append,
            attempts=2,
        )
        self.assertEqual(waits, [])
        self.assertEqual(toggles, ["toggle"])

    def test_task_window_helper_waits_and_fails_when_panel_is_missing(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        activation = []
        reads = iter([
            [("Finder", Rect(100, 50, 900, 700))],
            [("Finder", Rect(100, 50, 900, 700))],
        ])
        with self.assertRaisesRegex(
            self.runner.QAError, "exactly one visible.*Folderis=0"
        ):
            self.runner.prepare_task_recording_windows(
                approved,
                Rect(40, 50, 960, 700),
                activate_finder=lambda finder: activation.append(finder),
                read_windows=lambda: next(reads),
                toggle_panel=lambda: None,
                read_z_order=lambda: self.fail("z-order must not run without panel"),
                wait=lambda seconds: None,
                attempts=1,
            )
        self.assertEqual(activation, [Rect(100, 50, 900, 700)])

    def test_task_window_helper_rejects_changed_crop(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        changed = [
            ("Finder", Rect(120, 50, 900, 700)),
            ("Folderis", Rect(60, 50, 60, 700)),
        ]
        with self.assertRaisesRegex(self.runner.QAError, "geometry changed"):
            self.runner.prepare_task_recording_windows(
                approved,
                Rect(40, 50, 960, 700),
                activate_finder=lambda finder: None,
                read_windows=lambda: changed,
                toggle_panel=lambda: self.fail("changed geometry must not toggle panel"),
                read_z_order=lambda: self.fail("changed geometry must not read z-order"),
                wait=lambda seconds: None,
                attempts=1,
            )

    def test_occluded_panel_is_cycled_off_on_then_accepted_only_when_top(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        hidden = [("Finder", Rect(100, 50, 900, 700))]
        reads = iter([approved, approved, hidden, approved])
        z_orders = iter([
            coverage_snapshot(approved, occluder_position=1),
            coverage_snapshot(approved),
        ])
        activations = []
        toggles = []
        recovery_order = []

        def activate(finder):
            activations.append(finder)
            recovery_order.append("activate")

        def toggle():
            toggles.append("toggle")
            recovery_order.append("toggle")

        self.runner.prepare_task_recording_windows(
            approved,
            Rect(40, 50, 960, 700),
            activate_finder=activate,
            read_windows=lambda: next(reads),
            toggle_panel=toggle,
            read_z_order=lambda: next(z_orders),
            wait=lambda seconds: None,
            attempts=1,
        )
        self.assertEqual(toggles, ["toggle", "toggle"])
        self.assertEqual(
            activations,
            [Rect(100, 50, 900, 700), Rect(100, 50, 900, 700)],
        )
        self.assertEqual(
            recovery_order, ["activate", "toggle", "activate", "toggle"]
        )

    def test_unrelated_top_layer_window_is_rejected(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        with self.assertRaisesRegex(
            self.runner.WindowOcclusionError, "Orca.*above and intersects"
        ):
            self.runner.verify_on_screen_window_coverage(
                approved,
                coverage_snapshot(approved, occluder_position=0),
            )

    def test_finder_and_folderis_top_coverage_is_accepted(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        self.runner.verify_on_screen_window_coverage(
            approved, coverage_snapshot(approved)
        )

    def test_unsafe_task_state_never_constructs_or_starts_screencapture(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        unsafe_states = {
            "panel missing": [("Finder", Rect(100, 50, 900, 700))],
            "crop changed": [
                ("Finder", Rect(120, 50, 900, 700)),
                ("Folderis", Rect(60, 50, 60, 700)),
            ],
        }
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for label, current in unsafe_states.items():
                with self.subTest(label=label), mock.patch.object(
                    self.runner, "ScreenRecorder"
                ) as recorder:
                    def prepare(current_approved, crop, unsafe=current):
                        self.runner.prepare_task_recording_windows(
                            current_approved,
                            crop,
                            activate_finder=lambda finder: None,
                            read_windows=lambda: unsafe,
                            toggle_panel=lambda: None,
                            read_z_order=lambda: coverage_snapshot(current_approved),
                            wait=lambda seconds: None,
                            attempts=1,
                        )

                    manager = self.runner.RecordingManager(
                        directory, directory / "ffmpeg", window_preparer=prepare
                    )
                    manager.approved_windows = approved
                    manager.crop = Rect(40, 50, 960, 700)
                    manager.outputs = {"LD-01": directory / "LD-01-one.mp4"}
                    recording = manager.start_task("LD-01")
                    self.assertEqual(recording["status"], "ERROR")
                    self.assertIn("screencapture was not started", recording["error"])
                    recorder.assert_not_called()

    def test_unprovable_occlusion_never_starts_screencapture(self):
        approved = [
            ("Finder", Rect(100, 50, 900, 700)),
            ("Folderis", Rect(40, 50, 60, 700)),
        ]
        hidden = [("Finder", Rect(100, 50, 900, 700))]
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            self.runner, "ScreenRecorder"
        ) as recorder:
            reads = iter([approved, approved, hidden, approved])

            def prepare(current_approved, crop):
                self.runner.prepare_task_recording_windows(
                    current_approved,
                    crop,
                    activate_finder=lambda finder: None,
                    read_windows=lambda: next(reads),
                    toggle_panel=lambda: None,
                    read_z_order=lambda: coverage_snapshot(
                        current_approved, occluder_position=1
                    ),
                    wait=lambda seconds: None,
                    attempts=1,
                )

            directory = Path(temp)
            manager = self.runner.RecordingManager(
                directory, directory / "ffmpeg", window_preparer=prepare
            )
            manager.approved_windows = approved
            manager.crop = Rect(40, 50, 960, 700)
            manager.outputs = {"LD-01": directory / "LD-01-one.mp4"}
            recording = manager.start_task("LD-01")
            self.assertEqual(recording["status"], "ERROR")
            self.assertIn("Orca", recording["error"])
            self.assertIn("screencapture was not started", recording["error"])
            recorder.assert_not_called()

    def test_output_collisions_are_checked_as_one_preflight(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            ffmpeg = directory / "ffmpeg"
            ffmpeg.touch()
            first = directory / self.runner.recording_filename("LD-01", "one")
            second = directory / self.runner.recording_filename("W-01", "two")
            first.write_bytes(b"old-one")
            second.write_bytes(b"old-two")
            help_result = subprocess.CompletedProcess(
                [], 0, stdout="-v -R<x,y,w,h>", stderr=""
            )
            bounds_result = subprocess.CompletedProcess(
                [], 0,
                stdout="Finder\t100\t50\t900\t700\nFolderis\t40\t50\t60\t700\n",
                stderr="",
            )
            with mock.patch.object(Path, "is_file", return_value=True), mock.patch.object(
                self.runner.subprocess, "run", side_effect=[help_result]
            ):
                manager = self.runner.RecordingManager(directory, ffmpeg)
                with self.assertRaisesRegex(self.runner.QAError, "already exists"):
                    manager.preflight([("LD-01", "one"), ("W-01", "two")])
            self.assertEqual(first.read_bytes(), b"old-one")
            self.assertEqual(second.read_bytes(), b"old-two")

            with mock.patch.object(Path, "is_file", return_value=True), mock.patch.object(
                self.runner.subprocess,
                "run",
                side_effect=[help_result, bounds_result],
            ):
                manager = self.runner.RecordingManager(directory, ffmpeg, overwrite=True)
                manager.preflight([("LD-01", "one"), ("W-01", "two")])
            self.assertFalse(first.exists())
            self.assertFalse(second.exists())

    def test_cleanup_terminates_processes_and_removes_only_temporary_residue(self):
        class RunningProcess:
            def poll(self):
                return None

        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            output = directory / "W-01-label.mp4"
            output.write_bytes(b"finalized")
            recorder = self.runner.ScreenRecorder(
                output, directory / "ffmpeg", Rect(0, 0, 100, 100)
            )
            recorder.capture_output.write_bytes(b"capture")
            recorder.encoding_output.write_bytes(b"encoding")
            recorder.process = RunningProcess()
            recorder.encoding_process = RunningProcess()
            with mock.patch.object(
                self.runner, "terminate_process_group"
            ) as terminate:
                recorder.cleanup()
            self.assertEqual(terminate.call_count, 2)
            self.assertFalse(recorder.capture_output.exists())
            self.assertFalse(recorder.encoding_output.exists())
            self.assertEqual(output.read_bytes(), b"finalized")

    def test_finalization_explicitly_encodes_h264_playable_mp4(self):
        source = (FIXTURES / "run_qa_macos.py").read_text(encoding="utf-8")
        self.assertIn('"-c:v", "libx264"', source)
        self.assertIn('"-pix_fmt", "yuv420p"', source)
        self.assertIn('"-movflags", "+faststart"', source)

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
        "01-finder-sidebar/project.yml",
        "01-finder-sidebar/HostApp/Info.plist",
        "01-finder-sidebar/FinderExtension/Info.plist",
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

    def test_render_synchronizes_xcode_sources(self):
        rendered = self.bump.render(self.root, "1.2.3", "20260731.4")
        project = rendered[self.root / "01-finder-sidebar/project.yml"]
        self.assertIn('MARKETING_VERSION: "1.2.3"', project)
        self.assertIn('CURRENT_PROJECT_VERSION: "20260731.4"', project)
        for relative in (
            "01-finder-sidebar/HostApp/Info.plist",
            "01-finder-sidebar/FinderExtension/Info.plist",
        ):
            info = plistlib.loads(rendered[self.root / relative].encode())
            self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
            self.assertEqual(info["CFBundleVersion"], "20260731.4")

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
