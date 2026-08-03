#!/usr/bin/env python3
"""Atomically synchronize Folderis macOS and Windows version sources."""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "version.json"
APP_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")
BUILD_RE = re.compile(r"^[0-9]{8}\.[1-9][0-9]*$")


class VersionError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_version", nargs="?")
    parser.add_argument("build_version", nargs="?")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="show changes without writing")
    mode.add_argument("--check", action="store_true", help="verify all sources match version.json or supplied versions")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    return parser.parse_args()


def validate(app_version: str, build_version: str) -> None:
    if not APP_RE.fullmatch(app_version):
        raise VersionError("app version must look like 1.2, 1.2.3, or 1.2.3.4")
    if not BUILD_RE.fullmatch(build_version):
        raise VersionError("build version must look like YYYYMMDD.N (N starts at 1)")


def replace_exact(text: str, pattern: str, replacement: str, path: Path, expected: int = 1) -> str:
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != expected:
        raise VersionError(f"{path}: expected {expected} match(es) for {pattern!r}, found {count}")
    return updated


def render(root: Path, app_version: str, build_version: str) -> dict[Path, str]:
    padded = ".".join((app_version.split(".") + ["0"] * 4)[:4])
    targets: dict[Path, str] = {}

    def read(relative: str) -> tuple[Path, str]:
        path = root / relative
        return path, path.read_text(encoding="utf-8")

    path, text = read("01-finder-sidebar/make_release.sh")
    text = replace_exact(text, r'^APP_VERSION="[^"]+"$', f'APP_VERSION="{app_version}"', path)
    text = replace_exact(text, r'^BUILD_VERSION="[^"]+"$', f'BUILD_VERSION="{build_version}"', path)
    targets[path] = text

    path, text = read("01-finder-sidebar/build_app.sh")
    text = replace_exact(
        text,
        r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)",
        rf"\g<1>{app_version}\g<2>",
        path,
    )
    text = replace_exact(
        text,
        r"(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)",
        rf"\g<1>{build_version}\g<2>",
        path,
    )
    targets[path] = text

    path, text = read("01-finder-sidebar/FinderSidebar.xcodeproj/project.pbxproj")
    text = replace_exact(
        text, r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {app_version};", path, expected=2
    )
    text = replace_exact(
        text, r"CURRENT_PROJECT_VERSION = [^;]+;", f"CURRENT_PROJECT_VERSION = {build_version};", path, expected=2
    )
    targets[path] = text

    path, text = read("01-finder-sidebar/project.yml")
    text = replace_exact(
        text,
        r'^        MARKETING_VERSION: "[^"]+"$',
        f'        MARKETING_VERSION: "{app_version}"',
        path,
    )
    text = replace_exact(
        text,
        r'^        CURRENT_PROJECT_VERSION: "[^"]+"$',
        f'        CURRENT_PROJECT_VERSION: "{build_version}"',
        path,
    )
    targets[path] = text

    for relative in (
        "01-finder-sidebar/HostApp/Info.plist",
        "01-finder-sidebar/FinderExtension/Info.plist",
    ):
        path, text = read(relative)
        text = replace_exact(
            text,
            r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)",
            rf"\g<1>{app_version}\g<2>",
            path,
        )
        text = replace_exact(
            text,
            r"(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)",
            rf"\g<1>{build_version}\g<2>",
            path,
        )
        targets[path] = text

    path, text = read("win-explorer-sidebar/src/Sider/Sider.csproj")
    text = replace_exact(text, r"<Version>[^<]+</Version>", f"<Version>{app_version}</Version>", path)
    targets[path] = text

    path, text = read("win-explorer-sidebar/src/Setup/Setup.csproj")
    text = replace_exact(text, r"<Version>[^<]+</Version>", f"<Version>{app_version}</Version>", path)
    text = replace_exact(text, r"<AssemblyVersion>[^<]+</AssemblyVersion>", f"<AssemblyVersion>{padded}</AssemblyVersion>", path)
    text = replace_exact(text, r"<FileVersion>[^<]+</FileVersion>", f"<FileVersion>{padded}</FileVersion>", path)
    text = replace_exact(
        text,
        r"<InformationalVersion>[^<]+</InformationalVersion>",
        f"<InformationalVersion>{app_version}+{build_version}</InformationalVersion>",
        path,
    )
    targets[path] = text

    # These release scripts consume the synchronized sources instead of
    # carrying another literal. Keeping them in the checked target set makes
    # --check fail if a later edit silently reintroduces a divergent default.
    path, text = read("win-explorer-sidebar/build_release.sh")
    for marker in (
        'json.load(open("../version.json"))["app_version"]',
        'json.load(open("../version.json"))["build_version"]',
    ):
        if text.count(marker) != 1:
            raise VersionError(f"{path}: missing single-source marker {marker!r}")
    targets[path] = text

    path, text = read("01-finder-sidebar/make_release_matrix.sh")
    marker = "BUILD_VERSION=$(sed -n 's/^BUILD_VERSION="
    if text.count(marker) != 1:
        raise VersionError(f"{path}: release matrix no longer reads make_release.sh BUILD_VERSION")
    targets[path] = text

    manifest = root / "version.json"
    targets[manifest] = json.dumps(
        {"app_version": app_version, "build_version": build_version},
        indent=2,
    ) + "\n"
    return targets


def atomic_write(changes: dict[Path, str]) -> None:
    originals = {path: path.read_bytes() for path in changes}
    staged: dict[Path, Path] = {}
    committed: list[Path] = []
    try:
        for path, content in changes.items():
            fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
            staged_path = Path(name)
            staged[staged_path] = path
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(staged_path, path.stat().st_mode)
        for staged_path, destination in staged.items():
            os.replace(staged_path, destination)
            committed.append(destination)
    except Exception:
        for destination in committed:
            destination.write_bytes(originals[destination])
        raise
    finally:
        for staged_path in staged:
            staged_path.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    manifest_path = root / "version.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if bool(args.app_version) != bool(args.build_version):
        raise VersionError("provide both app_version and build_version, or neither with --check")
    if args.app_version:
        app_version, build_version = args.app_version, args.build_version
    elif args.check:
        app_version = manifest["app_version"]
        build_version = manifest["build_version"]
    else:
        raise VersionError("provide app_version and build_version (or use --check)")
    validate(app_version, build_version)

    rendered = render(root, app_version, build_version)
    changes = {
        path: content
        for path, content in rendered.items()
        if path.read_text(encoding="utf-8") != content
    }
    if args.check:
        if changes:
            print("Version sources out of sync:")
            for path in changes:
                print(f"  {path.relative_to(root)}")
            return 1
        print(f"Version sources match: app {app_version}, build {build_version}")
        return 0
    if args.dry_run:
        for path, content in changes.items():
            before = path.read_text(encoding="utf-8").splitlines(keepends=True)
            after = content.splitlines(keepends=True)
            print("".join(difflib.unified_diff(
                before, after,
                fromfile=str(path.relative_to(root)),
                tofile=str(path.relative_to(root)),
            )), end="")
        print(f"Dry run: {len(changes)} file(s) would change")
        return 0
    if not changes:
        print(f"Already synchronized: app {app_version}, build {build_version}")
        return 0
    atomic_write(changes)
    print(f"Updated {len(changes)} files: app {app_version}, build {build_version}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (VersionError, OSError, json.JSONDecodeError) as exc:
        print(f"version bump failed: {exc}", file=sys.stderr)
        raise SystemExit(2)
