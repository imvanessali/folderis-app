"""qr-read 多行 payload 协议（20260805.3 §6bis A1 修复）与结构化解析列（B9）。

旧协议 `路径\t内容` 在 payload 含换行时把续行静默丢弃（状态却写「已识别」）。
新协议：qr.swift 每码输出一行 JSON，skills.py 还原后 xlsx 单元格保留完整多行文本。
"""
import argparse
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SKILLS_PATH = ROOT / "01-finder-sidebar" / "skills" / "skills.py"
QR_SWIFT = ROOT / "01-finder-sidebar" / "skills" / "qr.swift"
SPEC = importlib.util.spec_from_file_location("folderis_qr_multiline_skills", SKILLS_PATH)
skills = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(skills)


VCARD = (
    "BEGIN:VCARD\n"
    "VERSION:3.0\n"
    "FN:筑波 花子\n"
    "ORG:筑波ホテル\n"
    "TEL:+81-29-000-0000\n"
    "EMAIL:hanako@tsukubahotel.jp\n"
    "END:VCARD"
)


def workbook_rows(path):
    import openpyxl
    return list(openpyxl.load_workbook(path, data_only=True).active.values)


class QrMacProtocolTests(unittest.TestCase):
    def test_json_lines_preserve_multiline_payloads(self):
        stdout = (
            json.dumps({"path": "/x/a.png", "payload": VCARD}, ensure_ascii=False) + "\n"
            + json.dumps({"path": "/x/b.png", "error": "未识别到二维码/条形码"},
                         ensure_ascii=False) + "\n"
        )
        records = skills._qr_mac_records(stdout)
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0], {"path": "/x/a.png", "payload": VCARD})
        self.assertEqual(records[1], {"path": "/x/b.png", "error": "未识别到二维码/条形码"})

    def test_legacy_tab_lines_remain_parseable(self):
        stdout = "/x/a.png\thttps://example.test\n/x/b.png\t(无法读取图片)\n"
        records = skills._qr_mac_records(stdout)
        self.assertEqual(records[0], {"path": "/x/a.png", "payload": "https://example.test"})
        self.assertEqual(records[1], {"path": "/x/b.png", "error": "无法读取图片"})

    def test_json_payload_content_is_not_mistaken_for_json_record(self):
        # payload 本身是 JSON 文本时，仍然通过 path 字段判别记录结构。
        stdout = json.dumps({"path": "/x/a.png", "payload": '{"k": "v"}'}) + "\n"
        records = skills._qr_mac_records(stdout)
        self.assertEqual(records[0]["payload"], '{"k": "v"}')


class QrPayloadSummaryTests(unittest.TestCase):
    def test_vcard_summary(self):
        summary = skills._qr_payload_summary(VCARD)
        self.assertIn("vCard", summary)
        self.assertIn("姓名=筑波 花子", summary)
        self.assertIn("电话=+81-29-000-0000", summary)

    def test_wifi_summary(self):
        summary = skills._qr_payload_summary("WIFI:T:WPA;S:GuestNet;P:pass1234;;")
        self.assertIn("SSID=GuestNet", summary)
        self.assertIn("密码=pass1234", summary)

    def test_mecard_summary(self):
        summary = skills._qr_payload_summary("MECARD:N:张三;TEL:13800001111;;")
        self.assertIn("MECARD", summary)
        self.assertIn("姓名=张三", summary)

    def test_mebkm_after_leading_url_line_is_parsed(self):
        payload = "http://tsukubahotel.jp/\nMEBKM:TITLE:筑波ホテル;URL:http\\://tsukubahotel.jp/;;"
        summary = skills._qr_payload_summary(payload)
        self.assertIn("MEBKM", summary)
        self.assertIn("标题=筑波ホテル", summary)
        self.assertIn("URL=http://tsukubahotel.jp/", summary)

    def test_plain_url_has_no_summary(self):
        self.assertIsNone(skills._qr_payload_summary("https://folderis.app"))


class QrReadWorkbookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_multiline_payload_lands_complete_in_xlsx(self):
        image = self.folder / "vcard.png"
        image.write_bytes(b"png-placeholder")
        stdout = json.dumps({"path": str(image), "payload": VCARD}, ensure_ascii=False) + "\n"
        result = subprocess.CompletedProcess([], 0, stdout=stdout, stderr="")
        args = argparse.Namespace(files=[str(image)], output=None)

        with mock.patch.object(skills, "IS_WIN", False), \
             mock.patch.object(skills, "helper", return_value=["fake-qr"]), \
             mock.patch.object(skills.subprocess, "run", return_value=result):
            skills.cmd_qr_read(args)

        rows = workbook_rows(self.folder / "二维码识别结果.xlsx")
        self.assertEqual(rows[0], ("截图文件名", "识别内容", "状态", "结构化解析"))
        name, payload, status, summary = rows[1]
        self.assertEqual((name, status), ("vcard.png", "已识别"))
        self.assertEqual(payload, VCARD)
        self.assertIn("\n", payload)
        self.assertIn("vCard", summary)

    def test_two_codes_in_one_image_stay_two_rows(self):
        image = self.folder / "double.png"
        image.write_bytes(b"png-placeholder")
        stdout = (
            json.dumps({"path": str(image), "payload": "https://a.example"}) + "\n"
            + json.dumps({"path": str(image), "payload": VCARD}, ensure_ascii=False) + "\n"
        )
        result = subprocess.CompletedProcess([], 0, stdout=stdout, stderr="")
        args = argparse.Namespace(files=[str(image)], output=None)

        with mock.patch.object(skills, "IS_WIN", False), \
             mock.patch.object(skills, "helper", return_value=["fake-qr"]), \
             mock.patch.object(skills.subprocess, "run", return_value=result):
            skills.cmd_qr_read(args)

        rows = workbook_rows(self.folder / "二维码识别结果.xlsx")
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[1][1], "https://a.example")
        self.assertEqual(rows[2][1], VCARD)


class QrReadEndToEndTests(unittest.TestCase):
    """真实 Vision 解码回环：qrcode 生成 → qr.swift(JSON 协议) → xlsx 完整多行。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    @unittest.skipUnless(shutil.which("swift"), "requires the Swift toolchain")
    def test_real_helper_roundtrip_keeps_all_lines(self):
        try:
            import qrcode
        except ImportError:
            self.skipTest("qrcode is available in the packaged Folderis runtime")
        image = self.folder / "名片.png"
        qrcode.make(VCARD).save(image)
        args = argparse.Namespace(files=[str(image)], output=None)

        # 固定使用仓库内的 qr.swift 源码，避免命中旧协议的预编译 helper。
        with mock.patch.object(skills, "helper", return_value=["swift", str(QR_SWIFT)]):
            skills.cmd_qr_read(args)

        rows = workbook_rows(self.folder / "二维码识别结果.xlsx")
        recognized = [row for row in rows[1:] if row[2] == "已识别"]
        self.assertTrue(recognized)
        self.assertEqual(recognized[0][1].replace("\r\n", "\n"), VCARD)


if __name__ == "__main__":
    unittest.main()
