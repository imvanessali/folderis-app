# -*- coding: utf-8 -*-
"""63 条素材包标准话术的本地路由回归：命中技能与放行 AI 的边界都不允许漂移。

规格由 test_data 素材包的真实文件组合生成；路由只看文件名/扩展名与话术，
文件内容无关。任何匹配器改动导致命中集合变化时，本测试会显式失败。
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SKILLS = Path(__file__).resolve().parents[1] / "skills" / "skills.py"
_spec = importlib.util.spec_from_file_location("skills_routing_under_test", SKILLS)
skills = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(skills)

# (case, files, instruction, expected skill 或 None=交给 AI)
CANONICAL_ROUTES = [
        (1, ['product_01_amber_bottle.jpg', 'product_02_color_bottles.jpg'], '去除所有这些图片的背景', 'img-remove-bg'),
        (2, ['logo_3_副本.png', 'product_01_amber_bottle.jpg', 'product_02_color_bottles.jpg'], '在每张图片右下角加半透明水印:© 2026 Vanessa', 'img-watermark'),
        (3, ['收据_1.webp', '收据_2.webp', '收据_3.jpg', '收据_4.jpg'], '全部顺时针旋转90度', 'img-rotate'),
        (4, ['travel_1_4k.png', 'travel_2_4k.png'], '视觉无损地压缩这些PNG', 'png-compress'),
        (5, ['travel_1_4k.jpg', 'travel_2_4k.jpg'], '视觉无损地压缩这些JPG', 'jpg-compress'),
        (6, ['image_1.jpg', 'image_2.jpg', 'image_3.png', 'image_4.png', 'image_5.webp', 'image_6.webp'], '全部转换为WebP', 'img-convert'),
        (7, ['travel_1_4k.jpg', 'travel_2_4k.jpg'], '缩放到1920像素宽,保持宽高比', 'img-resize'),
        (8, ['01_portal_timeline.png', '02_portal_metrics.png'], '对每张截图做OCR,输出为同名txt', 'img-ocr'),
        (9, ['receipt_sroie_000.jpg', 'receipt_sroie_001.jpg'], 'OCR这些收据,把金额和日期收集到一个Excel里,再按类别汇总', None),
        (10, ['01_product_shelf.jpg', '03_water_texture.jpg'], '把这些图片按顺序竖向拼接成一张长图', 'img-stitch'),
        (11, ['page-01.jpg', 'page-02.jpg'], '按文件名顺序把这些页面合并成一个PDF', 'pdf-convert'),
        (12, ['travel_1_4k.jpg', 'travel_2_4k.jpg'], '从(100,50)开始裁剪800×600', 'img-resize'),
        (13, ['long_screenshot_1.png', 'long_screenshot_2.png'], '把每张长截图切成3段', 'img-split'),
        (14, ['logo_1.png', 'logo_2.png'], '为每个logo各生成一个.ico', 'img-to-ico'),
        (15, ['01_shareholder_letter.docx', '02_form_10k.docx', '03_investor_relations_contacts.txt'], '按文件名顺序合并成一份投资者资料包', 'merge-docs'),
        (16, ['contract_01_professional_services.docx', 'contract_02_mutual_nda.docx'], "把这些合同转成PDF,加'Confidential'水印,再用密码8888加密打包", None),
        (17, ['dirty_doc_01.txt', 'dirty_doc_02.txt'], '清理这些txt文件:去掉行尾空格,合并连续空行', 'txt-clean'),
        (18, ['gbk_file_01.txt', 'gbk_file_02.txt'], '这些文件是GBK编码的——把它们全部转成UTF-8', 'encoding-convert'),
        (19, ['server_access_log.txt'], '把这个txt每1000行拆成一个文件', 'txt-split'),
        (20, ['offer_template.docx', 'roster.xlsx'], '按花名册为每个人生成一份', None),
        (21, ['01_pages_001-032.pdf', '02_pages_033-064.pdf'], '按文件名顺序合并这些PDF，恢复完整161页报告', 'pdf-merge'),
        (22, ['catalog_1.pdf', 'catalog_2.pdf'], '无损压缩这些PDF', 'pdf-compress'),
        (23, ['encrypted_1_password_test1234.pdf', 'encrypted_2_password_hello2026.pdf'], '去除这些PDF的密码和复制限制', None),
        (24, ['memo_01.pdf', 'memo_02.pdf'], '加上密码abc123', None),
        (25, ['starbucks_fy2025_annual_report_161pages.pdf'], '把每一页拆分成单独的文件', 'pdf-split'),
        (26, ['starbucks_fy2025_annual_report_161pages.pdf'], '提取第2-5页', 'pdf-split'),
        (27, ['starbucks_report_pages_02_03_01.pdf'], '按3、1、2重排页面，恢复报告正确前三页', 'pdf-reorder'),
        (28, ['mixed_brochure.pdf', 'table_report.pdf'], '把这些PDF逐个转成txt', None),
        (29, ['report_01.pdf', 'report_02.pdf'], "给所有这些PDF加'Confidential'水印", 'pdf-watermark'),
        (30, ['starbucks_brand_mark.png', 'starbucks_fy2025_annual_report.pdf'], '把品牌标志盖在最后一页的右下角', 'pdf-stamp'),
        (31, ['csv_AI岗位薪资.csv', 'employee_list.xlsx', 'excel_员工花名册.xlsx', 'orders.csv'], '把这些CSV转成Excel', 'table-convert'),
        (32, ['regional_sales.xlsx'], '把每个工作表拆分成单独的文件', 'excel-split'),
        (33, ['contacts_with_duplicates.xlsx'], '按第2列去重', 'excel-dedupe'),
        (34, ['products_v1_July.xlsx', 'products_v2_August.xlsx'], '按id列对比差异', 'excel-diff'),
        (35, ['contacts_merged.csv'], "把第一列按'-'拆分成姓名和电话两列", 'excel-transform'),
        (36, ['staff_split_names.xlsx'], '把第2列和第3列合并成一列', 'excel-transform'),
        (37, ['expense_details.xlsx'], '按部门汇总报销金额,生成一个汇总表', None),
        (38, ['large_dataset.csv'], '这个CSV太大了——查一下它有多少行,表头是什么样的', 'csv-preview'),
        (39, ['animation_clip_C.mov', 'animation_trailer_A.mov'], '把这些MOV全部转成MP4', 'av-convert'),
        (40, ['video_1080p_A.mp4', 'video_1080p_B.mp4'], '全部压缩到1080p,体积约为原来的一半,尽量视觉无损', 'av-compress'),
        (41, ['movie_A.mov', 'movie_B.mp4', 'movie_C.mp4'], '把每个视频的音轨提取为MP3', 'av-extract-audio'),
        (42, ['long_video.mp4'], '每10秒截取一帧保存为图片', 'av-frames'),
        (43, ['clip_01.mp4', 'clip_02.mp4'], '按文件名顺序把这三个视频合并成一个', 'av-merge'),
        (44, ['video_A.mov', 'video_B.mp4', 'video_C.mp4'], '把每个视频裁剪到第10-30秒', 'av-trim'),
        (45, ['animation_A.mp4', 'animation_B.mp4'], '把每个视频的前5秒转成GIF,480像素宽', 'av-gif'),
        (46, ['clip_01.mp4', 'clip_01.srt', 'clip_02.mp4', 'clip_02.srt'], '把字幕烧录进视频', 'av-subtitles'),
        (47, ['ambient_ed.wav', 'clip_bbb.wav'], '把这些WAV全部转成M4A', 'audio-convert'),
        (48, ['part_01.m4a', 'part_02.m4a'], '按文件名顺序把这几段会议录音拼接在一起', 'audio-concat'),
        (49, ['recording_1.wav', 'recording_2.wav'], '把所有这些录音的前5秒剪掉', 'audio-trim'),
        (50, ['noisy_recording_1.wav', 'noisy_recording_2.wav'], '全部降噪', 'audio-denoise'),
        (51, ['english_speech.wav'], '转写这段英文录音', 'audio-transcribe'),
        (52, ['meeting_recording.wav'], '先转写,再总结成会议纪要', None),
        (53, ['retail_01_shopper.jpg', 'retail_02_produce.jpg', 'supermarket_sales.csv'], '分析销售数据并用这些图片做成商业汇报HTML幻灯片', None),
        (54, ['01_django_release_notes.txt', '02_react_changelog.txt'], '总结成一页技术生态周报,保存为report.md', None),
        (55, ['meeting_2026_08_03.wav', 'whiteboard_1.jpg', 'whiteboard_2.jpg'], '把录音转成会议纪要,压缩照片,然后全部归档打包', None),
        (56, ['audio_1.wav', 'audio_2.wav', 'brief.docx', 'clip_1.mp4', 'clip_2.mp4', 'data_1.xlsx'], '按类型分到子文件夹并导出一份清单Excel', None),
        (57, ['IMG_1837.jpg', 'IMG_1974.jpg'], '按拍摄时间排序,重命名为vacation_001、vacation_002……', 'rename-batch'),
        (58, ['audio_1.wav', 'audio_2.wav', 'backup_photo.jpg', 'clip_1.mp4', 'clip_2.mp4', 'data_1.xlsx'], '根据MD5删除重复文件', 'dedupe-safe'),
        (59, ['CODE_OF_CONDUCT.md', 'LICENSE', 'README.md', 'index.html'], '把页面配色改成深色主题，并保持可访问性', None),
        (60, ['archive.zip', 'large_file_for_split.bin'], '解压这个zip', 'zip-batch'),
        (61, ['01_professional_services_agreement.docx', '02_mutual_nda.docx', '06_project_workflow.png'], '用密码abc123加密打包这份商业资料包', 'zip-encrypt'),
        (62, ['urls_to_encode.txt'], '把这个链接生成二维码', None),
        (63, ['qrcode_screenshot_1.png', 'qrcode_screenshot_2.png'], '识别图中的二维码', 'qr-read'),
]

NEGATIVE_REQUESTS = [
    (["a.png", "b.png"], "顺时针旋转 90 度并压缩"),
    (["a.png", "b.png"], "压缩后转成webp"),
    (["a.png"], "帮我处理一下这张图"),
    (["a.pdf", "b.pdf"], "合并这些PDF再加个水印"),
    (["a.wav"], "不要降噪"),
    (["a.mp4"], "把这个视频打包压缩"),
]


class CanonicalRoutingTests(unittest.TestCase):
    def _plan(self, files, instruction):
        with tempfile.TemporaryDirectory() as td:
            paths = []
            for name in files:
                p = Path(td) / name
                p.write_bytes(b"x")
                paths.append(str(p))
            return skills._strict_local_plan(instruction.strip().lower(), paths)

    def test_canonical_63_route_expectations(self):
        for case, files, instruction, expected in CANONICAL_ROUTES:
            with self.subTest(case=case, instruction=instruction):
                plan = self._plan(files, instruction)
                actual = plan["skill"] if plan else None
                self.assertEqual(actual, expected)

    def test_compound_or_negated_requests_stay_with_ai(self):
        for files, request in NEGATIVE_REQUESTS:
            with self.subTest(request=request):
                self.assertIsNone(self._plan(files, request))

    def test_named_column_split_routes_exact_headers_and_replaces_source(self):
        plan = self._plan(["contacts.csv"], "把第一列按'-'拆分成姓名和电话两列")
        self.assertEqual(plan["skill"], "excel-transform")
        self.assertIn("--new-names", plan["args"])
        self.assertEqual(plan["args"][plan["args"].index("--new-names") + 1], "姓名,电话")
        self.assertNotIn("--keep-source", plan["args"])


if __name__ == "__main__":
    unittest.main()
