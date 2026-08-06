"""pdf-convert 的 --files 批量分支（20260805.3 case28 A2 修复 + A3/C12 根目录零残留）。

修复前：`pdf-convert --files a.pdf b.pdf --to txt` 因 a.file 为 None 触发内部错误。
修复后：txt/docx/pdf 目标全部支持批量；多产物统一移入版本化 Output，根目录不残留。
"""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SKILLS_PATH = ROOT / "01-finder-sidebar" / "skills" / "skills.py"
SPEC = importlib.util.spec_from_file_location("folderis_pdf_convert_batch_skills", SKILLS_PATH)
skills = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(skills)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def convert_args(**overrides):
    base = dict(file=None, files=[], to="txt", output=None, dpi=150,
                password=None, pages=None, overwrite_original=False)
    base.update(overrides)
    return argparse.Namespace(**base)


def fake_ocr(source, dpi, password, pages):
    return f"=== 第 1 页 ===\nOCR text for {Path(source).name}\n"


class PdfConvertBatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.first = self.folder / "甲方合同.pdf"
        self.second = self.folder / "乙方合同.pdf"
        for path in (self.first, self.second):
            path.write_bytes(b"%PDF-placeholder-" + path.name.encode("utf-8"))
        self.originals = {path.name: digest(path) for path in (self.first, self.second)}

    def tearDown(self):
        self.temp.cleanup()

    def test_files_batch_txt_goes_to_output_with_no_root_residue(self):
        before_root = {entry.name for entry in self.folder.iterdir()}
        args = convert_args(files=[str(self.first), str(self.second)])

        with mock.patch.object(skills, "_pdf_ocr_text", side_effect=fake_ocr):
            skills.cmd_pdf_convert(args)

        output = self.folder / "Output"
        self.assertEqual(sorted(path.name for path in output.iterdir()),
                         ["乙方合同.txt", "甲方合同.txt"])
        self.assertIn("甲方合同.pdf", (output / "甲方合同.txt").read_text(encoding="utf-8"))
        # 根目录零残留：除 Output 目录外不允许出现任何新条目（C12）。
        after_root = {entry.name for entry in self.folder.iterdir()}
        self.assertEqual(after_root - before_root, {"Output"})
        self.assertEqual({path.name: digest(path) for path in (self.first, self.second)},
                         self.originals)

    def test_single_source_via_files_flag_keeps_side_by_side_naming(self):
        # case28 的实际调用形态：只传 --files（不带 --file）也不允许内部错误。
        args = convert_args(files=[str(self.first)])
        with mock.patch.object(skills, "_pdf_ocr_text", side_effect=fake_ocr):
            skills.cmd_pdf_convert(args)
        self.assertTrue((self.folder / "甲方合同.txt").exists())
        self.assertFalse((self.folder / "Output").exists())

    def test_file_and_files_are_merged(self):
        args = convert_args(file=str(self.first), files=[str(self.second)])
        with mock.patch.object(skills, "_pdf_ocr_text", side_effect=fake_ocr):
            skills.cmd_pdf_convert(args)
        output = self.folder / "Output"
        self.assertEqual(sorted(path.name for path in output.iterdir()),
                         ["乙方合同.txt", "甲方合同.txt"])

    def test_batch_with_explicit_output_directory(self):
        target = self.folder / "转换结果"
        args = convert_args(files=[str(self.first), str(self.second)], output=str(target))
        with mock.patch.object(skills, "_pdf_ocr_text", side_effect=fake_ocr):
            skills.cmd_pdf_convert(args)
        self.assertEqual(sorted(path.name for path in target.iterdir()),
                         ["乙方合同.txt", "甲方合同.txt"])
        self.assertFalse((self.folder / "Output").exists())

    def test_no_source_is_a_clear_error(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            skills.cmd_pdf_convert(convert_args())
        self.assertIn("--file", stderr.getvalue())

    def test_multiple_sources_to_images_is_a_clear_refusal_not_a_crash(self):
        args = convert_args(files=[str(self.first), str(self.second)], to="png", pages="all")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as ctx:
            skills.cmd_pdf_convert(args)
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("一次只处理一个文件", stderr.getvalue())
        # 拒绝时不留任何产物。
        self.assertEqual({entry.name for entry in self.folder.iterdir()},
                         {"甲方合同.pdf", "乙方合同.pdf"})


if __name__ == "__main__":
    unittest.main()
