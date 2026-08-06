"""非加密 zip writer 的 UTF-8 条目名（20260805.3 case55 A4 修复 + C13 flag 断言）。

修复前：macOS `zip-batch create-split` 走外壳 `zip -r`，中文条目名 flag_bits=0x0
（UTF-8 字节但没有 0x800 flag），Windows 资源管理器解出乱码目录名。
修复后：归档统一先由 Python zipfile 写入（str 文件名自动置 0x800），
超过分卷阈值时再用外壳 zip 拷贝模式重分卷（实测保留 flag_bits）。
"""
import argparse
import hashlib
import importlib.util
import os
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILLS_PATH = ROOT / "01-finder-sidebar" / "skills" / "skills.py"
SPEC = importlib.util.spec_from_file_location("folderis_zip_utf8_skills", SKILLS_PATH)
skills = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(skills)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create_args(files, output, volume_size="100m"):
    return argparse.Namespace(mode="create-split", files=[str(f) for f in files],
                              output=str(output), password=None,
                              volume_size=volume_size, overwrite_original=False)


@unittest.skipIf(skills.IS_WIN, "macOS zip writer under test")
class ZipCreateUtf8EntryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_single_archive_sets_utf8_flag_and_safe_relative_names(self):
        note = self.folder / "会议纪要.txt"
        note.write_text("记录", encoding="utf-8")
        nested = self.folder / "会议资料"
        nested.mkdir()
        (nested / "白板照片说明.txt").write_text("nested", encoding="utf-8")
        originals = {path: digest(path) for path in (note, nested / "白板照片说明.txt")}
        out = self.folder / "会议资料.zip"

        skills.cmd_zip_batch(create_args([note, nested], out))

        with zipfile.ZipFile(out) as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            self.assertEqual(sorted(names), ["会议纪要.txt", "会议资料/白板照片说明.txt"])
            for info in infos:
                self.assertTrue(info.flag_bits & 0x800,
                                f"{info.filename} missing UTF-8 flag: {hex(info.flag_bits)}")
                self.assertFalse(Path(info.filename).is_absolute())
                self.assertNotIn("..", Path(info.filename).parts)
                self.assertNotIn("Users", Path(info.filename).parts)
            self.assertEqual(archive.read("会议纪要.txt").decode("utf-8"), "记录")
        self.assertEqual({path: digest(path) for path in originals}, originals)

    def test_duplicate_names_get_versioned_roots_like_zip_encrypt(self):
        first_dir = self.folder / "a"
        second_dir = self.folder / "b"
        for parent in (first_dir, second_dir):
            parent.mkdir()
            (parent / "报告.txt").write_text(parent.name, encoding="utf-8")
        out = self.folder / "打包.zip"

        skills.cmd_zip_batch(create_args([first_dir / "报告.txt", second_dir / "报告.txt"], out))

        with zipfile.ZipFile(out) as archive:
            self.assertEqual(sorted(archive.namelist()), ["报告.txt", "报告_2.txt"])

    @unittest.skipUnless(shutil.which("zip"), "requires the system Info-ZIP binary")
    def test_split_volumes_preserve_utf8_flags(self):
        big = self.folder / "随机数据.bin"
        big.write_bytes(os.urandom(200 * 1024))
        note = self.folder / "说明.txt"
        note.write_text("小文件", encoding="utf-8")
        out = self.folder / "分卷包.zip"

        skills.cmd_zip_batch(create_args([big, note], out, volume_size="64k"))

        parts = sorted(self.folder.glob("分卷包.z[0-9][0-9]"))
        self.assertTrue(parts, "expected split volumes for oversized content")
        merged = self.folder / "merged_check.zip"
        with merged.open("wb") as stream:
            for part in [*parts, out]:
                stream.write(part.read_bytes())
        with zipfile.ZipFile(merged) as archive:
            flags = {info.filename: info.flag_bits for info in archive.infolist()}
        self.assertEqual(sorted(flags), ["说明.txt", "随机数据.bin"])
        for name, bits in flags.items():
            self.assertTrue(bits & 0x800, f"{name} missing UTF-8 flag: {hex(bits)}")


if __name__ == "__main__":
    unittest.main()
