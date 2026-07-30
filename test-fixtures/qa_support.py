"""Shared, dependency-light helpers for Folderis macOS and Windows QA."""
from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


MARKER = "__FOLDERIS_LOCAL_RESULT__"
CASES_FILE = Path(__file__).with_name("local_dispatch_cases.json")


def load_dispatch_cases(path: Path = CASES_FILE) -> list[dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1 or not isinstance(payload.get("cases"), list):
        raise ValueError(f"Unsupported local-dispatch case schema: {path}")
    ids = [case.get("id") for case in payload["cases"]]
    if not all(ids) or len(ids) != len(set(ids)):
        raise ValueError(f"Case IDs must be present and unique: {path}")
    return payload["cases"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_files(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def parse_dispatch_payload(stdout: str) -> dict:
    if MARKER not in stdout:
        raise ValueError("local-dispatch result marker was not emitted")
    return json.loads(stdout.rsplit(MARKER, 1)[1].strip().splitlines()[0])


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    width: int
    height: int

    @property
    def right(self) -> int:
        return self.x + self.width

    @property
    def bottom(self) -> int:
        return self.y + self.height


def union_rects(rects: Iterable[Rect], margin: int = 8) -> Rect:
    values = list(rects)
    if not values:
        raise ValueError("Finder and Folderis have no visible windows to record")
    left = min(item.x for item in values)
    top = min(item.y for item in values)
    right = max(item.right for item in values)
    bottom = max(item.bottom for item in values)
    return Rect(
        max(0, left - margin),
        max(0, top - margin),
        right - max(0, left - margin) + margin,
        bottom - max(0, top - margin) + margin,
    )


def parse_window_rects(output: str) -> list[Rect]:
    rects = []
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 5 or fields[0] not in {"Finder", "Folderis"}:
            continue
        x, y, width, height = map(int, fields[1:])
        if width > 0 and height > 0:
            rects.append(Rect(x, y, width, height))
    return rects


def recorder_command(output: Path, rect: Rect) -> list[str]:
    return [
        "/usr/sbin/screencapture",
        "-v",
        f"-R{rect.x},{rect.y},{rect.width},{rect.height}",
        str(output),
    ]


def terminate_process_group(
    process: subprocess.Popen,
    *,
    grace_seconds: float = 3.0,
) -> dict:
    """Terminate a POSIX process group and prove no group member remains."""
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=grace_seconds)
    try:
        os.killpg(process.pid, 0)
        alive = True
    except ProcessLookupError:
        alive = False
    return {"returncode": process.returncode, "process_group_alive": alive}


def cancellation_probe(
    command: list[str],
    cwd: Path,
    watched_directory: Path,
    *,
    settle_seconds: float = 1.0,
) -> dict:
    before = {path.resolve() for path in watched_directory.iterdir() if path.is_file()}
    process = subprocess.Popen(
        command,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    time.sleep(settle_seconds)
    cleanup = terminate_process_group(process)
    stdout, stderr = process.communicate()
    after = {path.resolve() for path in watched_directory.iterdir() if path.is_file()}
    residual = sorted(str(path) for path in after - before)
    return {
        **cleanup,
        "residual_outputs": residual,
        "stdout": stdout[-1000:],
        "stderr": stderr[-1000:],
    }
