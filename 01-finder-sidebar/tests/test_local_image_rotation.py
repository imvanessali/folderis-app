import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills" / "skills.py"
RESULT_MARKER = "__FOLDERIS_LOCAL_RESULT__"


def load_skills():
    spec = importlib.util.spec_from_file_location("folderis_skills_rotation_tests", SKILLS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LocalImageRotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.skills = load_skills()

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp_dir.name)
        self.selected = []
        for index in range(4):
            path = self.folder / f"selected-{index}.png"
            Image.new("RGB", (10 + index, 20 + index), (20 * index, 40, 80)).save(path)
            self.selected.append(path)
        self.unselected = self.folder / "not-selected.png"
        Image.new("RGB", (31, 17), (200, 10, 20)).save(self.unselected)
        self.originals = {path: path.read_bytes() for path in [*self.selected, self.unselected]}

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_dispatch(self, request, files=None, check=True):
        selected = self.selected if files is None else files
        result = subprocess.run(
            [sys.executable, str(SKILLS), "local-dispatch", "--request", request,
             "--files", *map(str, selected)],
            cwd=self.folder, text=True, capture_output=True, check=check,
        )
        payload = json.loads(result.stdout.rsplit(RESULT_MARKER, 1)[1])
        return result, payload

    def test_chinese_clockwise_90_rotates_exact_selected_scope(self):
        _, payload = self.run_dispatch("将所有图片顺时针旋转90度")

        self.assertTrue(payload["matched"])
        self.assertTrue(payload["success"])
        self.assertEqual(payload["skill"], "img-rotate")
        self.assertEqual(len(payload["outputs"]), 4)
        self.assertEqual(
            {Path(path).name for path in payload["outputs"]},
            {f"selected-{index}_rotated.png" for index in range(4)},
        )
        # 多产物按全局产物政策统一进入版本化 Output 目录。
        output_dir = self.folder / "Output"
        for source in self.selected:
            self.assertEqual(source.read_bytes(), self.originals[source])
            with Image.open(source) as original, Image.open(
                    output_dir / (source.stem + "_rotated.png")) as rotated:
                self.assertEqual(rotated.size, (original.height, original.width))
        self.assertEqual(self.unselected.read_bytes(), self.originals[self.unselected])
        self.assertFalse((self.folder / "not-selected_rotated.png").exists())
        self.assertFalse((output_dir / "not-selected_rotated.png").exists())

    def test_english_clockwise_90_is_a_deterministic_builtin_plan(self):
        for request in [
                "Rotate all selected images 90 degrees clockwise",
                "Rotate all selected images 90 degrees to the right"]:
            with self.subTest(request=request):
                plan = self.skills._strict_local_plan(request, self.selected)
                self.assertEqual(plan["skill"], "img-rotate")
                self.assertEqual(plan["args"][:-2], [str(path) for path in self.selected])
                self.assertEqual(plan["args"][-2:], ["--angle", "90"])

    def test_chinese_explicit_direction_variants_match(self):
        for request in ["把图片顺时针转90度", "把图片右转 90 度"]:
            with self.subTest(request=request):
                plan = self.skills._strict_local_plan(request, self.selected)
                self.assertEqual(plan["skill"], "img-rotate")
                self.assertEqual(plan["args"][-2:], ["--angle", "90"])

    def test_counterclockwise_is_converted_for_existing_clockwise_runner(self):
        plan = self.skills._strict_local_plan(
            "把选中的图片逆时针旋转 90°", self.selected)

        self.assertEqual(plan["skill"], "img-rotate")
        self.assertEqual(plan["args"][-2:], ["--angle", "270"])

        english_plan = self.skills._strict_local_plan(
            "Rotate the selected images 90 degrees counter clockwise", self.selected)
        self.assertEqual(english_plan["skill"], "img-rotate")
        self.assertEqual(english_plan["args"][-2:], ["--angle", "270"])

    def test_collision_versions_outputs_and_preserves_every_existing_file(self):
        first = self.selected[0].with_name("selected-0_rotated.png")
        first.write_bytes(b"existing-result")

        _, payload = self.run_dispatch("所有图片向右旋转 90 度", [self.selected[0]])

        self.assertTrue(payload["success"])
        self.assertEqual(first.read_bytes(), b"existing-result")
        self.assertEqual(self.selected[0].read_bytes(), self.originals[self.selected[0]])
        self.assertEqual([Path(path).name for path in payload["outputs"]],
                         ["selected-0_rotated_2.png"])

    def test_ambiguous_conflicting_or_negated_requests_fall_back_to_ai(self):
        requests = [
            "把图片旋转 90 度",
            "顺时针旋转图片",
            "不要顺时针旋转 90 度",
            "请勿把图片顺时针旋转90度",
            "我不想把图片顺时针旋转90度",
            "I do not want to rotate the images 90 degrees clockwise",
            "顺时针旋转 90 度并压缩",
            "rotate 90 degrees clockwise or counterclockwise",
        ]
        for request in requests:
            with self.subTest(request=request):
                self.assertIsNone(self.skills._strict_local_plan(request, self.selected))

    def test_mixed_or_missing_inputs_do_not_match(self):
        text_file = self.folder / "notes.txt"
        text_file.write_text("keep", encoding="utf-8")
        self.assertIsNone(self.skills._strict_local_plan(
            "顺时针旋转 90 度", [self.selected[0], text_file]))
        self.assertIsNone(self.skills._strict_local_plan(
            "顺时针旋转 90 度", [self.folder / "missing.png"]))

    def test_matched_skill_error_is_reported_without_changing_the_source(self):
        broken = self.folder / "broken.png"
        broken.write_bytes(b"not an image")
        before = broken.read_bytes()

        _, payload = self.run_dispatch("顺时针旋转 90 度", [broken])

        self.assertTrue(payload["matched"])
        self.assertFalse(payload["success"])
        self.assertEqual(payload["outputs"], [])
        self.assertEqual(broken.read_bytes(), before)
        self.assertIn("cannot identify image file", payload["details"])

    @unittest.skipIf(os.name == "nt", "POSIX signal behavior; Windows uses taskkill /T /F")
    def test_cancellation_terminates_the_builtin_child_process_group(self):
        fake_child = mock.Mock()
        fake_child.pid = 4242
        fake_child.poll.return_value = None
        fake_child.communicate.side_effect = lambda: os.kill(os.getpid(), signal.SIGTERM)

        args = mock.Mock(request="顺时针旋转 90 度", files=[str(self.selected[0])])
        with mock.patch.object(self.skills.subprocess, "Popen", return_value=fake_child), \
             mock.patch.object(self.skills.os, "killpg") as killpg, \
             self.assertRaises(SystemExit) as stopped:
            self.skills.cmd_local_dispatch(args)

        self.assertEqual(stopped.exception.code, 130)
        killpg.assert_called_once_with(4242, signal.SIGTERM)


class LocalDispatchUIOrderTests(unittest.TestCase):
    def test_macos_and_windows_bypass_cli_after_a_match(self):
        mac = (ROOT / "HostApp" / "ChatViewModel.swift").read_text(encoding="utf-8")
        windows = (ROOT.parent / "win-explorer-sidebar" / "src" / "Sider" /
                   "MainPanel.xaml.cs").read_text(encoding="utf-8")

        self.assertLess(mac.index("if let local = await Self.runLocalDispatch"),
                        mac.index("try await runCLIBackendTurn"))
        self.assertIn("local.matched", mac)
        self.assertIn("return\n                }", mac)
        cancel_gate = mac.index("guard !Task.isCancelled else { return }")
        self.assertGreater(cancel_gate, mac.index("if let local = await Self.runLocalDispatch"))
        self.assertLess(cancel_gate, mac.index("try await runCLIBackendTurn"))
        self.assertLess(windows.index('"local-dispatch", dispatchArgs.ToArray()'),
                        windows.index("_cliBackend.RunAsync"))
        self.assertIn('(bool?)local["matched"] == true', windows)
        self.assertIn("SaveConversation(conv);\n                    return;", windows)


if __name__ == "__main__":
    unittest.main()
