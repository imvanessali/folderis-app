import argparse
import hashlib
import importlib.util
import io
import tempfile
import unittest
import urllib.request
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills" / "skills.py"


def load_skills():
    spec = importlib.util.spec_from_file_location("folderis_audio_transcribe_tests", SKILLS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse(io.BytesIO):
    status = 200

    def getcode(self):
        return self.status


class AudioTranscribeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.skills = load_skills()

    def test_parser_exposes_sensevoice_and_not_old_engines(self):
        parser = self.skills.build_parser()
        component_action = next(
            action for action in parser._subparsers._group_actions[0]
            .choices["install-component"]._actions if action.dest == "component")
        self.assertIn("sensevoice-small", component_action.choices)
        self.assertNotIn("qwen3-asr", component_action.choices)
        self.assertNotIn("whisper", component_action.choices)

    def test_parse_sensevoice_output_separates_vad_segments(self):
        raw = (
            "<|zh|><|NEUTRAL|><|Speech|><|withitn|>第一段。"
            "<|en|><|NEUTRAL|><|Speech|><|withitn|>Second segment.\n"
        )
        text, languages = self.skills._parse_sensevoice_output(raw)
        self.assertEqual(text, "第一段。\nSecond segment.")
        self.assertEqual(languages, ["中文", "英语"])

    def test_windows_sensevoice_transcription_versions_existing_output(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            audio = folder / "meeting.mp3"
            audio.write_bytes(b"fake-audio")
            previous = folder / "meeting.txt"
            previous.write_text("保留旧产物", encoding="utf-8")
            args = argparse.Namespace(files=[str(audio)], locale="auto", output=None)

            with mock.patch.object(self.skills, "IS_WIN", True), \
                 mock.patch.object(self.skills, "_reserve_output", return_value=True), \
                 mock.patch.object(
                     self.skills, "_run_sensevoice",
                     return_value=("SenseVoiceSmall 测试转写。", ["中文"])):
                self.skills.cmd_audio_transcribe(args)

            output = folder / "meeting_2.txt"
            self.assertEqual(previous.read_text(encoding="utf-8"), "保留旧产物")
            self.assertEqual(output.read_text(encoding="utf-8"), "SenseVoiceSmall 测试转写。")

    def test_component_check_rejects_missing_runtime(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "components" / "sensevoice-small"
            (root / "model").mkdir(parents=True)
            (root / "VERSION").write_text(
                self.skills.SENSEVOICE_COMPONENT_VERSION, encoding="utf-8")
            (root / "model" / "sensevoice-small-q8.gguf").write_bytes(b"m")
            (root / "model" / "fsmn-vad.gguf").write_bytes(b"v")

            with mock.patch.object(self.skills, "SUPPORT_DIR", Path(td)), \
                 mock.patch.object(self.skills, "SENSEVOICE_MODEL_SIZE", 1), \
                 mock.patch.object(self.skills, "SENSEVOICE_VAD_SIZE", 1):
                self.assertFalse(self.skills._sensevoice_component_ready())

    def test_run_sensevoice_uses_native_runtime_vad_and_utf8(self):
        with tempfile.TemporaryDirectory() as td:
            support = Path(td)
            root = support / "components" / "sensevoice-small"
            executable = root / "bin" / "llama-funasr-sensevoice.exe"
            model = root / "model" / "sensevoice-small-q8.gguf"
            vad = root / "model" / "fsmn-vad.gguf"
            executable.parent.mkdir(parents=True)
            model.parent.mkdir(parents=True)
            executable.write_bytes(b"e")
            model.write_bytes(b"m")
            vad.write_bytes(b"v")
            (root / "VERSION").write_text(
                self.skills.SENSEVOICE_COMPONENT_VERSION, encoding="utf-8")
            audio = support / "会议.mp3"
            audio.write_bytes(b"audio")
            completed = SimpleNamespace(
                returncode=0,
                stdout="<|zh|><|NEUTRAL|><|Speech|><|withitn|>会议内容。\n",
                stderr="[sensevoice] done")

            with mock.patch.object(self.skills, "SUPPORT_DIR", support), \
                 mock.patch.object(self.skills, "SENSEVOICE_EXE_SIZE", 1), \
                 mock.patch.object(self.skills, "SENSEVOICE_MODEL_SIZE", 1), \
                 mock.patch.object(self.skills, "SENSEVOICE_VAD_SIZE", 1), \
                 mock.patch.object(self.skills.subprocess, "run", return_value=completed) as run:
                text, languages = self.skills._run_sensevoice(audio)

            self.assertEqual(text, "会议内容。")
            self.assertEqual(languages, ["中文"])
            command = run.call_args.args[0]
            self.assertEqual(command[0], str(executable))
            self.assertIn("--vad", command)
            self.assertIn("--keep-tags", command)
            self.assertEqual(run.call_args.kwargs["encoding"], "utf-8")
            self.assertEqual(run.call_args.kwargs["errors"], "replace")

    def test_verified_download_checks_hash_before_publishing(self):
        payload = b"verified component"
        digest = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as td, \
             mock.patch.object(urllib.request, "urlopen", return_value=FakeResponse(payload)):
            destination = Path(td) / "artifact.bin"
            result = self.skills._download_verified(
                "https://example.test/artifact", destination, len(payload), digest, "测试组件")

            self.assertEqual(result, destination)
            self.assertEqual(destination.read_bytes(), payload)
            self.assertFalse(destination.with_name("artifact.bin.part").exists())

    def test_verified_download_recovers_completed_partial_without_network(self):
        payload = b"completed before rename"
        digest = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as td, \
             mock.patch.object(urllib.request, "urlopen") as urlopen:
            destination = Path(td) / "artifact.bin"
            destination.with_name("artifact.bin.part").write_bytes(payload)

            result = self.skills._download_verified(
                "https://example.test/artifact", destination, len(payload), digest, "测试组件")

            self.assertEqual(result.read_bytes(), payload)
            urlopen.assert_not_called()

    def test_install_component_is_atomic_and_removes_only_legacy_qwen(self):
        executable_payload = b"sensevoice-exe"
        model_payload = b"sensevoice-model"
        vad_payload = b"sensevoice-vad"
        runtime_buffer = io.BytesIO()
        with zipfile.ZipFile(runtime_buffer, "w") as archive:
            archive.writestr("llama-funasr-sensevoice.exe", executable_payload)
        runtime_payload = runtime_buffer.getvalue()

        with tempfile.TemporaryDirectory() as td:
            support = Path(td)
            legacy = support / "components" / "qwen3-asr"
            legacy.mkdir(parents=True)
            (legacy / "old-model.bin").write_bytes(b"old")
            user_file = support / "settings.json"
            user_file.write_text("keep", encoding="utf-8")

            def fake_download(_url, destination, _size, _sha, _label):
                destination = Path(destination)
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.name == "runtime.zip":
                    destination.write_bytes(runtime_payload)
                elif destination.name == "sensevoice-small-q8.gguf":
                    destination.write_bytes(model_payload)
                else:
                    destination.write_bytes(vad_payload)
                return destination

            with mock.patch.object(self.skills, "IS_WIN", True), \
                 mock.patch.object(self.skills, "SUPPORT_DIR", support), \
                 mock.patch.object(self.skills, "SENSEVOICE_EXE_SIZE", len(executable_payload)), \
                 mock.patch.object(
                     self.skills, "SENSEVOICE_EXE_SHA256",
                     hashlib.sha256(executable_payload).hexdigest()), \
                 mock.patch.object(self.skills, "SENSEVOICE_MODEL_SIZE", len(model_payload)), \
                 mock.patch.object(self.skills, "SENSEVOICE_VAD_SIZE", len(vad_payload)), \
                 mock.patch.object(self.skills, "_download_verified", side_effect=fake_download):
                self.skills.cmd_install_component(
                    argparse.Namespace(component="sensevoice-small"))

                self.assertTrue(self.skills._sensevoice_component_ready())

            self.assertFalse(legacy.exists())
            self.assertEqual(user_file.read_text(encoding="utf-8"), "keep")
            self.assertTrue((support / "components" / "sensevoice-small" / "NOTICE.txt").exists())

    def test_segment_ranges_prefer_silence_and_overlap_only_hard_cuts(self):
        detected = "\n".join([
            "[silencedetect] silence_start: 43.0",
            "[silencedetect] silence_end: 44.0 | silence_duration: 1.0",
            "[silencedetect] silence_start: 92.0",
            "[silencedetect] silence_end: 93.0 | silence_duration: 1.0",
        ])
        ranges = self.skills._audio_segment_ranges(120.0, detected)
        self.assertEqual(ranges[0], (0.0, 43.5, False))
        self.assertEqual(ranges[1], (43.5, 92.5, False))
        self.assertEqual(ranges[2], (92.5, 120.0, False))

        short = self.skills._audio_segment_ranges(
            33.0, "silence_start: 10.0\nsilence_end: 11.0")
        self.assertEqual(short, [(0.0, 10.5, False), (10.5, 33.0, False)])

        hard = self.skills._audio_segment_ranges(70.0, "")
        self.assertEqual(hard[0], (0.0, 50.0, False))
        self.assertEqual(hard[1], (49.7, 70.0, True))

    def test_hard_cut_word_overlap_is_removed(self):
        previous = "alpha beta gamma delta epsilon zeta eta"
        current = "gamma delta epsilon zeta eta theta iota"
        self.assertEqual(self.skills._dedupe_overlap(previous, current), "theta iota")

    def test_no_speech_errors_are_skippable_but_real_failures_are_not(self):
        self.assertTrue(self.skills._is_no_speech_error(
            "转写失败：No speech detected"))
        self.assertTrue(self.skills._is_no_speech_error(
            "Speech recognition error 1110"))
        self.assertFalse(self.skills._is_no_speech_error(
            "network connection was lost"))


if __name__ == "__main__":
    unittest.main()
