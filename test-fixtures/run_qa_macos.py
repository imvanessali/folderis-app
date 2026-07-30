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
import shutil
import signal
import subprocess
import sys
import time
import wave
from pathlib import Path

from qa_support import (
    MARKER,
    cancellation_probe,
    load_dispatch_cases,
    parse_dispatch_payload,
    parse_window_rects,
    recorder_command,
    sha256,
    snapshot_files,
    terminate_process_group,
    union_rects,
)


HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SOURCE_SKILLS = REPO / "01-finder-sidebar" / "skills" / "skills.py"
DEFAULT_WORK = Path.home() / "Downloads" / "Test Folderis"
DEFAULT_EVIDENCE = Path.home() / "Downloads" / "Folderis QA Evidence"
WINDOW_SCRIPT = r'''
tell application "System Events"
  set rows to {}
  if exists process "Finder" then
    tell process "Finder"
      if exists window 1 then
        set p to position of window 1
        set s to size of window 1
        set end of rows to "Finder" & tab & (item 1 of p) & tab & (item 2 of p) & tab & (item 1 of s) & tab & (item 2 of s)
      end if
    end tell
  end if
  if exists process "Folderis" then
    tell process "Folderis"
      repeat with w in windows
        if value of attribute "AXVisible" of w then
          set p to position of w
          set s to size of w
          set end of rows to "Folderis" & tab & (item 1 of p) & tab & (item 2 of p) & tab & (item 1 of s) & tab & (item 2 of s)
        end if
      end repeat
    end tell
  end if
  set AppleScript's text item delimiters to linefeed
  return rows as text
end tell
'''


class QAError(RuntimeError):
    pass


class ScreenRecorder:
    def __init__(self, output: Path, ffmpeg: Path, overwrite: bool = False):
        self.output = output
        self.capture_output = output.with_name(f".{output.stem}.capture.mov")
        self.ffmpeg = ffmpeg
        self.overwrite = overwrite
        self.process: subprocess.Popen | None = None
        self.command: list[str] | None = None

    def start(self) -> None:
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
        if self.output.suffix.lower() != ".mp4":
            raise QAError("--recording-output must end in .mp4")
        if self.output.exists() and not self.overwrite:
            raise QAError(
                f"Evidence already exists: {self.output}. Move it or pass --overwrite-evidence."
            )
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
        labels = {line.split("\t", 1)[0] for line in bounds.stdout.splitlines()}
        if not {"Finder", "Folderis"} <= labels:
            missing = ", ".join(sorted({"Finder", "Folderis"} - labels))
            raise QAError(
                f"No visible window was found for: {missing}. Open Finder and Folderis "
                "before --record-screen; QA will not widen the crop to unrelated desktop areas."
            )
        rects = parse_window_rects(bounds.stdout)
        if not rects:
            raise QAError(
                "No visible Finder + Folderis windows were found. Open both apps before "
                "using --record-screen; recording will never include unrelated desktop areas."
            )
        self.output.parent.mkdir(parents=True, exist_ok=True)
        if self.output.exists():
            self.output.unlink()
        self.capture_output.unlink(missing_ok=True)
        self.command = recorder_command(self.capture_output, union_rects(rects))
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

    def stop(self) -> None:
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
        temporary_mp4 = self.output.with_name(f".{self.output.stem}.encoding.mp4")
        temporary_mp4.unlink(missing_ok=True)
        try:
            encoded = subprocess.run(
                [str(self.ffmpeg), "-y", "-i", str(self.capture_output), "-c", "copy", str(temporary_mp4)],
                capture_output=True,
                text=True,
            )
            if encoded.returncode or not temporary_mp4.is_file() or temporary_mp4.stat().st_size == 0:
                raise QAError(
                    "Screen recording finished but MP4 finalization failed. "
                    f"ffmpeg detail: {encoded.stderr[-500:]}"
                )
            os.replace(temporary_mp4, self.output)
        finally:
            temporary_mp4.unlink(missing_ok=True)
            self.capture_output.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Folderis macOS real-fixture QA")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK)
    parser.add_argument("--runtime-root", type=Path, help="runtime containing python/, skills/, bin/")
    parser.add_argument("--skills", type=Path, help="explicit skills.py (defaults to runtime or source)")
    parser.add_argument("--python", type=Path, help="explicit Python executable")
    parser.add_argument("--report", type=Path, default=DEFAULT_EVIDENCE / "qa-macos-results.json")
    parser.add_argument("--record-screen", action="store_true", help="record only the Finder + Folderis bounding region")
    parser.add_argument("--recording-output", type=Path, default=DEFAULT_EVIDENCE / "folderis-qa-evidence.mp4")
    parser.add_argument("--overwrite-evidence", action="store_true")
    parser.add_argument("--skip-cancellation", action="store_true", help="diagnostic escape hatch; not a complete QA round")
    return parser.parse_args()


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
        python = args.python or Path(sys.executable)
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


