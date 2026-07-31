"""The 47 real-fixture workflows from the established Folderis QA round."""
from __future__ import annotations


def structural_cases() -> list[dict]:
    """Return stable cross-format cases without resolving paths prematurely."""
    cases = [
        ("W-01", "图片水印", "Test Image", ["img-watermark", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--text", "(c) 2026", "--position", "br"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"text": "(c) 2026", "position": "br"}),
        ("W-02", "图片旋转", "Test Image", ["img-rotate", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--angle", "90"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"angle": 90}),
        ("W-03", "JPG压缩", "Test Image", ["jpg-compress", "michail-sapiton-alCEnNmzhPE-unsplash.jpg"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"quality": 85}),
        ("W-04", "图片转PNG", "Test Image", ["img-convert", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--to", "png"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"format": "png"}),
        ("W-05", "图片改宽", "Test Image", ["img-resize", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--width", "1920"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"width": 1920}),
        ("W-06", "系统OCR", "Test Image", ["img-ocr", "michail-sapiton-alCEnNmzhPE-unsplash.jpg"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"engine": "macOS Vision"}),
        ("W-07", "图片纵向拼接", "Test Image", ["img-stitch", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--direction", "vertical", "--output", "stitched.jpg"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"direction": "vertical"}),
        ("W-08", "图片精确裁剪", "Test Image", ["img-resize", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--crop", "800,600,100,50"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"width": 800, "height": 600, "x": 100, "y": 50}),
        ("W-09", "图片切三段", "Test Image", ["img-split", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--parts", "3"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"parts": 3}),
        ("W-10", "生成ICO", "Test Image", ["img-to-ico", "marko-brecic-Z9P2g8TuTdA-unsplash.png"], ["marko-brecic-Z9P2g8TuTdA-unsplash.png"], {"format": "ico"}),
        ("W-11", "合并DOCX", "Test Docs", ["merge-docs", "采购合同A.docx", "采购合同B.docx", "--output", "合并.docx"], ["采购合同A.docx", "采购合同B.docx"], {"format": "docx", "input_count": 2}),
        ("W-12", "DOCX转PDF", "Test Docs", ["pdf-convert", "--file", "采购合同A.docx", "--to", "pdf"], ["采购合同A.docx"], {"format": "pdf"}),
        ("W-13", "TXT清理", "Test Docs", ["txt-clean", "待清理.txt", "--trim", "--collapse-blank"], ["待清理.txt"], {"trim": True, "collapse_blank": True}),
        ("W-14", "GBK转UTF8", "Test Docs", ["encoding-convert", "销售说明_gbk.txt", "--source", "gbk", "--target", "utf-8"], ["销售说明_gbk.txt"], {"source_encoding": "gbk", "target_encoding": "utf-8"}),
        ("W-15", "TXT按千行切分", "Test Docs", ["txt-split", "长日志.txt", "--lines", "1000"], ["长日志.txt"], {"lines_per_part": 1000}),
        ("W-16", "DOCX模板填充", "Test Docs", ["docx-fill", "聘书模板.docx", "名单.xlsx"], ["聘书模板.docx", "名单.xlsx"], {"one_output_per_data_row": True}),
        ("W-17", "合并PDF", "Test PDF", ["pdf-merge", "ai_agents_handbook_pages_2-5.pdf", "ai_agents_handbook_pages_2-5-v1.1.pdf", "--output", "merged.pdf"], ["ai_agents_handbook_pages_2-5.pdf", "ai_agents_handbook_pages_2-5-v1.1.pdf"], {"expected_pages": 8}),
        ("W-18", "压缩PDF", "Test PDF", ["pdf-compress", "ai_agents_handbook.pdf"], ["ai_agents_handbook.pdf"], {"preserve_page_count": True}),
        ("W-19", "加密PDF", "Test PDF", ["pdf-crypt", "encrypt", "ai_agents_handbook_pages_2-5.pdf", "--new-password", "abc123", "--output", "加密.pdf"], ["ai_agents_handbook_pages_2-5.pdf"], {"password": "abc123"}),
        ("W-20", "解密PDF", "Test PDF", ["pdf-crypt", "decrypt", "加密.pdf", "--password", "abc123", "--output", "解密.pdf"], ["加密.pdf"], {"password": "abc123"}),
        ("W-21", "PDF逐页拆分", "Test PDF", ["pdf-split", "ai_agents_handbook_pages_2-5.pdf"], ["ai_agents_handbook_pages_2-5.pdf"], {"expected_parts": 4, "pages_per_part": 1}),
        ("W-22", "PDF重排", "Test PDF", ["pdf-reorder", "ai_agents_handbook_pages_2-5.pdf", "3,1,2", "--output", "reordered.pdf"], ["ai_agents_handbook_pages_2-5.pdf"], {"order": [3, 1, 2]}),
        ("W-23", "PDF转TXT", "Test PDF", ["pdf-convert", "--file", "ai_agents_handbook_pages_2-5.pdf", "--to", "txt"], ["ai_agents_handbook_pages_2-5.pdf"], {"format": "txt", "pages": "all"}),
        ("W-24", "PDF转PNG", "Test PDF", ["pdf-convert", "--file", "ai_agents_handbook_pages_2-5.pdf", "--to", "png", "--pages", "all"], ["ai_agents_handbook_pages_2-5.pdf"], {"format": "png", "expected_pages": 4}),
        ("W-25", "PDF水印", "Test PDF", ["pdf-watermark", "ai_agents_handbook_pages_2-5.pdf", "--text", "机密"], ["ai_agents_handbook_pages_2-5.pdf"], {"text": "机密"}),
        ("W-26", "PDF盖章", "Test PDF", ["pdf-stamp", "ai_agents_handbook_pages_2-5.pdf", "--image", "../Test Misc/印章.png", "--page", "last", "--position", "br"], ["ai_agents_handbook_pages_2-5.pdf", "../Test Misc/印章.png"], {"page": "last", "position": "br"}),
        ("W-27", "XLSX转CSV", "Test Excel", ["table-convert", "样例数据.xlsx"], ["样例数据.xlsx"], {"format": "csv"}),
        ("W-28", "Excel工作表拆分", "Test Excel", ["excel-split", "Free_Test_Data_1MB_XLSX.xlsx"], ["Free_Test_Data_1MB_XLSX.xlsx"], {"one_output_per_sheet": True}),
        ("W-29", "Excel按列去重", "Test Excel", ["excel-dedupe", "样例数据.xlsx", "--columns", "2"], ["样例数据.xlsx"], {"columns": [2]}),
        ("W-30", "Excel两表对比", "Test Excel", ["excel-diff", "星辰科技_2025年上半年财务数据.xlsx", "星辰科技_2025年下半年财务数据.xlsx"], ["星辰科技_2025年上半年财务数据.xlsx", "星辰科技_2025年下半年财务数据.xlsx"], {"comparison": "keyed_rows"}),
        ("W-31", "Excel列拆分", "Test Excel", ["excel-transform", "待拆分示例.xlsx", "--split-column", "1", "--delimiter", "-"], ["待拆分示例.xlsx"], {"split_column": 1, "delimiter": "-"}),
        ("W-32", "Excel分组求和", "Test Excel", ["excel-groupby", "样例数据.xlsx", "--by", "5", "--agg", "sum", "--value", "6"], ["样例数据.xlsx"], {"group_by": 5, "aggregation": "sum", "value_column": 6}),
        ("W-33", "Excel按键更新", "Test Excel", ["excel-update-by-key", "--source", "星辰科技_2025年下半年财务数据.xlsx", "--target", "星辰科技_2025年上半年财务数据.xlsx", "--key", "1", "--output", "同比.xlsx"], ["星辰科技_2025年下半年财务数据.xlsx", "星辰科技_2025年上半年财务数据.xlsx"], {"key_column": 1}),
        ("W-34", "CSV预览", "Test Excel", ["csv-preview", "file_example_XLS_100.csv"], ["file_example_XLS_100.csv"], {"preview_only": True}),
        ("W-35", "Excel按列拆文件", "Test Excel", ["excel-split-column", "样例数据.xlsx", "--by", "5"], ["样例数据.xlsx"], {"by_column": 5}),
        ("W-36", "Excel模糊合并", "Test Excel", ["excel-fuzzy-merge", "样例数据.xlsx", "样例数据.xlsx", "--key", "1"], ["样例数据.xlsx"], {"key_column": 1}),
        ("W-37", "Excel提取邮箱", "Test Excel", ["extract-patterns", "待提取示例.xlsx", "--type", "email", "--context", "分公司"], ["待提取示例.xlsx"], {"pattern_type": "email", "context": "分公司"}),
        ("W-38", "视频转MKV", "Test Video", ["av-convert", "file_example_MP4_1280_10MG.mp4", "--to", "mkv"], ["file_example_MP4_1280_10MG.mp4"], {"format": "matroska"}),
        ("W-39", "视频提取MP3", "Test Video", ["av-extract-audio", "file_example_MP4_1280_10MG.mp4", "--to", "mp3"], ["file_example_MP4_1280_10MG.mp4"], {"format": "mp3"}),
        ("W-40", "视频每十秒截帧", "Test Video", ["av-frames", "file_example_MP4_1280_10MG.mp4", "--every", "10"], ["file_example_MP4_1280_10MG.mp4"], {"every_seconds": 10}),
        ("W-41", "视频转GIF", "Test Video", ["av-gif", "file_example_MP4_1280_10MG.mp4", "--width", "480", "--duration", "5"], ["file_example_MP4_1280_10MG.mp4"], {"width": 480, "duration_seconds": 5, "fps": 12}),
        ("W-42", "音频转M4A", "Test Audio", ["audio-convert", "clip_a.wav", "--to", "m4a"], ["clip_a.wav"], {"format": "m4a"}),
        ("W-43", "音频拼接", "Test Audio", ["audio-concat", "clip_a.wav", "clip_b.wav", "--output", "joined.wav"], ["clip_a.wav", "clip_b.wav"], {"expected_duration_seconds": 7}),
        ("W-44", "目录清单Excel", "Test Image", ["dir-inventory", ".", "--output", "../Test Misc/清单.xlsx"], ["."], {"format": "xlsx", "recursive": True}),
        ("W-45", "文件MD5", "Test Image", ["hash-files", "michail-sapiton-alCEnNmzhPE-unsplash.jpg", "marko-brecic-Z9P2g8TuTdA-unsplash.png", "--algo", "md5"], ["michail-sapiton-alCEnNmzhPE-unsplash.jpg", "marko-brecic-Z9P2g8TuTdA-unsplash.png"], {"algorithm": "md5"}),
        ("W-46", "AES加密压缩包", "Test Misc", ["zip-encrypt", "../Test Image/michail-sapiton-alCEnNmzhPE-unsplash.jpg", "--password", "abc123", "--output", "enc.zip"], ["../Test Image/michail-sapiton-alCEnNmzhPE-unsplash.jpg"], {"password": "abc123", "format": "zip"}),
        ("W-47", "生成二维码", "Test Misc", ["qr-make", "https://folderis.app", "--output", "qr.png"], [], {"content": "https://folderis.app", "size": 512}),
    ]
    return [
        {
            "id": id_,
            "label": label,
            "cwd": cwd,
            "args": args,
            "inputs": inputs,
            "parameters": parameters,
        }
        for id_, label, cwd, args, inputs, parameters in cases
    ]
