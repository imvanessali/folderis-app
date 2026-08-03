#!/usr/bin/env python3
"""Run the real-fixture Folderis built-in-skill QA round on macOS.

The canonical fixtures are never modified: every invocation first calls
reset_test_folder.sh and operates only on the refreshed writable copy.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

from qa_support import (
    MARKER,
    Rect,
    cancellation_probe,
    load_dispatch_cases,
    parse_named_window_rects,
    parse_dispatch_payload,
    recording_crop_from_windows,
    recorder_command,
    sha256,
    snapshot_files,
    terminate_process_group,
)
from qa_semantic_validators import validate_structural_case
from qa_structural_cases import structural_cases


HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SOURCE_SKILLS = REPO / "01-finder-sidebar" / "skills" / "skills.py"
DEFAULT_WORK = Path.home() / "Downloads" / "Test Folderis"
DEFAULT_EVIDENCE = Path.home() / "Downloads" / "Folderis QA Evidence"
WINDOW_SCRIPT = r'''
tell application "System Events"
  set windowLines to {}
  if exists process "Finder" then
    tell process "Finder"
      repeat with w in windows
        if not (value of attribute "AXMinimized" of w) then
          set p to position of w
          set s to size of w
          set end of windowLines to "Finder" & tab & (item 1 of p) & tab & (item 2 of p) & tab & (item 1 of s) & tab & (item 2 of s)
        end if
      end repeat
    end tell
  end if
  if exists process "Folderis" then
    tell process "Folderis"
      repeat with w in windows
        if not (value of attribute "AXMinimized" of w) then
          set p to position of w
          set s to size of w
          set end of windowLines to "Folderis" & tab & (item 1 of p) & tab & (item 2 of p) & tab & (item 1 of s) & tab & (item 2 of s)
        end if
      end repeat
    end tell
  end if
  set AppleScript's text item delimiters to linefeed
  return windowLines as text
end tell
'''
ACTIVATE_FINDER_WINDOW_SCRIPT = r'''
on run argv
  set targetX to (item 1 of argv) as integer
  set targetY to (item 2 of argv) as integer
  set targetWidth to (item 3 of argv) as integer
  set targetHeight to (item 4 of argv) as integer
  tell application "System Events"
    if not (exists process "Finder") then error "Finder is not running"
    tell process "Finder"
      set frontmost to true
      repeat with w in windows
        try
          if not (value of attribute "AXMinimized" of w) then
            set p to position of w
            set s to size of w
            if (item 1 of p) = targetX and (item 2 of p) = targetY and ¬
              (item 1 of s) = targetWidth and (item 2 of s) = targetHeight then
              perform action "AXRaise" of w
              return "raised"
            end if
          end if
        end try
      end repeat
    end tell
  end tell
  error "The Finder window approved at recording preflight is no longer available"
end run
'''
TOGGLE_FOLDERIS_PANEL_SCRIPT = r'''
tell application "System Events"
  if not (exists process "Folderis") then error "Folderis is not running"
  tell process "Folderis"
    repeat with mb in menu bars
      repeat with statusItem in menu bar items of mb
        try
          if (role description of statusItem as text) is "status menu" then
            perform action "AXPress" of statusItem
            delay 0.1
            if exists menu item "显示/隐藏聊天面板" of menu 1 of statusItem then
              click menu item "显示/隐藏聊天面板" of menu 1 of statusItem
              return "toggled"
            end if
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
error "Folderis status action 显示/隐藏聊天面板 was not found"
'''
WINDOW_Z_ORDER_JXA = r'''
ObjC.import("AppKit");
ObjC.import("CoreGraphics");

function firstPID(bundleIdentifier) {
  var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleIdentifier);
  return Number(apps.count) ? Number(apps.objectAtIndex(0).processIdentifier) : -1;
}

var raw = $.CGWindowListCopyWindowInfo(1, 0); // on-screen only, relative to all windows
var windows = ObjC.castRefToObject(raw);
var output = [];
for (var index = 0; index < Number(windows.count); index++) {
  var item = ObjC.deepUnwrap(windows.objectAtIndex(index));
  if (item.kCGWindowLayer === 0) {
    output.push({
      z: index,
      owner: item.kCGWindowOwnerName || "",
      owner_pid: Number(item.kCGWindowOwnerPID),
      name: item.kCGWindowName || "",
      number: Number(item.kCGWindowNumber),
      layer: Number(item.kCGWindowLayer),
      alpha: Number(item.kCGWindowAlpha),
      bounds: item.kCGWindowBounds
    });
  }
}
JSON.stringify({
  finder_pid: firstPID("com.apple.finder"),
  folderis_pid: firstPID("com.local.findersidebar.host"),
  windows: output
});
'''


class QAError(RuntimeError):
    pass


class WindowOcclusionError(QAError):
    pass


def recording_filename(task_id: str, label: str) -> str:
    """Return a stable, readable filename safe for common filesystems."""
    clean_id = re.sub(r"[^A-Za-z0-9._-]+", "-", task_id.strip()).strip("._-")
    clean_label = unicodedata.normalize("NFKC", label).strip()
    clean_label = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "-", clean_label)
    clean_label = re.sub(r"\s+", "-", clean_label)
    clean_label = re.sub(r"-+", "-", clean_label).strip(" .-")
    if not clean_id or not clean_label:
        raise QAError(f"Recording task needs a usable ID and label: {task_id!r}, {label!r}")
    return f"{clean_id}-{clean_label}.mp4"


def read_recording_windows() -> list[tuple[str, Rect]]:
    bounds = subprocess.run(
        ["osascript", "-e", WINDOW_SCRIPT],
        capture_output=True,
        text=True,
    )
    if bounds.returncode != 0:
        raise QAError(
            "Unable to read Finder/Folderis window bounds. Grant Accessibility "
            f"permission to the terminal running QA. Detail: {bounds.stderr.strip()}"
        )
    return parse_named_window_rects(bounds.stdout)


def activate_exact_finder_window(finder: Rect) -> None:
    """Raise the approved Finder window without clicking or changing selection."""
    activated = subprocess.run(
        [
            "osascript", "-e", ACTIVATE_FINDER_WINDOW_SCRIPT, "--",
            str(finder.x), str(finder.y), str(finder.width), str(finder.height),
        ],
        capture_output=True,
        text=True,
    )
    if activated.returncode != 0:
        raise QAError(
            "Unable to reactivate the Finder window approved at preflight without "
            f"changing its geometry. Detail: {activated.stderr.strip()}"
        )


def toggle_folderis_panel() -> None:
    toggled = subprocess.run(
        ["osascript", "-e", TOGGLE_FOLDERIS_PANEL_SCRIPT],
        capture_output=True,
        text=True,
    )
    if toggled.returncode != 0:
        raise QAError(
            "Unable to use Folderis status action 显示/隐藏聊天面板. "
            f"Detail: {toggled.stderr.strip()}"
        )


def read_window_z_order() -> dict:
    result = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", WINDOW_Z_ORDER_JXA],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise QAError(
            "Unable to read authoritative on-screen window z-order with CoreGraphics. "
            f"Detail: {result.stderr.strip()}"
        )
    try:
        payload = json.loads(result.stdout)
        if (
            not isinstance(payload.get("windows"), list)
            or not isinstance(payload.get("finder_pid"), int)
            or not isinstance(payload.get("folderis_pid"), int)
        ):
            raise ValueError("missing PID or window list")
        return payload
    except (json.JSONDecodeError, AttributeError, ValueError) as exc:
        raise QAError(f"CoreGraphics window z-order returned invalid JSON: {exc}") from exc


def rect_from_window_layer(window: dict) -> Rect:
    try:
        bounds = window["bounds"]
        return Rect(
            int(bounds["X"]),
            int(bounds["Y"]),
            int(bounds["Width"]),
            int(bounds["Height"]),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise QAError(f"CoreGraphics window has invalid bounds: {window!r}") from exc


def rects_intersect(first: Rect, second: Rect) -> bool:
    return (
        max(first.x, second.x) < min(first.right, second.right)
        and max(first.y, second.y) < min(first.bottom, second.bottom)
    )


def verify_on_screen_window_coverage(
    approved_windows: list[tuple[str, Rect]],
    snapshot: dict,
) -> None:
    """Prove the approved pair owns the visible layer-0 pixels in its rectangles."""
    approved = {name: rect for name, rect in approved_windows}
    if len(approved_windows) != 2 or set(approved) != {"Finder", "Folderis"}:
        raise QAError("Visible-content verification needs one approved Finder and Folderis")
    try:
        target_pids = {
            "Finder": snapshot["finder_pid"],
            "Folderis": snapshot["folderis_pid"],
        }
        windows = snapshot["windows"]
    except (KeyError, TypeError) as exc:
        raise QAError(f"CoreGraphics snapshot is incomplete: {snapshot!r}") from exc
    if any(pid <= 0 for pid in target_pids.values()):
        raise QAError(f"CoreGraphics could not resolve target application PIDs: {target_pids}")
    targets: dict[str, tuple[int, dict]] = {}
    for name, target_rect in approved.items():
        matches = [
            (index, window)
            for index, window in enumerate(windows)
            if window.get("layer") == 0
            and window.get("owner_pid") == target_pids[name]
            and rect_from_window_layer(window) == target_rect
        ]
        if len(matches) != 1:
            raise WindowOcclusionError(
                f"CoreGraphics did not find exactly one on-screen {name} window at "
                f"{target_rect} (found {len(matches)})"
            )
        try:
            opaque = float(matches[0][1].get("alpha", 0)) >= 1
        except (TypeError, ValueError):
            opaque = False
        if not opaque:
            raise WindowOcclusionError(
                f"CoreGraphics cannot prove opaque on-screen {name} content"
            )
        targets[name] = matches[0]

    related_pids = set(target_pids.values())
    for name, (target_index, _) in targets.items():
        target_rect = approved[name]
        for covering in windows[:target_index]:
            if covering.get("layer") != 0 or covering.get("owner_pid") in related_pids:
                continue
            covering_rect = rect_from_window_layer(covering)
            if rects_intersect(target_rect, covering_rect):
                owner = covering.get("owner") or f"PID {covering.get('owner_pid')}"
                raise WindowOcclusionError(
                    f"Unrelated on-screen window {owner!r} is above and intersects the "
                    f"approved {name} rectangle"
                )


def wait_for_approved_geometry(
    approved_windows: list[tuple[str, Rect]],
    approved_crop: Rect,
    *,
    read_windows=read_recording_windows,
    wait=time.sleep,
    attempts: int = 20,
    wait_seconds: float = 0.1,
) -> None:
    approved_geometry = sorted(approved_windows, key=lambda item: item[0])
    last_error = "Folderis panel did not become visible"
    for attempt in range(attempts):
        try:
            current_windows = read_windows()
            current_crop = recording_crop_from_windows(current_windows)
            current_geometry = sorted(current_windows, key=lambda item: item[0])
            if current_crop != approved_crop or current_geometry != approved_geometry:
                raise QAError(
                    "Finder/Folderis recording geometry changed after preflight; "
                    f"approved crop={approved_crop}, current crop={current_crop}"
                )
            return
        except (QAError, ValueError) as exc:
            last_error = str(exc)
        if attempt + 1 < attempts:
            wait(wait_seconds)
    raise QAError(last_error)


def wait_for_panel_hidden(
    approved_finder: Rect,
    *,
    read_windows=read_recording_windows,
    wait=time.sleep,
    attempts: int = 20,
    wait_seconds: float = 0.1,
) -> None:
    last_error = "Folderis panel remained visible"
    for attempt in range(attempts):
        current = read_windows()
        finder = [rect for name, rect in current if name == "Finder"]
        folderis = [rect for name, rect in current if name == "Folderis"]
        if finder == [approved_finder] and not folderis:
            return
        last_error = (
            "Folderis panel did not hide cleanly or Finder geometry changed "
            f"(Finder={finder}, Folderis={folderis})"
        )
        if attempt + 1 < attempts:
            wait(wait_seconds)
    raise QAError(last_error)


def prepare_task_recording_windows(
    approved_windows: list[tuple[str, Rect]],
    approved_crop: Rect,
    *,
    activate_finder=activate_exact_finder_window,
    read_windows=read_recording_windows,
    toggle_panel=toggle_folderis_panel,
    read_z_order=read_window_z_order,
    verify_coverage=verify_on_screen_window_coverage,
    wait=time.sleep,
    attempts: int = 20,
    wait_seconds: float = 0.1,
) -> None:
    """Restore and prove the approved foreground content before one recording."""
    approved_finders = [rect for name, rect in approved_windows if name == "Finder"]
    if len(approved_finders) != 1:
        raise QAError("Recording preflight did not retain exactly one approved Finder window")
    activate_finder(approved_finders[0])
    current_windows = read_windows()
    if not [rect for name, rect in current_windows if name == "Folderis"]:
        toggle_panel()
    try:
        wait_for_approved_geometry(
            approved_windows,
            approved_crop,
            read_windows=read_windows,
            wait=wait,
            attempts=attempts,
            wait_seconds=wait_seconds,
        )
        verify_coverage(approved_windows, read_z_order())
        return
    except WindowOcclusionError:
        # AX geometry can describe a panel that is behind another app. Cycling
        # the status action is the supported way to order its actual pixels front.
        toggle_panel()
        wait_for_panel_hidden(
            approved_finders[0],
            read_windows=read_windows,
            wait=wait,
            attempts=attempts,
            wait_seconds=wait_seconds,
        )
        activate_finder(approved_finders[0])
        # Show the panel last. Raising Finder after this point can leave AX
        # geometry intact while putting the panel's actual pixels behind Orca.
        toggle_panel()
        wait_for_approved_geometry(
            approved_windows,
            approved_crop,
            read_windows=read_windows,
            wait=wait,
            attempts=attempts,
            wait_seconds=wait_seconds,
        )
        verify_coverage(approved_windows, read_z_order())


class ScreenRecorder:
    """One task-scoped recorder using a crop already approved by preflight."""

    def __init__(self, output: Path, ffmpeg: Path, crop):
        self.output = output
        self.capture_output = output.with_name(f".{output.stem}.capture.mov")
        self.encoding_output = output.with_name(f".{output.stem}.encoding.mp4")
        self.ffmpeg = ffmpeg
        self.crop = crop
        self.process: subprocess.Popen | None = None
        self.encoding_process: subprocess.Popen | None = None
        self.command: list[str] | None = None

    def start(self) -> None:
        self.capture_output.unlink(missing_ok=True)
        self.encoding_output.unlink(missing_ok=True)
        self.command = recorder_command(self.capture_output, self.crop)
        try:
            self.process = subprocess.Popen(
                self.command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            time.sleep(1.0)
            if self.process.poll() is not None:
                _, stderr = self.process.communicate()
                raise QAError(
                    "Screen recording could not start. Enable System Settings → Privacy & "
                    "Security → Screen Recording for the terminal/Orca, then retry. "
                    f"Recorder detail: {stderr.strip() or 'no diagnostic'}"
                )
        except BaseException:
            self.cleanup()
            raise

    def stop(self) -> None:
        try:
            if not self.process:
                return
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGINT)
                    self.process.wait(timeout=10)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    terminate_process_group(self.process)
            _, stderr = self.process.communicate()
            if not self.capture_output.is_file() or self.capture_output.stat().st_size == 0:
                raise QAError(
                    "Screen recording produced no video. Enable System Settings → Privacy & "
                    "Security → Screen Recording for the terminal/Orca and retry. "
                    f"Recorder detail: {stderr.strip() or 'no diagnostic'}"
                )
            self.encoding_process = subprocess.Popen(
                [
                    str(self.ffmpeg), "-y", "-i", str(self.capture_output),
                    "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(self.encoding_output),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            _, encode_stderr = self.encoding_process.communicate()
            if (
                self.encoding_process.returncode
                or not self.encoding_output.is_file()
                or self.encoding_output.stat().st_size == 0
            ):
                raise QAError(
                    "Screen recording finished but H.264 MP4 finalization failed. "
                    f"ffmpeg detail: {encode_stderr[-500:]}"
                )
            os.replace(self.encoding_output, self.output)
        finally:
            self.cleanup()

    def cleanup(self) -> None:
        for process in (self.encoding_process, self.process):
            if process and process.poll() is None:
                terminate_process_group(process)
        self.encoding_process = None
        self.process = None
        self.encoding_output.unlink(missing_ok=True)
        self.capture_output.unlink(missing_ok=True)


class RecordingManager:
    """Preflight and run deterministic, isolated recordings for known QA tasks."""

    def __init__(
        self,
        directory: Path,
        ffmpeg: Path,
        overwrite: bool = False,
        *,
        window_preparer=prepare_task_recording_windows,
    ):
        self.directory = directory.resolve()
        self.ffmpeg = ffmpeg
        self.overwrite = overwrite
        self.crop = None
        self.approved_windows: list[tuple[str, Rect]] = []
        self.outputs: dict[str, Path] = {}
        self.active: ScreenRecorder | None = None
        self.window_preparer = window_preparer

    def preflight(self, tasks: list[tuple[str, str]]) -> None:
        recorder = Path("/usr/sbin/screencapture")
        if not recorder.is_file():
            raise QAError(
                "Screen recording is unavailable: /usr/sbin/screencapture is missing. "
                "Run QA on a supported macOS host or omit --record-screen."
            )
        support = subprocess.run([str(recorder), "-h"], capture_output=True, text=True)
        help_text = (support.stdout or "") + (support.stderr or "")
        if "-v" not in help_text or "-R<x,y,w,h>" not in help_text:
            raise QAError(
                "This macOS screencapture build does not support cropped video recording "
                "(-v with -R). Upgrade macOS or omit --record-screen."
            )
        if not self.ffmpeg.is_file():
            raise QAError(
                f"MP4 recorder support is unavailable because ffmpeg was not found: {self.ffmpeg}"
            )
        self.outputs = {
            task_id: self.directory / recording_filename(task_id, label)
            for task_id, label in tasks
        }
        if len(self.outputs) != len(tasks) or len(set(self.outputs.values())) != len(tasks):
            raise QAError("Recording task IDs and filenames must be unique")
        conflicts = [
            path
            for output in self.outputs.values()
            for path in (
                output,
                output.with_name(f".{output.stem}.capture.mov"),
                output.with_name(f".{output.stem}.encoding.mp4"),
            )
            if path.exists() or path.is_symlink()
        ]
        if conflicts and not self.overwrite:
            preview = ", ".join(str(path) for path in conflicts[:5])
            extra = f" (+{len(conflicts) - 5} more)" if len(conflicts) > 5 else ""
            raise QAError(
                f"Recording evidence already exists: {preview}{extra}. Move the complete "
                "recording directory or pass --overwrite-evidence."
            )
        non_files = [path for path in conflicts if path.is_dir()]
        if non_files:
            raise QAError(
                "Recording evidence paths must be files, not directories: "
                + ", ".join(str(path) for path in non_files)
            )
        try:
            self.approved_windows = read_recording_windows()
            self.crop = recording_crop_from_windows(self.approved_windows)
        except ValueError as exc:
            raise QAError(str(exc)) from exc
        self.directory.mkdir(parents=True, exist_ok=True)
        # All conflicts are resolved only after every task and the crop have passed
        # preflight, so a later validation error cannot partially delete evidence.
        for path in conflicts:
            path.unlink()

    def start_task(self, task_id: str) -> dict:
        output = self.outputs[task_id]
        recording = {"path": str(output), "status": "recording", "error": None}
        try:
            self.window_preparer(self.approved_windows, self.crop)
            self.active = ScreenRecorder(output, self.ffmpeg, self.crop)
            self.active.start()
        except BaseException as exc:
            recording["status"] = "ERROR"
            recording["error"] = (
                str(exc)
                if self.active
                else (
                    "Unsafe per-task recording state; screencapture was not started. "
                    f"Detail: {exc}"
                )
            )
            if self.active:
                self.active.cleanup()
            self.active = None
        return recording

    def stop_task(self, recording: dict) -> None:
        if not self.active:
            return
        try:
            self.active.stop()
            recording["status"] = "RECORDED"
        except BaseException as exc:
            recording["status"] = "ERROR"
            recording["error"] = str(exc)
        finally:
            self.active.cleanup()
            self.active = None

    def cleanup(self) -> None:
        if self.active:
            self.active.cleanup()
            self.active = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Folderis macOS real-fixture QA")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK)
    parser.add_argument("--runtime-root", type=Path, help="runtime containing python/, skills/, bin/")
    parser.add_argument("--skills", type=Path, help="explicit skills.py (defaults to runtime or source)")
    parser.add_argument("--python", type=Path, help="explicit Python executable")
    parser.add_argument("--report", type=Path, default=DEFAULT_EVIDENCE / "qa-macos-results.json")
    parser.add_argument(
        "--record-screen",
        action="store_true",
        help=(
            "record one H.264 MP4 per QA task using only one strictly gap-free Finder + "
            "Folderis area (extra or separated windows fail)"
        ),
    )
    parser.add_argument(
        "--recording-directory",
        type=Path,
        default=DEFAULT_EVIDENCE / "recordings",
        help="directory for per-task MP4 evidence (default: %(default)s)",
    )
    parser.add_argument(
        "--recording-output",
        type=Path,
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--overwrite-evidence", action="store_true")
    parser.add_argument("--skip-cancellation", action="store_true", help="diagnostic escape hatch; not a complete QA round")
    args = parser.parse_args()
    if args.recording_output is not None:
        parser.error(
            "--recording-output was replaced by --recording-directory because QA now "
            "writes one MP4 per task; pass the destination directory instead"
        )
    return args


def resolve_runtime(args: argparse.Namespace) -> tuple[Path, Path, dict[str, str]]:
    runtime = args.runtime_root
    if runtime:
        python = args.python or runtime / "python" / "bin" / "python3"
        skills = args.skills or runtime / "skills" / "skills.py"
        env = {
            "FS_FFMPEG": str(runtime / "bin" / "ffmpeg"),
            "FS_FFPROBE": str(runtime / "bin" / "ffprobe"),
        }
    else:
        packaged_pythons = [
            Path.home() / "Library" / "Application Support" / "FinderSidebar" / "python" / "bin" / "python3",
            Path("/Applications/Folderis.app/Contents/Resources/runtime/python/bin/python3.12"),
        ]
        python = args.python or next(
            (candidate for candidate in packaged_pythons if candidate.is_file()),
            Path(sys.executable),
        )
        skills = args.skills or SOURCE_SKILLS
        support = Path.home() / "Library" / "Application Support" / "FinderSidebar" / "bin"
        env = {
            "FS_FFMPEG": str(support / "ffmpeg"),
            "FS_FFPROBE": str(support / "ffprobe"),
        }
    for label, path in (("Python", python), ("skills.py", skills)):
        if not path.is_file():
            raise QAError(f"{label} not found: {path}")
    return python, skills, env


def media_probe(ffprobe: Path, path: Path) -> dict:
    result = subprocess.run(
        [str(ffprobe), "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise QAError(f"ffprobe failed for {path.name}: {result.stderr[-400:]}")
    return json.loads(result.stdout)


def duration(probe: dict) -> float:
    return float(probe["format"]["duration"])


def run_command(
    python: Path,
    skills: Path,
    cwd: Path,
    args: list[str],
    env_extra: dict[str, str],
    timeout: int = 300,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env.update(env_extra)
    return subprocess.run(
        [str(python), str(skills), *args],
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def recording_tasks(
    dispatch_cases: list[dict],
    workflow_cases: list[dict],
    include_cancellation: bool,
) -> list[tuple[str, str]]:
    tasks = [(case["id"], case["label"]) for case in dispatch_cases]
    tasks.append(("ART-COLLISION", "重复转换碰撞"))
    tasks.extend((case["id"], case["label"]) for case in workflow_cases)
    if include_cancellation:
        tasks.append(("CANCEL-01", "视频压缩取消"))
    return tasks


def run_recorded_action(manager: RecordingManager | None, task_id: str, action):
    """Run an action even if recording fails, always finalizing its recorder."""
    recording = manager.start_task(task_id) if manager else None
    try:
        value = action()
    finally:
        if manager and recording:
            manager.stop_task(recording)
    return value, recording


def recording_passed(recording: dict | None) -> bool:
    return recording is None or recording["status"] == "RECORDED"


def main() -> int:
    if sys.platform != "darwin":
        raise QAError("run_qa_macos.py must run on macOS")
    args = parse_args()
    python, skills, env_extra = resolve_runtime(args)
    dispatch_cases = load_dispatch_cases()
    workflow_cases = structural_cases()
    ffmpeg = Path(env_extra["FS_FFMPEG"])
    recorder = (
        RecordingManager(args.recording_directory, ffmpeg, args.overwrite_evidence)
        if args.record_screen
        else None
    )
    if recorder:
        recorder.preflight(
            recording_tasks(dispatch_cases, workflow_cases, not args.skip_cancellation)
        )

    reset = subprocess.run([str(HERE / "reset_test_folder.sh"), str(args.work_dir)], text=True)
    if reset.returncode:
        raise QAError("Fixture reset failed; QA did not start")

    work = args.work_dir.resolve()
    baseline = snapshot_files(work)
    results: list[dict] = []
    structural_results: list[dict] = []
    payloads: dict[str, dict] = {}
    ffprobe = Path(env_extra["FS_FFPROBE"])

    try:
        for case in dispatch_cases:
            cwd = work / case["cwd"]
            selected = [str((cwd / name).resolve()) for name in case["files"]]
            command = ["local-dispatch", "--request", case["request"], "--files", *selected]
            started = time.time()
            completed, recording = run_recorded_action(
                recorder,
                case["id"],
                lambda: run_command(python, skills, cwd, command, env_extra),
            )
            try:
                payload = parse_dispatch_payload(completed.stdout)
                passed = payload.get("matched") is case["expect_matched"]
                if case["expect_matched"]:
                    passed = passed and payload.get("success") and payload.get("skill") == case["expect_skill"]
                else:
                    passed = passed and not payload.get("outputs")
            except Exception as exc:
                payload, passed = {"parse_error": str(exc)}, False
            passed = passed and recording_passed(recording)
            payloads[case["id"]] = payload
            results.append({
                "id": case["id"],
                "label": case["label"],
                "status": "PASS" if passed else "FAIL",
                "selected_inputs": selected,
                "ai_bypassed": True,
                "elapsed": round(time.time() - started, 2),
                "payload": payload,
                "recording": recording,
            })
            print(f"[{'PASS' if passed else 'FAIL'}] {case['id']} {case['label']}")

        # Repeat conversion to prove deterministic _2 collision behavior.
        collision_case = next(case for case in dispatch_cases if case["id"] == "LD-02")
        collision_cwd = work / collision_case["cwd"]
        collision, collision_recording = run_recorded_action(
            recorder,
            "ART-COLLISION",
            lambda: run_command(
                python,
                skills,
                collision_cwd,
                ["local-dispatch", "--request", collision_case["request"], "--files",
                 str((collision_cwd / collision_case["files"][0]).resolve())],
                env_extra,
            ),
        )
        collision_payload = parse_dispatch_payload(collision.stdout)
        collision_names = [Path(path).name for path in collision_payload.get("outputs", [])]
        expected_collision = "michail-sapiton-alCEnNmzhPE-unsplash_2.webp"
        collision_ok = (
            collision_names == [expected_collision]
            and recording_passed(collision_recording)
        )
        results.append({
            "id": "ART-COLLISION",
            "label": "重复转换碰撞",
            "status": "PASS" if collision_ok else "FAIL",
            "expected_output": expected_collision,
            "actual_outputs": collision_names,
            "recording": collision_recording,
        })

        from PIL import Image
        from pypdf import PdfReader

        crop = Path(payloads["LD-01"]["outputs"][0])
        with Image.open(crop) as image:
            crop_ok = image.size == (800, 600) and image.format in {"JPEG", "JPG"}
            crop_detail = {"name": crop.name, "format": image.format, "dimensions": list(image.size)}
        results.append({"id": "ART-CROP", "status": "PASS" if crop_ok else "FAIL", **crop_detail})

        webp = Path(payloads["LD-02"]["outputs"][0])
        with Image.open(webp) as image:
            webp_ok = image.format == "WEBP"
            webp_detail = {"name": webp.name, "format": image.format, "dimensions": list(image.size)}
        results.append({"id": "ART-WEBP", "status": "PASS" if webp_ok else "FAIL", **webp_detail})

        csv_path = Path(payloads["LD-03"]["outputs"][0])
        with csv_path.open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.reader(stream))
        results.append({
            "id": "ART-CSV",
            "status": "PASS" if csv_path.name == "样例数据.csv" and len(rows) > 1 else "FAIL",
            "name": csv_path.name,
            "format": "csv/utf-8-sig",
            "rows": len(rows),
        })

        pdf = Path(payloads["LD-04"]["outputs"][0])
        pages = len(PdfReader(str(pdf)).pages)
        results.append({
            "id": "ART-PDF",
            "status": "PASS" if pdf.name == "ai_agents_handbook_pages_2-5_2.pdf" and pages == 4 else "FAIL",
            "name": pdf.name,
            "format": "PDF",
            "pages": pages,
        })

        gif = Path(payloads["LD-05"]["outputs"][0])
        with Image.open(gif) as image:
            frames = getattr(image, "n_frames", 1)
            gif_ms = sum(
                (image.seek(index), image.info.get("duration", 0))[1]
                for index in range(frames)
            )
            gif_ok = image.format == "GIF" and image.width == 480 and 4_000 <= gif_ms <= 5_500
            gif_detail = {
                "name": gif.name,
                "format": image.format,
                "dimensions": [image.width, image.height],
                "duration_seconds": round(gif_ms / 1000, 3),
                "fps_requested": 12,
            }
        results.append({"id": "ART-GIF", "status": "PASS" if gif_ok else "FAIL", **gif_detail})

        if not ffprobe.is_file():
            fallback_probe = shutil.which("ffprobe")
            if not fallback_probe:
                raise QAError(f"ffprobe not found: {ffprobe}")
            ffprobe = Path(fallback_probe)
        source_video = work / "Test Video" / "file_example_MP4_1280_10MG.mp4"
        compressed = Path(payloads["LD-11"]["outputs"][0])
        source_probe = media_probe(ffprobe, source_video)
        compressed_probe = media_probe(ffprobe, compressed)
        source_duration, compressed_duration = duration(source_probe), duration(compressed_probe)
        video_stream = next(stream for stream in compressed_probe["streams"] if stream["codec_type"] == "video")
        video_ok = (
            compressed.suffix.lower() == ".mp4"
            and video_stream["codec_name"] == "h264"
            and abs(source_duration - compressed_duration) <= max(0.5, source_duration * 0.02)
        )
        results.append({
            "id": "ART-VIDEO",
            "status": "PASS" if video_ok else "FAIL",
            "name": compressed.name,
            "format": "MP4",
            "codec": video_stream["codec_name"],
            "crf_requested": 28,
            "source_duration": source_duration,
            "output_duration": compressed_duration,
        })

        audio_dir = work / "Test Audio"
        joined = run_command(
            python, skills, audio_dir,
            ["audio-concat", "clip_a.wav", "clip_b.wav", "--output", "joined.wav"],
            env_extra,
        )
        joined_path = audio_dir / "joined.wav"
        with wave.open(str(audio_dir / "clip_a.wav")) as first, wave.open(str(audio_dir / "clip_b.wav")) as second:
            expected_audio = first.getnframes() / first.getframerate() + second.getnframes() / second.getframerate()
        with wave.open(str(joined_path)) as output_audio:
            actual_audio = output_audio.getnframes() / output_audio.getframerate()
        results.append({
            "id": "ART-AUDIO",
            "status": "PASS" if joined.returncode == 0 and abs(expected_audio - actual_audio) <= 0.1 else "FAIL",
            "name": joined_path.name,
            "format": "WAV",
            "source_duration_sum": expected_audio,
            "output_duration": actual_audio,
        })

        image_dir = work / "Test Image"
        hash_targets = [
            image_dir / "michail-sapiton-alCEnNmzhPE-unsplash.jpg",
            image_dir / "marko-brecic-Z9P2g8TuTdA-unsplash.png",
        ]
        hashed = run_command(
            python, skills, image_dir,
            ["hash-files", *map(str, hash_targets), "--algo", "sha256"],
            env_extra,
        )
        digests = {str(path): sha256(path) for path in hash_targets}
        hash_ok = hashed.returncode == 0 and all(digest in hashed.stdout for digest in digests.values())
        results.append({
            "id": "ART-HASH",
            "status": "PASS" if hash_ok else "FAIL",
            "algorithm": "sha256",
            "selected_inputs": [str(path) for path in hash_targets],
            "digests": digests,
        })

        # Execute the established 47-case real-fixture round. Each row runs one
        # built-in skill workflow and receives a command-specific semantic
        # validator; there are no padding/aggregate PASS rows.
        for case in workflow_cases:
            cwd = work / case["cwd"]
            selected_paths = [(cwd / item).resolve() for item in case["inputs"]]
            selected_inputs = [str(path) for path in selected_paths]
            input_hashes = {
                str(path): sha256(path)
                for path in selected_paths
                if path.is_file()
            }
            before = snapshot_files(work)
            started = time.time()
            completed, recording = run_recorded_action(
                recorder,
                case["id"],
                lambda: run_command(python, skills, cwd, case["args"], env_extra),
            )
            after = snapshot_files(work)
            outputs = [
                work / relative
                for relative in sorted(set(after) - set(before))
            ]
            inputs_preserved = all(
                path.is_file() and sha256(path) == digest
                for name, digest in input_hashes.items()
                for path in [Path(name)]
            )
            failure = None
            evidence = {}
            if completed.returncode != 0:
                failure = (
                    f"skill exited {completed.returncode}: "
                    f"{((completed.stderr or '') + (completed.stdout or ''))[-800:].strip()}"
                )
            else:
                try:
                    evidence = validate_structural_case(
                        case,
                        work=work,
                        cwd=cwd,
                        inputs=selected_paths,
                        outputs=outputs,
                        stdout=(completed.stdout or "") + (completed.stderr or ""),
                        ffprobe=ffprobe,
                        run_skill=lambda skill_cwd, skill_args: run_command(
                            python, skills, skill_cwd, skill_args, env_extra
                        ),
                    )
                    if not inputs_preserved:
                        failure = "one or more selected input files changed"
                except Exception as exc:
                    failure = f"semantic validation failed: {exc}"
            if not recording_passed(recording):
                recording_error = recording["error"] if recording else "unknown recording error"
                failure = (
                    f"{failure}; recording failed: {recording_error}"
                    if failure
                    else f"recording failed: {recording_error}"
                )
            status = "PASS" if failure is None else "FAIL"
            structural_results.append({
                "id": case["id"],
                "label": case["label"],
                "status": status,
                "skill": case["args"][0],
                "selected_inputs": selected_inputs,
                "actual_outputs": [str(path) for path in outputs],
                "parameters": case["parameters"],
                "inputs_preserved": inputs_preserved,
                "ai_bypassed": True,
                "elapsed": round(time.time() - started, 2),
                "evidence": evidence,
                "failure": failure,
                "recording": recording,
            })
            print(f"[{status}] {case['id']} {case['label']}")

        if len(structural_results) != 47:
            raise QAError(
                f"Structural QA definition error: executed {len(structural_results)} rows, expected 47"
            )

        if not args.skip_cancellation:
            cancel_command = [
                str(python), str(skills), "local-dispatch", "--request", "压缩这个视频",
                "--files", str(source_video),
            ]
            cancel, cancel_recording = run_recorded_action(
                recorder,
                "CANCEL-01",
                lambda: cancellation_probe(
                    cancel_command, source_video.parent, source_video.parent
                ),
            )
            cancel_ok = (
                not cancel["process_group_alive"]
                and not cancel["residual_outputs"]
                and recording_passed(cancel_recording)
            )
            results.append({
                "id": "CANCEL-01",
                "label": "视频压缩取消",
                "status": "PASS" if cancel_ok else "FAIL",
                "selected_inputs": [str(source_video)],
                "process_cleanup": not cancel["process_group_alive"],
                "residual_outputs": cancel["residual_outputs"],
                "note": "A residual output is reported as a Folderis product failure and is not deleted by QA.",
                "recording": cancel_recording,
            })

        current = snapshot_files(work)
        changed_originals = [
            name for name, digest in baseline.items()
            if current.get(name) != digest
        ]
        results.append({
            "id": "ORIGINALS",
            "status": "PASS" if not changed_originals else "FAIL",
            "baseline_file_count": len(baseline),
            "changed_or_missing_originals": changed_originals,
        })
    finally:
        if recorder:
            recorder.cleanup()

    report = {
        "schema_version": 1,
        "platform": "macOS",
        "work_directory": str(work),
        "canonical_fixtures": str(HERE),
        "fixture_reset": True,
        "skills_sha256": sha256(skills),
        "python_executable": str(python),
        "screen_recording_directory": str(args.recording_directory.resolve()) if recorder else None,
        "results": results,
        "structural_validations": structural_results,
        "structural_summary": {
            "required_executed": 47,
            "executed": len(structural_results),
            "passed": sum(item["status"] == "PASS" for item in structural_results),
            "failed": sum(item["status"] == "FAIL" for item in structural_results),
            "skipped": sum(item["status"] == "SKIP" for item in structural_results),
        },
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    failed = [item["id"] for item in [*results, *structural_results] if item["status"] != "PASS"]
    print(f"Report: {args.report}")
    print(
        "Structural validations: "
        f"PASS {report['structural_summary']['passed']} / "
        f"FAIL {report['structural_summary']['failed']} / "
        f"SKIP {report['structural_summary']['skipped']} / "
        f"EXECUTED {report['structural_summary']['executed']}"
    )
    total = len(results) + len(structural_results)
    print(f"All rows: PASS {total - len(failed)} / FAIL {len(failed)} / TOTAL {total}")
    if failed:
        print("Failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (QAError, subprocess.TimeoutExpired, KeyError, IndexError, ValueError) as exc:
        print(f"QA ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
