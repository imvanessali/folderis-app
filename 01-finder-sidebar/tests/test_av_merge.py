import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills" / "skills.py"
RESULT_MARKER = "__FOLDERIS_LOCAL_RESULT__"

if sys.platform == "win32":
    _SUPPORT = Path(os.environ.get("FOLDERIS_SUPPORT_DIR") or
                    (Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Sider"))
    _FF, _FP = _SUPPORT / "bin/ffmpeg.exe", _SUPPORT / "bin/ffprobe.exe"
else:
    _SUPPORT = Path.home() / "Library/Application Support/FinderSidebar"
    _FF, _FP = _SUPPORT / "bin/ffmpeg", _SUPPORT / "bin/ffprobe"
FFMPEG = Path(os.environ.get("FS_FFMPEG", str(_FF)))
FFPROBE = Path(os.environ.get("FS_FFPROBE", str(_FP)))


@unittest.skipUnless(FFMPEG.exists() and FFPROBE.exists(),
                     "ffmpeg/ffprobe 组件未安装")
class AvMergeTests(unittest.TestCase):
    """QA 2026-07-23 D1/D2 回归：混合帧率合并时长 + 视频压缩本地分发。"""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def make_clip(self, name, rate, duration=2):
        path = self.folder / name
        subprocess.run(
            [str(FFMPEG), "-y", "-f", "lavfi",
             "-i", f"testsrc=duration={duration}:size=320x240:rate={rate}",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path)],
            check=True, capture_output=True)
        return path

    def duration(self, path):
        result = subprocess.run(
            [str(FFPROBE), "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nk=1:nw=1", str(path)],
            check=True, capture_output=True, text=True)
        return float(result.stdout.strip())

    def run_skill(self, *arguments, check=True):
        return subprocess.run(
            [sys.executable, str(SKILLS), *map(str, arguments)],
            cwd=self.folder,
            env={**os.environ, "FS_FFMPEG": str(FFMPEG), "FS_FFPROBE": str(FFPROBE)},
            text=True,
            capture_output=True,
            check=check,
        )

    def test_mixed_frame_rate_merge_keeps_total_duration(self):
        clips = [self.make_clip("a_30fps.mp4", "30"),
                 self.make_clip("b_2997fps.mp4", "30000/1001"),
                 self.make_clip("c_24fps.mp4", "24")]
        expected = sum(self.duration(c) for c in clips)

        self.run_skill("av-merge", *[c.name for c in clips], "--output", "merged.mp4")

        merged = self.folder / "merged.mp4"
        self.assertTrue(merged.exists())
        self.assertAlmostEqual(self.duration(merged), expected,
                               delta=max(0.5, expected * 0.02))

    def test_uniform_inputs_merge_keeps_total_duration(self):
        clips = [self.make_clip("a.mp4", "30"), self.make_clip("b.mp4", "30")]
        expected = sum(self.duration(c) for c in clips)

        self.run_skill("av-merge", *[c.name for c in clips], "--output", "merged.mp4")

        self.assertAlmostEqual(self.duration(self.folder / "merged.mp4"), expected,
                               delta=max(0.5, expected * 0.02))

    def make_51_clip(self, name, duration=2):
        """带 5.1 六声道音轨的视频：原生 aac 编码器不支持该布局，必须降混。"""
        path = self.folder / name
        subprocess.run(
            [str(FFMPEG), "-y",
             "-f", "lavfi", "-i", f"testsrc=duration={duration}:size=320x240:rate=24",
             "-f", "lavfi", "-i", f"anullsrc=channel_layout=5.1:sample_rate=48000",
             "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p",
             "-c:a", "pcm_s16le", str(path)],
            check=True, capture_output=True)
        return path

    def audio_channels(self, path):
        result = subprocess.run(
            [str(FFPROBE), "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=channels", "-of", "default=nk=1:nw=1", str(path)],
            check=True, capture_output=True, text=True)
        return int(result.stdout.strip())

    def test_compress_downmixes_surround_audio(self):
        clip = self.make_51_clip("surround.mov")
        self.assertEqual(self.audio_channels(clip), 6)

        self.run_skill("av-compress", clip.name, "--crf", "28")

        out = self.folder / "surround_small.mp4"
        self.assertTrue(out.exists())
        self.assertGreater(out.stat().st_size, 0)
        self.assertEqual(self.audio_channels(out), 2)
        self.assertGreater(self.duration(out), 1.5)

    def test_failed_compress_does_not_publish_partial_output(self):
        clip = self.make_clip("cancelled.mp4", "30")
        fake_ffmpeg = self.folder / "fake-ffmpeg"
        fake_ffmpeg.write_text(
            "#!/bin/sh\n"
            "for last do :; done\n"
            "printf partial > \"$last\"\n"
            "exit 9\n",
            encoding="utf-8",
        )
        fake_ffmpeg.chmod(0o755)
        task_id = "cancel-regression"

        result = subprocess.run(
            [sys.executable, str(SKILLS), "av-compress", clip.name, "--crf", "28"],
            cwd=self.folder,
            env={
                **os.environ,
                "FS_FFMPEG": str(fake_ffmpeg),
                "FS_FFPROBE": str(FFPROBE),
                "FOLDERIS_TASK_ID": task_id,
            },
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / "cancelled_small.mp4").exists())
        self.assertFalse(
            (Path(tempfile.gettempdir()) / f"folderis-{task_id}-cancelled_small.mp4").exists()
        )

    def test_convert_downmixes_surround_audio(self):
        clip = self.make_51_clip("surround.mov")
        self.run_skill("av-convert", clip.name, "--to", "mp4")
        out = self.folder / "surround.mp4"
        self.assertTrue(out.exists())
        self.assertEqual(self.audio_channels(out), 2)

    def test_odd_width_video_converts_and_trims_to_even_dimensions(self):
        source = self.folder / "odd.mov"
        subprocess.run(
            [str(FFMPEG), "-y", "-f", "lavfi",
             "-i", "testsrc=duration=2:size=321x240:rate=24",
             "-c:v", "libx264", "-pix_fmt", "yuv444p", str(source)],
            check=True,
            capture_output=True,
        )

        self.run_skill("av-convert", source.name, "--to", "mp4")
        self.run_skill("av-trim", source.name, "--start", "0", "--end", "1")

        for output in (self.folder / "odd.mp4", self.folder / "odd_clip.mov"):
            probe = subprocess.run(
                [str(FFPROBE), "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=width,height", "-of", "json", str(output)],
                check=True,
                capture_output=True,
                text=True,
            )
            stream = json.loads(probe.stdout)["streams"][0]
            self.assertEqual((stream["width"], stream["height"]), (320, 240))

    def dispatch(self, request, *files):
        result = self.run_skill("local-dispatch", "--request", request,
                                "--files", *files)
        return json.loads(result.stdout.split(RESULT_MARKER, 1)[1])

    def test_documented_video_compress_bypasses_ai(self):
        clip = self.make_clip("视频_BigBuckBunny_10s.mp4", "30")
        payload = self.dispatch("压缩这个视频", clip.name)

        self.assertTrue(payload["matched"])
        self.assertTrue(payload["success"])
        self.assertEqual(payload["skill"], "av-compress")
        self.assertTrue((self.folder / "视频_BigBuckBunny_10s_small.mp4").exists())

    def test_mixed_convert_and_compress_still_falls_through_to_ai(self):
        clip = self.make_clip("clip.mov", "30")
        payload = self.dispatch("转成 mp4 并压缩一下", clip.name)
        self.assertFalse(payload["matched"])

    def test_archive_request_on_videos_falls_through_to_ai(self):
        clip = self.make_clip("clip.mp4", "30")
        payload = self.dispatch("把这个视频打包压缩", clip.name)
        self.assertFalse(payload["matched"])


if __name__ == "__main__":
    unittest.main()