def main() -> int:
    if sys.platform != "darwin":
        raise QAError("run_qa_macos.py must run on macOS")
    args = parse_args()
    python, skills, env_extra = resolve_runtime(args)
    reset = subprocess.run([str(HERE / "reset_test_folder.sh"), str(args.work_dir)], text=True)
    if reset.returncode:
        raise QAError("Fixture reset failed; QA did not start")

    work = args.work_dir.resolve()
    baseline = snapshot_files(work)
    results: list[dict] = []
    payloads: dict[str, dict] = {}
    ffmpeg = Path(env_extra["FS_FFMPEG"])
    ffprobe = Path(env_extra["FS_FFPROBE"])
    recorder = ScreenRecorder(args.recording_output, ffmpeg, args.overwrite_evidence) if args.record_screen else None
    if recorder:
        recorder.start()

    try:
        for case in load_dispatch_cases():
            cwd = work / case["cwd"]
            selected = [str((cwd / name).resolve()) for name in case["files"]]
            command = ["local-dispatch", "--request", case["request"], "--files", *selected]
            started = time.time()
            completed = run_command(python, skills, cwd, command, env_extra)
            try:
                payload = parse_dispatch_payload(completed.stdout)
                passed = payload.get("matched") is case["expect_matched"]
                if case["expect_matched"]:
                    passed = passed and payload.get("success") and payload.get("skill") == case["expect_skill"]
                else:
                    passed = passed and not payload.get("outputs")
            except Exception as exc:
                payload, passed = {"parse_error": str(exc)}, False
            payloads[case["id"]] = payload
            results.append({
                "id": case["id"],
                "label": case["label"],
                "status": "PASS" if passed else "FAIL",
                "selected_inputs": selected,
                "ai_bypassed": True,
                "elapsed": round(time.time() - started, 2),
                "payload": payload,
            })
            print(f"[{'PASS' if passed else 'FAIL'}] {case['id']} {case['label']}")

        # Repeat conversion to prove deterministic _2 collision behavior.
        collision_case = next(case for case in load_dispatch_cases() if case["id"] == "LD-02")
        collision_cwd = work / collision_case["cwd"]
        collision = run_command(
            python,
            skills,
            collision_cwd,
            ["local-dispatch", "--request", collision_case["request"], "--files",
             str((collision_cwd / collision_case["files"][0]).resolve())],
            env_extra,
        )
        collision_payload = parse_dispatch_payload(collision.stdout)
        collision_names = [Path(path).name for path in collision_payload.get("outputs", [])]
        expected_collision = "michail-sapiton-alCEnNmzhPE-unsplash_2.webp"
        results.append({
            "id": "ART-COLLISION",
            "status": "PASS" if collision_names == [expected_collision] else "FAIL",
            "expected_output": expected_collision,
            "actual_outputs": collision_names,
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

        if not args.skip_cancellation:
            cancel_command = [
                str(python), str(skills), "local-dispatch", "--request", "压缩这个视频",
                "--files", str(source_video),
            ]
            cancel = cancellation_probe(cancel_command, source_video.parent, source_video.parent)
            results.append({
                "id": "CANCEL-01",
                "status": "PASS" if not cancel["process_group_alive"] and not cancel["residual_outputs"] else "FAIL",
                "selected_inputs": [str(source_video)],
                "process_cleanup": not cancel["process_group_alive"],
                "residual_outputs": cancel["residual_outputs"],
                "note": "A residual output is reported as a Folderis product failure and is not deleted by QA.",
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
            recorder.stop()

    report = {
        "schema_version": 1,
        "platform": "macOS",
        "work_directory": str(work),
        "canonical_fixtures": str(HERE),
        "fixture_reset": True,
        "skills_sha256": sha256(skills),
        "screen_recording": str(args.recording_output) if recorder else None,
        "results": results,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    failed = [item["id"] for item in results if item["status"] != "PASS"]
    print(f"Report: {args.report}")
    print(f"PASS {len(results) - len(failed)} / FAIL {len(failed)} / TOTAL {len(results)}")
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
