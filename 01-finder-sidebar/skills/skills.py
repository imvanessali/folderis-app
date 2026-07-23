#!/usr/bin/env python3
"""FinderSidebar skills toolbox.

One subcommand per skill; the AI agent calls `run_skill` which executes
`venv/bin/python3 skills.py <skill> [args...]` with cwd = the bound folder.
All paths are resolved relative to cwd. Prints a human-readable summary to
stdout; non-zero exit = failure.
"""
import argparse
import atexit
import csv
import hashlib
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unicodedata
import uuid
import zipfile
from datetime import datetime
from pathlib import Path

IS_WIN = sys.platform == "win32"
if IS_WIN:
    # The desktop app reads subprocess output as UTF-8. Keep direct CLI and
    # test-harness runs on Windows consistent instead of inheriting a GBK code page.
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

if IS_WIN:
    SUPPORT_DIR = Path(os.environ.get("FOLDERIS_SUPPORT_DIR") or
                       (Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Sider"))
    _FF_NAME, _FP_NAME = "bin/ffmpeg.exe", "bin/ffprobe.exe"
else:
    SUPPORT_DIR = Path.home() / "Library/Application Support/FinderSidebar"
    _FF_NAME, _FP_NAME = "bin/ffmpeg", "bin/ffprobe"
FFMPEG = os.environ.get("FS_FFMPEG", str(SUPPORT_DIR / _FF_NAME))
FFPROBE = os.environ.get("FS_FFPROBE", str(SUPPORT_DIR / _FP_NAME))
SKILLS_DIR = Path(__file__).resolve().parent

# 依赖 macOS 原生组件（Vision/Speech/PDFKit/CoreImage）的技能，Windows 上明确报不支持
MAC_ONLY_HELPERS = {}  # 所有技能均有 Windows 实现路径


def die(msg, code=1):
    print(f"错误：{msg}", file=sys.stderr)
    sys.exit(code)


def ok(msg):
    print(msg)


def expand(patterns):
    """Expand glob patterns / literal paths into an existing-file list."""
    out = []
    for p in patterns:
        path = Path(p)
        if path.exists():
            out.append(path)
            continue
        matches = sorted(Path(".").glob(p))
        if not matches:
            die(f"找不到文件：{p}")
        out.extend(matches)
    return out


def helper(name):
    """优先用打包的编译版组件（bin/<name>）；开发机上回退 swift 解释器。"""
    if IS_WIN:
        die(f"「{MAC_ONLY_HELPERS.get(name, name)}」技能暂不支持 Windows（依赖 macOS 系统组件，移植开发中）。"
            "请如实告知用户此限制。")
    binary = SUPPORT_DIR / "bin" / name
    if binary.exists():
        return [str(binary)]
    return ["swift", str(SKILLS_DIR / f"{name}.swift")]


def _win_office_to_pdf(src, dst):
    """Word/WPS 的 COM 接口转换：国内办公机基本必有其一。"""
    try:
        import win32com.client
    except ImportError:
        die("缺少 pywin32（运行时装完即有；若仍报错请重装技能运行时）")
    import pythoncom
    pythoncom.CoInitialize()
    last_err = None
    for prog in ("Word.Application", "KWPS.Application", "Kwps.Application"):
        try:
            app = win32com.client.DispatchEx(prog)
        except Exception as e:
            last_err = e
            continue
        try:
            app.Visible = False
            doc = app.Documents.Open(str(Path(src).resolve()))
            doc.ExportAsFixedFormat(str(Path(dst).resolve()), 17)  # 17 = PDF
            doc.Close(False)
            return
        except Exception as e:
            last_err = e
        finally:
            try: app.Quit()
            except Exception: pass
    die(f"未检测到可用的 Microsoft Word 或 WPS（{last_err}）。"
        "可引导用户安装 LibreOffice（install-component libreoffice）作为替代。")


def _fitz():
    try:
        import fitz  # PyMuPDF
        return fitz
    except ImportError:
        die("缺少 PyMuPDF（运行时装完即有；若仍报错请重装技能运行时）")


def _page_numbers(spec, total):
    if not spec or spec.strip().lower() == "all":
        return list(range(1, total + 1))
    result = []
    for part in spec.split(","):
        part = part.strip()
        try:
            if "-" in part:
                start, end = (int(v.strip()) for v in part.split("-", 1))
                values = range(start, end + 1)
            else:
                values = [int(part)]
        except ValueError:
            die(f"无效页码范围：{spec}（示例：5 或 1-3,7）")
        for page in values:
            if page < 1 or page > total:
                die(f"页码 {page} 超出范围（PDF 共 {total} 页）")
            if page not in result:
                result.append(page)
    if not result:
        die("没有指定任何页面")
    return result


def _win_pdf_render(src, out_dir, fmt, dpi, pages=None):
    fitz = _fitz()
    doc = fitz.open(str(src))
    for page_no in _page_numbers(pages, len(doc)):
        page = doc[page_no - 1]
        pix = page.get_pixmap(dpi=int(dpi))
        pix.save(str(Path(out_dir) / f"page_{page_no:03d}.{fmt}"))
    doc.close()


def _win_pdf_watermark(src, dst, text, opacity, font_size):
    fitz = _fitz()
    doc = fitz.open(str(src))
    for page in doc:
        tw = fitz.TextWriter(page.rect, opacity=float(opacity), color=(0.55, 0.57, 0.60))
        font = fitz.Font("china-s")
        w = font.text_length(text, fontsize=float(font_size))
        step_x, step_y = w + 120, float(font_size) + 110
        span = max(page.rect.width, page.rect.height) * 1.6
        y = -span
        while y < span:
            x = -span
            while x < span:
                tw.append((x, y), text, font=font, fontsize=float(font_size))
                x += step_x
            y += step_y
        center = fitz.Point(page.rect.width / 2, page.rect.height / 2)
        tw.write_text(page, morph=(center, fitz.Matrix(45)))
    doc.save(str(dst))
    doc.close()


def _win_pdf_stamp(src, dst, image, page_spec, pos, width):
    fitz = _fitz()
    doc = fitz.open(str(src))
    from PIL import Image as _I
    iw, ih = _I.open(image).size
    w = float(width); h = w * ih / iw; m = 36
    if page_spec == "all": targets = range(len(doc))
    elif page_spec == "last": targets = [len(doc) - 1]
    else: targets = [int(page_spec) - 1]
    for i in targets:
        page = doc[i]; r = page.rect
        origin = {
            "bl": (r.x0 + m, r.y1 - h - m), "tr": (r.x1 - w - m, r.y0 + m),
            "tl": (r.x0 + m, r.y0 + m), "center": (r.width / 2 - w / 2, r.height / 2 - h / 2),
        }.get(pos, (r.x1 - w - m, r.y1 - h - m))  # 默认 br
        page.insert_image(fitz.Rect(origin[0], origin[1], origin[0] + w, origin[1] + h),
                          filename=str(image))
    doc.save(str(dst))
    doc.close()


def _win_ocr_text(path):
    """Windows 10+ 系统自带 OCR 引擎（中英文取决于系统语言包）。"""
    try:
        import winocr
        from PIL import Image as _I
    except ImportError:
        die("缺少 winocr（重装技能运行时即可）")
    img = _I.open(path).convert("RGB")
    for lang in ("zh-Hans", "zh-CN", "en-US", ""):
        try:
            r = winocr.recognize_pil_sync(img, lang) if lang else winocr.recognize_pil_sync(img)
            text = (r.get("text") or "").strip()
            if text:
                return text
        except Exception:
            continue
    return ""


def _pdf_ocr_text(src, dpi=220, password=None, pages=None):
    """Render every PDF page, then OCR it. Never trust only the PDF text layer."""
    src = Path(src)
    with tempfile.TemporaryDirectory(prefix="folderis-pdf-ocr-") as temp:
        work = Path(temp)
        render_src = src
        if password:
            from pypdf import PdfWriter
            writer = PdfWriter()
            for page in _reader(src, password).pages:
                writer.add_page(page)
            render_src = work / "unlocked.pdf"
            with render_src.open("wb") as fh:
                writer.write(fh)

        pages_dir = work / "pages"
        pages_dir.mkdir()
        if IS_WIN:
            _win_pdf_render(render_src, pages_dir, "png", dpi, pages)
        else:
            command = [*helper("pdfrender"), str(render_src), str(pages_dir), "png", str(dpi)]
            if pages:
                command.append(pages)
            run(command)

        images = sorted(pages_dir.glob("page_*.png"))
        if not images:
            die(f"PDF 没有可识别的页面：{src.name}")

        pages = []
        for image in images:
            page_no = int(image.stem.rsplit("_", 1)[-1])
            if IS_WIN:
                text = _win_ocr_text(image)
            else:
                text_file = work / f"page_{page_no:03d}.txt"
                run([*helper("ocr"), str(image), str(text_file)])
                text = text_file.read_text(encoding="utf-8").strip()
            pages.append(f"=== 第 {page_no} 页 ===\n{text}".rstrip())
        return "\n\n".join(pages) + "\n"


def ffmpeg_or_die():
    if not Path(FFMPEG).exists():
        src = "gyan.dev 官方构建" if IS_WIN else "evermeet.cx 官方静态版"
        die(f"ffmpeg 未安装。请先询问用户：音视频处理需要一次性下载 ffmpeg 组件（约 80MB，来自 {src}）。"
            "用户同意后调用技能 install-component ffmpeg 即可自动安装；拒绝则说明无法处理音视频。")
    return FFMPEG


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        die(f"命令失败：{' '.join(str(c) for c in cmd[:4])}…\n{r.stderr[-800:]}")
    return r


# ---------------------------------------------------------------- documents

def cmd_rename_batch(a):
    files = expand(a.files)
    plan = []
    for i, f in enumerate(sorted(files), start=a.start):
        name = f.stem
        if a.regex and a.replace is not None:
            name = re.sub(a.regex, a.replace, name)
        if a.template:
            name = a.template.replace("{name}", name) \
                             .replace("{n}", str(i).zfill(a.pad)) \
                             .replace("{date}", datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d"))
        new = f.with_name(name + (a.ext or f.suffix))
        if new != f:
            plan.append((f, new))
    if a.dry_run:
        for src, dst in plan:
            print(f"{src.name} -> {dst.name}")
        ok(f"（预览，共 {len(plan)} 项，未执行）")
        return
    for src, dst in plan:
        if dst.exists():
            die(f"目标已存在：{dst.name}")
        src.rename(dst)
    ok(f"已重命名 {len(plan)} 个文件")


def _reader(path, password=None):
    from pypdf import PdfReader
    r = PdfReader(str(path))
    if r.is_encrypted:
        r.decrypt(password or "")
    return r


def cmd_pdf_split(a):
    from pypdf import PdfWriter
    r = _reader(a.file, a.password)
    src = Path(a.file)
    if a.ranges:
        ranges = a.ranges.split(",")
        if a.output and len(ranges) != 1:
            die("多个页码范围不能共用一个 --output；请分别处理")
        for idx, rng in enumerate(ranges, 1):
            w = PdfWriter()
            lo, _, hi = rng.partition("-")
            lo, hi = int(lo), int(hi or lo)
            if lo < 1 or hi < lo or hi > len(r.pages):
                die(f"页码范围超出 PDF 边界：{rng}（共 {len(r.pages)} 页）")
            for p in range(lo - 1, hi):
                w.add_page(r.pages[p])
            label = re.sub(r"[^0-9-]", "", rng) or str(idx)
            out = Path(a.output) if a.output else src.with_name(f"{src.stem}_pages_{label}.pdf")
            out = available_output(out, explicit=bool(a.output))
            with open(out, "wb") as fh:
                w.write(fh)
        ok(f"已按范围拆分为 {len(ranges)} 个文件")
    else:
        for i, page in enumerate(r.pages, 1):
            w = PdfWriter()
            w.add_page(page)
            with open(available_output(src.with_name(f"{src.stem}_p{i:03d}.pdf")), "wb") as fh:
                w.write(fh)
        ok(f"已拆分为 {len(r.pages)} 个单页 PDF")


def cmd_pdf_reorder(a):
    from pypdf import PdfWriter
    r = _reader(a.file, a.password)
    order = [int(x) for x in a.order.split(",")]
    w = PdfWriter()
    for p in order:
        w.add_page(r.pages[p - 1])
    out = available_output(Path(a.output or Path(a.file).with_name(Path(a.file).stem + "_reordered.pdf")), explicit=bool(a.output))
    with open(out, "wb") as fh:
        w.write(fh)
    ok(f"已按顺序 {a.order} 生成 {out.name}（{len(order)} 页）")


def cmd_pdf_merge(a):
    from pypdf import PdfWriter
    w = PdfWriter()
    files = expand(a.files)
    for f in files:
        for page in _reader(f).pages:
            w.add_page(page)
    out = available_output(Path(a.output), explicit=True)
    with open(out, "wb") as fh:
        w.write(fh)
    ok(f"已合并 {len(files)} 个 PDF → {out}")


def cmd_pdf_crypt(a):
    from pypdf import PdfWriter
    r = _reader(a.file, a.password)
    w = PdfWriter()
    for page in r.pages:
        w.add_page(page)
    out = available_output(Path(a.output or Path(a.file).with_name(Path(a.file).stem + ("_encrypted" if a.mode == "encrypt" else "_decrypted") + ".pdf")), explicit=bool(a.output))
    if a.mode == "encrypt":
        if not a.new_password:
            die("encrypt 需要 --new-password")
        w.encrypt(a.new_password)
        with open(out, "wb") as fh:
            w.write(fh)
        ok(f"已加密 → {out.name}")
    else:  # decrypt / strip restrictions: rewrite without encryption
        with open(out, "wb") as fh:
            w.write(fh)
        ok(f"已解除加密/复制打印限制 → {out.name}")


def cmd_pdf_compress(a):
    """无损压缩：压缩内容流 + 去重对象 + 清理孤儿对象，不改动任何内容。
    对扫描件（本身就是压缩图片）效果有限，会如实报告。"""
    from pypdf import PdfWriter
    files = expand(a.files)
    total_before = total_after = 0
    for f in files:
        before = f.stat().st_size
        writer = PdfWriter(clone_from=str(f))
        for page in writer.pages:
            page.compress_content_streams()
        try:
            writer.compress_identical_objects(remove_duplicates=True, remove_unreferenced=True)
        except TypeError:
            writer.compress_identical_objects(remove_identicals=True, remove_orphans=True)
        except Exception:
            pass
        out = f if a.in_place else available_output(f.with_name(f.stem + "_compressed.pdf"))
        with open(out, "wb") as fh:
            writer.write(fh)
        after = out.stat().st_size
        if after >= before and not a.in_place:
            shutil.copyfile(f, out)
            after = before
            print(f"{f.name}: 已是最优结构，无可压缩空间")
        else:
            print(f"{f.name}: {before//1024}KB → {after//1024}KB（-{100 - after*100//max(before,1)}%）")
        total_before += before
        total_after += after
    ok(f"合计 {total_before//1024}KB → {total_after//1024}KB（无损，内容与页数不变；扫描件类 PDF 压缩空间有限）")


def cmd_pdf_convert(a):
    src = Path(a.file) if a.file else None
    if a.to in ("png", "jpg"):
        if not a.pages:
            die("PDF 转图片必须明确指定 --pages（如 --pages 1 或 --pages all），不能默认处理全部页面")

        requested = a.pages.strip()
        out_dir = available_output(Path(a.output or f"{src.stem}_pages"), explicit=bool(a.output))

        out_dir.parent.mkdir(parents=True, exist_ok=True)
        temp_dir = Path(tempfile.mkdtemp(prefix=".folderis-pdf-pages-", dir=out_dir.parent))
        try:
            page_spec = None if requested.lower() == "all" else requested
            if IS_WIN:
                _win_pdf_render(src, temp_dir, a.to, a.dpi, page_spec)
            else:
                command = [*helper("pdfrender"), str(src), str(temp_dir), a.to, str(a.dpi)]
                if page_spec:
                    command.append(page_spec)
                run(command)
            n = len(list(temp_dir.glob(f"*.{a.to}")))
            if n == 0:
                die("没有生成任何页面图片")
            temp_dir.replace(out_dir)
        except BaseException:
            shutil.rmtree(temp_dir, ignore_errors=True)
            raise
        ok(f"已按 --pages {requested} 渲染 {n} 页 → {out_dir}/")
    elif a.to == "txt":
        text = _pdf_ocr_text(src, max(a.dpi, 220), a.password, a.pages)
        out = available_output(Path(a.output or src.with_suffix(".txt")), explicit=bool(a.output))
        out.write_text(text, encoding="utf-8")
        ok(f"已逐页 OCR 提取文本 → {out.name}（{len(text)} 字符）")
    elif a.to == "docx":
        soffice = shutil.which("soffice") or (
            "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            if Path("/Applications/LibreOffice.app").exists() else None)
        if soffice:
            out = available_output(Path(a.output or src.with_suffix(".docx")), explicit=bool(a.output))
            temp_dir = Path(tempfile.mkdtemp(prefix="folderis-docx-"))
            try:
                run([soffice, "--headless", "--convert-to", "docx", "--outdir", str(temp_dir), str(src)])
                generated = temp_dir / src.with_suffix(".docx").name
                if not generated.exists():
                    die("LibreOffice 没有生成 DOCX")
                shutil.move(str(generated), str(out))
            finally:
                shutil.rmtree(temp_dir, ignore_errors=True)
            ok(f"已高保真转换 → {out.name}（LibreOffice）")
        else:
            text = "\n\n".join(p.extract_text() or "" for p in _reader(src, a.password).pages)
            handle = tempfile.NamedTemporaryFile(
                mode="w", suffix=".txt", encoding="utf-8", delete=False)
            tmp = Path(handle.name)
            handle.write(text)
            handle.close()
            out = available_output(Path(a.output or src.with_suffix(".docx")), explicit=bool(a.output))
            try:
                run(["textutil", "-convert", "docx", str(tmp), "-output", str(out)])
            finally:
                tmp.unlink(missing_ok=True)
            ok(f"已转换（纯文字级，排版/表格/图片未保留）→ {out.name}。如需高保真请安装 LibreOffice")
    elif a.to == "pdf":  # docx/doc/rtf/html/txt → pdf（AppKit + Core Text 原生排版）
        if src.suffix.lower() in (".docx", ".doc", ".txt", ".rtf", ".html", ".htm", ".md"):
            out = available_output(Path(a.output or src.with_suffix(".pdf")), explicit=bool(a.output))
            if IS_WIN:
                _win_office_to_pdf(src, out)
            else:
                run([*helper("doc2pdf"), str(src), str(out)])
            if not out.exists() or out.stat().st_size == 0:
                die("转换失败：输出为空")
            ok(f"已转换 → {out.name}（{out.stat().st_size // 1024}KB）")
        else:
            die(f"暂不支持 {src.suffix} → pdf")
    elif a.to == "images-to-pdf":
        files = expand(a.files)
        imgs = [_open_image(f).convert("RGB") for f in files]
        out = available_output(Path(a.output or "merged.pdf"), explicit=bool(a.output))
        imgs[0].save(out, save_all=True, append_images=imgs[1:])
        ok(f"已把 {len(imgs)} 张图片合成 → {out.name}")
    else:
        die(f"未知转换目标 {a.to}")


def cmd_merge_docs(a):
    files = expand(a.files)
    exts = {f.suffix.lower() for f in files}
    out = available_output(Path(a.output), explicit=True)
    if exts <= {".txt", ".md"}:
        with open(out, "w", encoding="utf-8") as fh:
            for f in files:
                fh.write(f.read_text(encoding="utf-8", errors="replace"))
                fh.write("\n\n")
        ok(f"已合并 {len(files)} 个文本 → {out.name}")
    elif exts <= {".docx", ".doc", ".rtf", ".txt"}:
        run(["textutil", "-cat", "docx", *map(str, files), "-output", str(out)])
        ok(f"已合并 {len(files)} 个文档 → {out.name}")
    else:
        die(f"不支持混合类型合并：{exts}")


def cmd_txt_clean(a):
    files = expand(a.files)
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        if a.trim:
            text = "\n".join(line.rstrip() for line in text.split("\n"))
        if a.collapse_blank:
            text = re.sub(r"\n{3,}", "\n\n", text)
        if a.strip_all_blank:
            text = "\n".join(l for l in text.split("\n") if l.strip())
        target = f if a.in_place else available_output(f.with_name(f.stem + "_clean" + f.suffix))
        target.write_text(text, encoding="utf-8")
    ok(f"已清理 {len(files)} 个文本文件")


def cmd_txt_split(a):
    f = Path(a.file)
    text = f.read_text(encoding="utf-8", errors="replace")
    parts = []
    if a.lines:
        rows = text.split("\n")
        parts = ["\n".join(rows[i:i + a.lines]) for i in range(0, len(rows), a.lines)]
    elif a.chars:
        parts = [text[i:i + a.chars] for i in range(0, len(text), a.chars)]
    elif a.delimiter:
        parts = text.split(a.delimiter)
    else:
        die("需要 --lines / --chars / --delimiter 之一")
    for i, part in enumerate(parts, 1):
        available_output(f.with_name(f"{f.stem}_part{i:03d}{f.suffix}")).write_text(part, encoding="utf-8")
    ok(f"已分割为 {len(parts)} 个文件")


def cmd_excel_split(a):
    import openpyxl
    src = Path(a.file)
    wb = openpyxl.load_workbook(str(src))
    for name in wb.sheetnames:
        single = openpyxl.Workbook()
        single.remove(single.active)
        ws_src = wb[name]
        ws_new = single.create_sheet(title=name)
        for row in ws_src.iter_rows(values_only=True):
            ws_new.append(row)
        safe = re.sub(r'[/\\:*?"<>|]', "_", name)
        single.save(available_output(src.with_name(f"{src.stem}_{safe}.xlsx")))
    ok(f"已把 {len(wb.sheetnames)} 个工作表拆分为独立文件")


def cmd_excel_merge(a):
    import openpyxl
    files = expand(a.files)
    out_wb = openpyxl.Workbook()
    out_wb.remove(out_wb.active)
    if a.into_one_sheet:
        ws = out_wb.create_sheet("merged")
        header_written = False
        for f in files:
            wb = openpyxl.load_workbook(str(f), read_only=True)
            for sheet in wb.worksheets:
                rows = sheet.iter_rows(values_only=True)
                header = next(rows, None)
                if header is None:
                    continue
                if not header_written:
                    ws.append(header)
                    header_written = True
                for row in rows:
                    ws.append(row)
    else:
        for f in files:
            wb = openpyxl.load_workbook(str(f), read_only=True)
            for sheet in wb.worksheets:
                title = f"{Path(f).stem}_{sheet.title}"[:31]
                ws = out_wb.create_sheet(title)
                for row in sheet.iter_rows(values_only=True):
                    ws.append(row)
    out = available_output(Path(a.output), explicit=True)
    out_wb.save(out)
    ok(f"已合并 {len(files)} 个表格 → {out}")


def cmd_excel_dedupe(a):
    import openpyxl
    src = Path(a.file)
    wb = openpyxl.load_workbook(str(src))
    ws = wb.active
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        die("空表")
    header, body = rows[0], rows[1:]
    keys = [int(k) - 1 for k in a.columns.split(",")] if a.columns else list(range(len(header)))
    seen, kept = set(), []
    for row in body:
        sig = tuple(row[k] for k in keys)
        if sig not in seen:
            seen.add(sig)
            kept.append(row)
    out_wb = openpyxl.Workbook()
    out_ws = out_wb.active
    out_ws.append(header)
    for row in kept:
        out_ws.append(row)
    out = available_output(src.with_name(src.stem + "_dedup.xlsx"))
    out_wb.save(out)
    ok(f"去重完成：{len(body)} 行 → {len(kept)} 行（移除 {len(body) - len(kept)}）→ {out.name}")


def cmd_excel_diff(a):
    import openpyxl
    def load(path):
        wb = openpyxl.load_workbook(str(path), read_only=True)
        return list(wb.active.iter_rows(values_only=True))
    ra, rb = load(a.file_a), load(a.file_b)
    keys = [int(k) - 1 for k in a.columns.split(",")] if a.columns else [0]
    def index(rows):
        return {tuple(r[k] for k in keys): r for r in rows[1:]}
    ia, ib = index(ra), index(rb)
    only_a = [k for k in ia if k not in ib]
    only_b = [k for k in ib if k not in ia]
    changed = [k for k in ia if k in ib and ia[k] != ib[k]]
    print(f"仅在 {a.file_a}：{len(only_a)} 行")
    for k in only_a[:20]:
        print("  A:", k)
    print(f"仅在 {a.file_b}：{len(only_b)} 行")
    for k in only_b[:20]:
        print("  B:", k)
    print(f"键相同但内容不同：{len(changed)} 行")
    for k in changed[:20]:
        print("  Δ:", k)


def cmd_excel_transform(a):
    """列级变换：按分隔符/正则把一列拆成多列，或多列合并成一列。
    新列插入在源列右侧，不覆盖已有数据。"""
    import openpyxl
    src = Path(a.file)
    wb = openpyxl.load_workbook(str(src))
    ws = wb[a.sheet] if a.sheet else wb.active
    first_data_row = 1 if a.no_header else 2

    if a.split_column:
        col = a.split_column

        def parts_of(value):
            s = "" if value is None else str(value)
            if a.regex:
                m = re.search(a.regex, s)
                return [g if g is not None else "" for g in m.groups()] if m else []
            if a.delimiter:
                return s.split(a.delimiter)
            die("拆分需要 --delimiter 或 --regex（正则用捕获组定义各列）")

        n = 0
        for row in ws.iter_rows(min_row=first_data_row):
            n = max(n, len(parts_of(row[col - 1].value)))
        if n < 2:
            die("没有可拆分的内容（检查分隔符/正则是否匹配）")

        ws.insert_cols(col + 1, n)
        if not a.no_header:
            base = ws.cell(row=1, column=col).value or f"列{col}"
            for i in range(n):
                ws.cell(row=1, column=col + 1 + i, value=f"{base}_{i + 1}")
        filled = 0
        for r in range(first_data_row, ws.max_row + 1):
            parts = parts_of(ws.cell(row=r, column=col).value)
            if parts:
                filled += 1
            for i, part in enumerate(parts[:n]):
                ws.cell(row=r, column=col + 1 + i,
                        value=part.strip() if isinstance(part, str) else part)
        if a.drop_source:
            ws.delete_cols(col)
        summary = f"已把第 {col} 列拆成 {n} 列（{filled} 行有内容）"

    elif a.merge_columns:
        cols = [int(c) for c in a.merge_columns.split(",")]
        sep = a.delimiter if a.delimiter is not None else ""
        target = max(cols) + 1
        ws.insert_cols(target)
        if not a.no_header:
            names = [str(ws.cell(row=1, column=c).value or c) for c in cols]
            ws.cell(row=1, column=target, value="+".join(names))
        for r in range(first_data_row, ws.max_row + 1):
            values = [ws.cell(row=r, column=c).value for c in cols]
            joined = sep.join("" if v is None else str(v) for v in values)
            ws.cell(row=r, column=target, value=joined)
        summary = f"已把列 {a.merge_columns} 合并到第 {target} 列"
    else:
        die("需要 --split-column 或 --merge-columns")

    out = src if a.in_place else available_output(src.with_name(src.stem + "_transformed.xlsx"))
    wb.save(out)
    ok(f"{summary} → {out.name}")


def cmd_csv_preview(a):
    f = Path(a.file)
    size = f.stat().st_size
    n_rows = 0
    head = []
    with open(f, newline="", encoding=a.encoding, errors="replace") as fh:
        reader = csv.reader(fh)
        for i, row in enumerate(reader):
            if i < a.rows:
                head.append(row)
            n_rows += 1
    print(f"文件 {f.name}：{size/1e6:.1f} MB，共 {n_rows} 行，{len(head[0]) if head else 0} 列")
    for row in head:
        print(" | ".join(str(c)[:30] for c in row[:12]))


def _detect_encoding(raw):
    """utf-8 → 常见 CJK 编码逐个严格试解 → chardet 兜底。
    chardet 在小样本上容易误判，中文场景优先走确定性路径。"""
    for enc in ("utf-8", "gb18030", "big5", "shift_jis"):
        try:
            raw.decode(enc)
            return enc
        except (UnicodeDecodeError, LookupError):
            continue
    import chardet
    return chardet.detect(raw[:200_000])["encoding"] or "latin-1"


def cmd_encoding_convert(a):
    files = expand(a.files)
    for f in files:
        raw = f.read_bytes()
        enc = a.source or _detect_encoding(raw)
        text = raw.decode(enc, errors="replace")
        target = f if a.in_place else available_output(f.with_name(f.stem + "_utf8" + f.suffix))
        target.write_text(text, encoding=a.target)
        print(f"{f.name}: {enc} → {a.target}")
    ok(f"已转换 {len(files)} 个文件编码")


# ------------------------------------------------------------------ images

def _open_image(path):
    from PIL import Image
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    try:
        return Image.open(path)
    except Exception:
        if not IS_WIN and Path(path).suffix.lower() in (".heic", ".heif"):
            # macOS decodes HEIF natively through sips, so the optional Python
            # plugin must never block otherwise supported image operations.
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                converted = Path(tmp.name)
            try:
                run(["sips", "-s", "format", "png", str(path), "--out", str(converted)])
                with Image.open(converted) as image:
                    return image.copy()
            finally:
                converted.unlink(missing_ok=True)
        raise


def _sips_dimensions(path):
    result = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)])
    width = re.search(r"pixelWidth:\s*(\d+)", result.stdout)
    height = re.search(r"pixelHeight:\s*(\d+)", result.stdout)
    if not width or not height:
        die(f"无法读取图片尺寸：{Path(path).name}")
    return int(width.group(1)), int(height.group(1))


def _mac_sips_resize(path, args, output):
    target = output
    temporary = None
    if args.in_place:
        handle = tempfile.NamedTemporaryFile(suffix=path.suffix, delete=False)
        handle.close()
        temporary = Path(handle.name)
        target = temporary

    command = ["sips"]
    if args.width and args.height:
        command += ["--resampleHeightWidth", str(args.height), str(args.width)]
    elif args.width:
        command += ["--resampleWidth", str(args.width)]
    elif args.height:
        command += ["--resampleHeight", str(args.height)]
    elif args.percent:
        old_width, old_height = _sips_dimensions(path)
        width = max(1, round(old_width * args.percent / 100))
        height = max(1, round(old_height * args.percent / 100))
        command += ["--resampleHeightWidth", str(height), str(width)]
    else:
        die("请指定 --crop、--width、--height 或 --percent")

    try:
        run([*command, str(path), "--out", str(target)])
        if temporary:
            os.replace(temporary, path)
            target = path
        return _sips_dimensions(target)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


def cmd_png_compress(a):
    """TinyPNG 式智能压缩：pngquant 量化（保留透明通道，肉眼近似无损）。"""
    files = expand(a.files)
    pngquant = SUPPORT_DIR / ("bin/pngquant.exe" if IS_WIN else "bin/pngquant")
    total_before = total_after = 0
    for f in files:
        if f.suffix.lower() != ".png":
            print(f"跳过（非 PNG）：{f.name}")
            continue
        before = f.stat().st_size
        out = f if a.in_place else available_output(f.with_name(f.stem + "_tiny.png"))
        if pngquant.exists():
            r = subprocess.run([str(pngquant), "--quality", a.quality, "--speed", "1",
                                "--strip", "--skip-if-larger", "--force",
                                "--output", str(out), str(f)],
                               capture_output=True, text=True)
            if r.returncode == 98:  # skip-if-larger: already tiny
                if not a.in_place:
                    shutil.copyfile(f, out)
                print(f"{f.name}: 已足够小，未再压缩")
                total_before += before
                total_after += out.stat().st_size
                continue
            if r.returncode != 0:
                die(f"pngquant 失败：{r.stderr[-300:]}")
        else:
            img = _open_image(f).convert("RGBA")
            from PIL import Image as I
            img = img.quantize(colors=256, method=I.Quantize.FASTOCTREE, dither=I.Dither.FLOYDSTEINBERG)
            img.save(out, optimize=True)
        after = out.stat().st_size
        total_before += before
        total_after += after
        print(f"{f.name}: {before//1024}KB → {after//1024}KB（-{100 - after*100//max(before,1)}%）")
    if total_before:
        ok(f"合计 {total_before//1024}KB → {total_after//1024}KB，节省 {100 - total_after*100//total_before}%（透明通道保留）")


def cmd_jpg_compress(a):
    """JPG 压缩：默认高质量重编码（视觉无损，省30-70%）；
    --strict-lossless 只做元数据段清理（像素零改动，省幅有限）。"""
    files = expand(a.files)
    total_before = total_after = 0

    def strip_metadata(data: bytes) -> bytes:
        # JPEG 段级手术：丢弃 APP1-APP15（EXIF/XMP/缩略图）与注释段，
        # 图像数据字节原样保留 —— 真无损。
        out = bytearray(data[:2])          # SOI
        i = 2
        while i < len(data) - 1:
            if data[i] != 0xFF:
                out.extend(data[i:])       # 进入熵编码数据，余下全保留
                break
            marker = data[i + 1]
            if marker == 0xDA:             # SOS 之后全部保留
                out.extend(data[i:])
                break
            seg_len = int.from_bytes(data[i + 2:i + 4], "big")
            segment = data[i:i + 2 + seg_len]
            # 0xE1-0xEF: APP1-APP15；0xFE: COM 注释。APP0(JFIF) 保留。
            if not (0xE1 <= marker <= 0xEF or marker == 0xFE):
                out.extend(segment)
            i += 2 + seg_len
        return bytes(out)

    for f in files:
        if f.suffix.lower() not in (".jpg", ".jpeg"):
            print(f"跳过（非 JPG）：{f.name}")
            continue
        before = f.stat().st_size
        out = f if a.in_place else available_output(f.with_name(f.stem + "_min" + f.suffix))
        if a.strict_lossless:
            slimmed = strip_metadata(f.read_bytes())
            out.write_bytes(slimmed if len(slimmed) < before else f.read_bytes())
        else:
            img = _open_image(f)
            img.save(out, "JPEG", quality=a.quality, optimize=True, progressive=True)
            if out.stat().st_size >= before:   # 原图已很紧凑就不折腾
                shutil.copyfile(f, out)
        after = out.stat().st_size
        total_before += before
        total_after += after
        print(f"{f.name}: {before//1024}KB → {after//1024}KB（-{100 - after*100//max(before,1)}%）")
    mode = "严格无损（仅清元数据，像素不变）" if a.strict_lossless else f"视觉无损（quality={a.quality} 重编码）"
    ok(f"合计 {total_before//1024}KB → {total_after//1024}KB · {mode}")


def cmd_img_compress(a):
    files = expand(a.files)
    for f in files:
        img = _open_image(f)
        out = available_output(f.with_name(f.stem + "_compressed.jpg"))
        img.convert("RGB").save(out, "JPEG", quality=a.quality, optimize=True)
        print(f"{f.name}: {f.stat().st_size//1024}KB → {out.stat().st_size//1024}KB")
    ok(f"已压缩 {len(files)} 张图片")


def cmd_img_resize(a):
    files = expand(a.files)
    for f in files:
        suffix = "_cropped" if a.crop else "_resized"
        out = f.with_name(f.stem + suffix + f.suffix) if not a.in_place else f
        if not a.in_place:
            out = available_output(out)
        if a.crop:
            try:
                values = [int(v.strip()) for v in a.crop.split(",")]
            except ValueError:
                die("--crop 格式应为 W,H,X,Y，例如 --crop 1179,2553,0,0")
            if len(values) != 4:
                die("--crop 格式应为 W,H,X,Y，例如 --crop 1179,2553,0,0")
            w, h, x, y = values
            if w <= 0 or h <= 0 or x < 0 or y < 0:
                die("裁剪宽高必须大于 0，X/Y 必须是从左上角开始的非负坐标")
            img = _open_image(f)
            temporary = None
            try:
                if x + w > img.width or y + h > img.height:
                    die(f"裁剪区域 {w}x{h}+{x}+{y} 超出原图 {img.width}x{img.height}")
                save_options = {
                    key: img.info[key]
                    for key in ("icc_profile", "exif", "dpi")
                    if img.info.get(key)
                }
                cropped = img.crop((x, y, x + w, y + h))
                try:
                    fd, temp_name = tempfile.mkstemp(
                        prefix=f".{out.stem}-", suffix=out.suffix, dir=out.parent)
                    temporary = Path(temp_name)
                    os.close(fd)
                    cropped.save(temporary, **save_options)
                finally:
                    cropped.close()
                os.chmod(temporary, stat.S_IMODE(f.stat().st_mode))
                os.replace(temporary, out)
                temporary = None
            finally:
                img.close()
                if temporary:
                    temporary.unlink(missing_ok=True)
            print(f"{f.name} → {w}x{h}（左上角 {x},{y}）")
            continue
        if not IS_WIN:
            width, height = _mac_sips_resize(f, a, out)
            print(f"{f.name} → {width}x{height}")
            continue
        img = _open_image(f)
        if a.width or a.height:
            w = a.width or int(img.width * (a.height / img.height))
            h = a.height or int(img.height * (a.width / img.width))
            img = img.resize((w, h))
        elif a.percent:
            img = img.resize((int(img.width * a.percent / 100), int(img.height * a.percent / 100)))
        img.save(out)
        print(f"{f.name} → {img.width}x{img.height}")
    ok(f"已处理 {len(files)} 张")


def cmd_img_convert(a):
    files = expand(a.files)
    if a.output and len(files) != 1:
        die("多张图片不能共用一个 --output；请分别处理")
    fmt = a.to.lower()
    pil_fmt = {"jpg": "JPEG", "jpeg": "JPEG", "png": "PNG", "webp": "WEBP", "heic": "HEIF"}[fmt]
    for f in files:
        out = Path(a.output) if a.output else f.with_suffix("." + fmt)
        if _same_path(out, f) and not a.overwrite_original:
            out = f.with_name(f.stem + "_converted." + fmt)
        out = available_output(out, explicit=bool(a.output))
        if not IS_WIN and fmt in ("jpg", "jpeg", "png", "heic"):
            sips_fmt = "jpeg" if fmt in ("jpg", "jpeg") else fmt
            run(["sips", "-s", "format", sips_fmt, str(f), "--out", str(out)])
            print(f"{f.name} → {out.name}")
            continue
        img = _open_image(f)
        if pil_fmt == "JPEG":
            img = img.convert("RGB")
        img.save(out, pil_fmt)
        print(f"{f.name} → {out.name}")
    ok(f"已转换 {len(files)} 张为 {fmt}")


def cmd_img_watermark(a):
    from PIL import ImageDraw, ImageFont, Image
    files = expand(a.files)
    for f in files:
        img = _open_image(f).convert("RGBA")
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        if a.text:
            font_size = a.size or max(24, img.width // 20)
            font = ImageFont.load_default()
            for candidate in ("/System/Library/Fonts/PingFang.ttc",
                              "/System/Library/Fonts/Hiragino Sans GB.ttc",
                              "/System/Library/Fonts/STHeiti Medium.ttc",
                              "/System/Library/Fonts/Helvetica.ttc"):
                try:
                    font = ImageFont.truetype(candidate, font_size)
                    break
                except Exception:
                    continue
            draw = ImageDraw.Draw(layer)
            bbox = draw.textbbox((0, 0), a.text, font=font)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            pos = {
                "br": (img.width - tw - 20, img.height - th - 20),
                "bl": (20, img.height - th - 20),
                "tr": (img.width - tw - 20, 20),
                "tl": (20, 20),
                "center": ((img.width - tw) // 2, (img.height - th) // 2),
            }[a.position]
            draw.text(pos, a.text, font=font, fill=(255, 255, 255, int(255 * a.opacity)))
        elif a.logo:
            logo = _open_image(a.logo).convert("RGBA")
            scale = img.width // 6 / logo.width
            logo = logo.resize((int(logo.width * scale), int(logo.height * scale)))
            alpha = logo.getchannel("A").point(lambda v: int(v * a.opacity))
            logo.putalpha(alpha)
            layer.paste(logo, (img.width - logo.width - 20, img.height - logo.height - 20), logo)
        out = available_output(f.with_name(f.stem + "_wm" + (".png" if f.suffix.lower() == ".png" else ".jpg")))
        result = Image.alpha_composite(img, layer)
        (result if out.suffix == ".png" else result.convert("RGB")).save(out)
    ok(f"已为 {len(files)} 张图片加水印")


def cmd_img_remove_bg(a):
    files = expand(a.files)
    if IS_WIN:
        try:
            from rembg import remove
        except ImportError:
            die("抠图组件未安装。请先询问用户：需一次性下载抠图组件（约 200MB，含 AI 模型）。"
                "用户同意后调用技能 install-component rembg；拒绝则说明无法抠图。")
        os.environ.setdefault("U2NET_HOME", str(SUPPORT_DIR / "models"))
        for f in files:
            out = available_output(f.with_name(f.stem + "_nobg.png"))
            out.write_bytes(remove(f.read_bytes()))
            print(f"{f.name} → {out.name}")
        ok(f"已抠图 {len(files)} 张（u2net 模型）")
        return
    for f in files:
        out = available_output(f.with_name(f.stem + "_nobg.png"))
        run([*helper("nobg"), str(f), str(out)])
        print(f"{f.name} → {out.name}")
    ok(f"已抠图 {len(files)} 张（Apple Vision 主体识别）")


def cmd_img_split(a):
    files = expand(a.files)
    n = a.parts
    for f in files:
        img = _open_image(f)
        for i in range(n):
            if a.direction == "vertical":
                box = (0, img.height * i // n, img.width, img.height * (i + 1) // n)
            else:
                box = (img.width * i // n, 0, img.width * (i + 1) // n, img.height)
            out = available_output(f.with_name(f"{f.stem}_slice{i+1:02d}{f.suffix}"))
            img.crop(box).save(out)
        print(f"{f.name} → {n} 段")
    ok(f"已把 {len(files)} 张图各分割为 {n} 段")


def cmd_img_stitch(a):
    from PIL import Image
    files = expand(a.files)
    imgs = [_open_image(f) for f in files]
    if a.direction == "vertical":
        width = max(i.width for i in imgs)
        imgs = [i.resize((width, int(i.height * width / i.width))) for i in imgs]
        canvas = Image.new("RGB", (width, sum(i.height for i in imgs)), "white")
        y = 0
        for i in imgs:
            canvas.paste(i, (0, y))
            y += i.height
    else:
        height = max(i.height for i in imgs)
        imgs = [i.resize((int(i.width * height / i.height), height)) for i in imgs]
        canvas = Image.new("RGB", (sum(i.width for i in imgs), height), "white")
        x = 0
        for i in imgs:
            canvas.paste(i, (x, 0))
            x += i.width
    out = available_output(Path(a.output), explicit=True)
    canvas.save(out)
    ok(f"已拼接 {len(files)} 张 → {out}")


def cmd_img_rotate(a):
    files = expand(a.files)
    for f in files:
        img = _open_image(f)
        if a.angle:
            img = img.rotate(-a.angle, expand=True)
        if a.flip == "h":
            from PIL import Image as I
            img = img.transpose(I.FLIP_LEFT_RIGHT)
        elif a.flip == "v":
            from PIL import Image as I
            img = img.transpose(I.FLIP_TOP_BOTTOM)
        target = f if a.in_place else available_output(f.with_name(f.stem + "_rotated" + f.suffix))
        img.save(target)
    ok(f"已处理 {len(files)} 张")


def cmd_img_ocr(a):
    files = expand(a.files)
    for f in files:
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_suffix(".txt")
        out = available_output(out, explicit=bool(a.output))
        if IS_WIN:
            out.write_text(_win_ocr_text(f), encoding="utf-8")
        else:
            run([*helper("ocr"), str(f), str(out)])
        print(f"{f.name} → {out.name}（{out.stat().st_size} 字节）")
    ok(f"已 OCR {len(files)} 张图片")


def cmd_pdf_ocr(a):
    files = expand(a.files)
    if a.output and len(files) != 1:
        die("多份 PDF 不能共用一个 --output；请逐份处理")
    for f in files:
        if f.suffix.lower() != ".pdf":
            die(f"pdf-ocr 只接受 PDF：{f.name}")
        text = _pdf_ocr_text(f, a.dpi, a.password, a.pages)
        if a.output:
            out = available_output(Path(a.output), explicit=True)
            out.write_text(text, encoding="utf-8")
            print(f"{f.name} → {out.name}（逐页 OCR，{len(text)} 字符）")
        else:
            print(f"--- {f.name} OCR 结果 ---\n{text}")
    ok(f"已 OCR {len(files)} 份 PDF")


def cmd_img_to_ico(a):
    files = expand(a.files)
    for f in files:
        img = _open_image(f).convert("RGBA")
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_suffix(".ico")
        out = available_output(out, explicit=bool(a.output))
        img.save(out, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
        print(f"{f.name} → {out.name}")
    ok(f"已生成 {len(files)} 个 ICO（含 16–256px 多尺寸）")


# ------------------------------------------------------------- audio/video

def cmd_av_extract_audio(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    codec = {"mp3": ["-c:a", "libmp3lame", "-q:a", "2"],
             "m4a": ["-c:a", "aac", "-b:a", "192k"],
             "wav": ["-c:a", "pcm_s16le"]}[a.to]
    for f in files:
        out = available_output(f.with_suffix("." + a.to))
        run([ff, "-y", "-i", str(f), "-vn", *codec, str(out)])
        print(f"{f.name} → {out.name}")
    ok(f"已提取 {len(files)} 个音轨")


def cmd_av_trim(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    for f in files:
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_name(f.stem + "_clip" + f.suffix)
        out = available_output(out, explicit=bool(a.output))
        cmd = [ff, "-y", "-ss", a.start]
        if a.end:
            cmd += ["-to", a.end]
        cmd += ["-i", str(f)]
        cmd += (["-c", "copy"] if a.fast else [])
        cmd += [str(out)]
        run(cmd)
        print(f"{f.name} → {out.name}")
    ok(f"已对 {len(files)} 个文件截取 {a.start}–{a.end or '结尾'}")


def cmd_av_convert(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    for f in files:
        out = available_output(f.with_suffix("." + a.to))
        run([ff, "-y", "-i", str(f), str(out)])
        print(f"{f.name} → {out.name}")
    ok(f"已转换 {len(files)} 个视频为 {a.to}")


def cmd_av_compress(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    for f in files:
        out = available_output(f.with_name(f.stem + "_small.mp4"))
        cmd = [ff, "-y", "-i", str(f), "-c:v", "libx264", "-crf", str(a.crf), "-preset", "medium", "-c:a", "aac", "-b:a", "128k"]
        if a.width:
            cmd += ["-vf", f"scale={a.width}:-2"]
        run(cmd + [str(out)])
        print(f"{f.name}: {f.stat().st_size//1_000_000}MB → {out.stat().st_size//1_000_000}MB")
    ok(f"已压缩 {len(files)} 个视频（crf={a.crf}）")


def _probe_media(path):
    """ffprobe JSON 探测：返回 (时长, 视频流, 音频流)；ffprobe 缺失时返回 None。"""
    if not Path(FFPROBE).exists():
        return None
    r = subprocess.run([FFPROBE, "-v", "error", "-print_format", "json",
                        "-show_format", "-show_streams", str(path)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die(f"无法读取媒体信息：{Path(path).name}\n{r.stderr[-400:]}")
    data = json.loads(r.stdout or "{}")
    try:
        duration = float(data.get("format", {}).get("duration"))
    except (TypeError, ValueError):
        duration = None
    streams = data.get("streams", [])
    videos = [s for s in streams if s.get("codec_type") == "video"
              and not s.get("disposition", {}).get("attached_pic")]
    audios = [s for s in streams if s.get("codec_type") == "audio"]
    return duration, videos, audios


def _merge_signature(probe):
    """copy 拼接是否安全，取决于各段编码/尺寸/帧率/时基/采样率完全一致。"""
    _, videos, audios = probe
    v = videos[0] if videos else None
    a = audios[0] if audios else None
    return (
        (v.get("codec_name"), v.get("width"), v.get("height"), v.get("pix_fmt"),
         v.get("avg_frame_rate"), v.get("time_base")) if v else None,
        (a.get("codec_name"), a.get("sample_rate"), a.get("channels")) if a else None,
    )


def _fps_of(stream):
    rate = stream.get("avg_frame_rate") or "0/1"
    try:
        num, _, den = rate.partition("/")
        value = float(num) / float(den or 1)
    except (ValueError, ZeroDivisionError):
        return None, rate
    return (value, rate) if value > 0 else (None, rate)


def _merge_duration_ok(out, expected):
    """合并产物时长必须≈输入总时长；无法探测（无 ffprobe/无总时长）时不拦截。"""
    if expected is None:
        return True
    probe = _probe_media(out)
    if probe is None or probe[0] is None:
        return True
    return abs(probe[0] - expected) <= max(0.5, expected * 0.02)


def _av_merge_copy(ff, files, out):
    lst = Path(tempfile.gettempdir()) / f"folderis-concat-{uuid.uuid4().hex}.txt"
    lst.write_text("\n".join(f"file '{Path(f).resolve()}'" for f in files), encoding="utf-8")
    try:
        run([ff, "-y", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(out)])
    finally:
        lst.unlink(missing_ok=True)


def _av_merge_reencode(ff, files, probes, out):
    """concat 滤镜重编码：统一分辨率/帧率/时基后拼接，正确处理混合参数输入。"""
    n = len(files)
    has_video = all(p[1] for p in probes)
    use_audio = all(p[2] for p in probes)
    if not has_video and not use_audio:
        die("这些片段既无统一的视频流也无统一的音频流，无法拼接")
    cmd = [ff, "-y"]
    for f in files:
        cmd += ["-i", str(f)]
    parts, chain = [], ""
    if has_video:
        v0 = probes[0][1][0]
        w, h = v0.get("width"), v0.get("height")
        fps_values = [_fps_of(p[1][0]) for p in probes]
        fps = max(fps_values, key=lambda item: item[0] or 0)[1] if any(v for v, _ in fps_values) else "30"
        for i in range(n):
            parts.append(
                f"[{i}:v]scale={w}:{h}:force_original_aspect_ratio=decrease,"
                f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,fps={fps},format=yuv420p,setsar=1,"
                f"setpts=PTS-STARTPTS[v{i}]")
    if use_audio:
        for i in range(n):
            parts.append(f"[{i}:a]aformat=sample_fmts=fltp:channel_layouts=stereo,"
                         f"aresample=48000,asetpts=PTS-STARTPTS[a{i}]")
    for i in range(n):
        chain += (f"[v{i}]" if has_video else "") + (f"[a{i}]" if use_audio else "")
    labels = ("[v]" if has_video else "") + ("[a]" if use_audio else "")
    parts.append(f"{chain}concat=n={n}:v={int(has_video)}:a={int(use_audio)}{labels}")
    cmd += ["-filter_complex", ";".join(parts)]
    if has_video:
        cmd += ["-map", "[v]", "-c:v", "libx264", "-crf", "18", "-preset", "medium"]
    if use_audio:
        cmd += ["-map", "[a]"]
        if has_video:
            cmd += ["-c:a", "aac", "-b:a", "192k"]
    run(cmd + [str(out)])


def cmd_av_merge(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    out = available_output(Path(a.output), explicit=True)
    probes = [_probe_media(f) for f in files]
    if any(p is None for p in probes):
        # 无 ffprobe：退回 copy 拼接，失败时重编码（无法校验时长）
        try:
            _av_merge_copy(ff, files, out)
        except SystemExit:
            lst = Path(tempfile.gettempdir()) / f"folderis-concat-{uuid.uuid4().hex}.txt"
            lst.write_text("\n".join(f"file '{Path(f).resolve()}'" for f in files), encoding="utf-8")
            try:
                run([ff, "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                     "-c:v", "libx264", "-c:a", "aac", str(out)])
            finally:
                lst.unlink(missing_ok=True)
        ok(f"已合并 {len(files)} 段 → {out}")
        return

    durations = [p[0] for p in probes]
    expected = sum(durations) if all(d is not None for d in durations) else None
    uniform = len({_merge_signature(p) for p in probes}) == 1
    merged = False
    if uniform:
        try:
            _av_merge_copy(ff, files, out)
            merged = _merge_duration_ok(out, expected)
        except SystemExit:
            merged = False
        if not merged:
            out.unlink(missing_ok=True)
    if not merged:
        # 编码/帧率/时基不一致（或 copy 拼接时长不对）：重编码拼接
        _av_merge_reencode(ff, files, probes, out)
        if not _merge_duration_ok(out, expected):
            actual = _probe_media(out)[0]
            out.unlink(missing_ok=True)
            die(f"合并结果时长 {actual:.3f}s 与输入总时长 {expected:.3f}s 不符，已中止并删除产物")
    if all(p[1] for p in probes) and not all(p[2] for p in probes) and any(p[2] for p in probes):
        print("提示：部分片段没有音轨，合并结果不含音频")
    ok(f"已合并 {len(files)} 段 → {out}")


def cmd_audio_trim(a):
    cmd_av_trim(a)


def cmd_audio_concat(a):
    cmd_av_merge(a)


def cmd_audio_convert(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    for f in files:
        out = available_output(f.with_suffix("." + a.to))
        run([ff, "-y", "-i", str(f), str(out)])
        print(f"{f.name} → {out.name}")
    ok(f"已转换 {len(files)} 个音频为 {a.to}")


def cmd_audio_denoise(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    for f in files:
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_name(f.stem + "_denoised" + f.suffix)
        out = available_output(out, explicit=bool(a.output))
        run([ff, "-y", "-i", str(f), "-af", f"afftdn=nr={a.strength}", str(out)])
        print(f"{f.name} → {out.name}")
    ok(f"已降噪 {len(files)} 个文件（如需人声/伴奏分离需另装 demucs，向用户说明）")


def cmd_av_gif(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    filt = f"fps={a.fps},scale={a.width}:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
    for f in files:
        if a.output and len(files) != 1:
            die("多个视频不能共用一个 --output；请分别处理")
        if a.output:
            out = Path(a.output)
        else:
            start = float(a.start or 0)
            duration = float(a.duration) if a.duration else None
            parts = []
            if duration is not None:
                duration_label = str(int(duration)) if duration.is_integer() else str(duration).rstrip("0").rstrip(".")
                parts.append(("first" if start == 0 else "duration") + duration_label + "s")
            if a.width:
                parts.append(f"{a.width}px")
            suffix = "_" + "_".join(parts) if parts else ""
            out = f.with_name(f.stem + suffix + ".gif")
        out = available_output(out, explicit=bool(a.output))
        task_id = re.sub(r"[^a-zA-Z0-9-]", "", os.environ.get("FOLDERIS_TASK_ID", "")) or uuid.uuid4().hex
        partial = Path(tempfile.gettempdir()) / f"folderis-{task_id}-{out.name}"
        cmd = [ff, "-y"]
        if a.start:
            cmd += ["-ss", a.start]
        if a.duration:
            cmd += ["-t", str(a.duration)]
        try:
            run(cmd + ["-i", str(f), "-vf", filt, str(partial)])
            shutil.move(str(partial), str(out))
        finally:
            partial.unlink(missing_ok=True)
        print(f"{f.name} → {out.name}（{out.stat().st_size//1024}KB）")
    ok(f"已生成 {len(files)} 个 GIF")


def cmd_av_subtitles(a):
    ff = ffmpeg_or_die()
    files = expand(a.files)
    done = 0
    for f in files:
        # 单文件可显式指定字幕；批量时按同名 .srt/.ass 自动配对。
        if a.subtitles and len(files) == 1:
            sub = Path(a.subtitles)
        else:
            sub = next((f.with_suffix(ext) for ext in (".srt", ".ass", ".vtt")
                        if f.with_suffix(ext).exists()), None)
            if sub is None:
                print(f"跳过（找不到同名字幕）：{f.name}")
                continue
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_name(f.stem + "_subbed.mp4")
        out = available_output(out, explicit=bool(a.output))
        if a.soft:
            run([ff, "-y", "-i", str(f), "-i", str(sub), "-c", "copy", "-c:s", "mov_text", str(out)])
        else:
            sub_escaped = str(sub).replace("'", r"\'").replace(":", r"\:")
            run([ff, "-y", "-i", str(f), "-vf", f"subtitles='{sub_escaped}'", "-c:a", "copy", str(out)])
        print(f"{f.name} + {sub.name} → {out.name}")
        done += 1
    ok(f"已处理 {done} 个视频的字幕（{'软封装' if a.soft else '烧录'}）")


def _transcriber_binary() -> Path:
    """Speech 框架要求进程有正式身份：首次使用时把 transcribe.swift
    编译成带内嵌 Info.plist 的二进制。"""
    binary = SUPPORT_DIR / "bin/transcribe"
    src = SKILLS_DIR / "transcribe.swift"
    plist = SKILLS_DIR / "transcribe-Info.plist"
    if binary.exists() and binary.stat().st_mtime >= src.stat().st_mtime:
        return binary
    binary.parent.mkdir(parents=True, exist_ok=True)
    print("首次使用：正在编译转写组件…")
    run(["swiftc", str(src), "-o", str(binary),
         "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
         "-Xlinker", "__info_plist", "-Xlinker", str(plist)])
    run(["codesign", "--force", "-s", "-", str(binary)])
    return binary


SENSEVOICE_COMPONENT_VERSION = "sensevoice-small-q8-runtime-0.1.4-v1"
SENSEVOICE_RUNTIME_URL = (
    "https://github.com/FunAudioLLM/SenseVoice/releases/download/"
    "runtime-llamacpp-v0.1.4/funasr-llamacpp-windows-x64.zip"
)
SENSEVOICE_RUNTIME_SIZE = 4_663_344
SENSEVOICE_RUNTIME_SHA256 = "ae0bca37e046dcd0e59ac3399f2ed246abf0696a84dc1f4322adc894bb5339e7"
SENSEVOICE_EXE_SIZE = 1_476_608
SENSEVOICE_EXE_SHA256 = "cfe32b66d07549a22962609748ad73bcf32a774ddf2725887f424c1307262fb6"
SENSEVOICE_MODEL_URL = (
    "https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF/resolve/"
    "90c1c61912018b70ada0fcc024ea24aca62f2e63/sensevoice-small-q8.gguf?download=true"
)
SENSEVOICE_MODEL_SIZE = 254_208_320
SENSEVOICE_MODEL_SHA256 = "4ae45c94422de949b387e2e0fb10d7e14e4c42c69db30c3444ecc7d4b844b7c5"
SENSEVOICE_VAD_URL = (
    "https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/resolve/"
    "6840bae4c5c92ee8c04faaf4db23dd0105098d7f/fsmn-vad.gguf?download=true"
)
SENSEVOICE_VAD_SIZE = 1_720_512
SENSEVOICE_VAD_SHA256 = "1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479"
_SENSEVOICE_TAG_BLOCK = re.compile(r"(?:<\|[^<>]+\|>)+")


def _sensevoice_paths():
    root = SUPPORT_DIR / "components" / "sensevoice-small"
    return (
        root,
        root / "bin" / "llama-funasr-sensevoice.exe",
        root / "model" / "sensevoice-small-q8.gguf",
        root / "model" / "fsmn-vad.gguf",
    )


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().lower()


def _verified_file(path, expected_size, expected_sha256):
    path = Path(path)
    return (
        path.is_file()
        and path.stat().st_size == expected_size
        and _sha256_file(path) == expected_sha256
    )


def _download_verified(url, destination, expected_size, expected_sha256, label):
    """Download an immutable component artifact with resume and SHA-256 verification."""
    import urllib.request

    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if _verified_file(destination, expected_size, expected_sha256):
        return destination

    partial = destination.with_name(destination.name + ".part")
    if partial.exists() and partial.stat().st_size > expected_size:
        partial.unlink()
    if partial.exists() and partial.stat().st_size == expected_size:
        print(f"校验已下载的 {label}…")
        if _sha256_file(partial) == expected_sha256:
            os.replace(partial, destination)
            return destination
        partial.unlink()
    offset = partial.stat().st_size if partial.exists() else 0
    headers = {"User-Agent": "Folderis/1.0"}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    request = urllib.request.Request(url, headers=headers)
    print(f"下载 {label}（约 {expected_size / 1_000_000:.0f}MB）…")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            status = getattr(response, "status", None) or response.getcode()
            append = offset > 0 and status == 206
            mode = "ab" if append else "wb"
            downloaded = offset if append else 0
            next_report = ((downloaded // (25 * 1024 * 1024)) + 1) * (25 * 1024 * 1024)
            with partial.open(mode) as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    downloaded += len(chunk)
                    if downloaded >= next_report:
                        print(f"  {label}：{min(100, downloaded * 100 // expected_size)}%")
                        next_report += 25 * 1024 * 1024
    except Exception as exc:
        raise RuntimeError(f"{label} 下载中断：{exc}。已下载部分会保留，下次可继续。") from exc

    if partial.stat().st_size != expected_size:
        raise RuntimeError(
            f"{label} 下载不完整（{partial.stat().st_size} / {expected_size} 字节），请重试。")
    print(f"校验 {label} 完整性…")
    if _sha256_file(partial) != expected_sha256:
        partial.unlink(missing_ok=True)
        raise RuntimeError(f"{label} SHA-256 校验失败，已删除损坏文件，请重试。")
    os.replace(partial, destination)
    return destination


def _sensevoice_component_ready():
    root, executable, model, vad = _sensevoice_paths()
    marker = root / "VERSION"
    return (
        marker.is_file()
        and marker.read_text(encoding="utf-8").strip() == SENSEVOICE_COMPONENT_VERSION
        and executable.is_file()
        and executable.stat().st_size == SENSEVOICE_EXE_SIZE
        and model.is_file()
        and model.stat().st_size == SENSEVOICE_MODEL_SIZE
        and vad.is_file()
        and vad.stat().st_size == SENSEVOICE_VAD_SIZE
    )


def _parse_sensevoice_output(stdout):
    """Turn per-VAD-segment tagged output into readable text and language labels."""
    tag_blocks = _SENSEVOICE_TAG_BLOCK.findall(stdout)
    parts = [part.strip() for part in _SENSEVOICE_TAG_BLOCK.split(stdout) if part.strip()]
    text = "\n".join(parts) if tag_blocks else stdout.strip()
    language_names = {
        "zh": "中文", "en": "英语", "yue": "粤语", "ja": "日语", "ko": "韩语"
    }
    languages = []
    for block in tag_blocks:
        match = re.search(r"<\|([^|>]+)\|>", block)
        language = language_names.get(match.group(1).lower()) if match else None
        if language and language not in languages:
            languages.append(language)
    return text, languages


def _run_sensevoice(audio):
    _, executable, model, vad = _sensevoice_paths()
    if not _sensevoice_component_ready():
        die("SenseVoiceSmall 转写组件未安装。请先询问用户：Windows 本地转写需一次性下载约 260MB，"
            "完全离线并支持中文、英语、粤语、日语和韩语。用户同意后调用技能 "
            "install-component sensevoice-small；拒绝则说明无法在本机转写。")
    command = [
        str(executable), "-m", str(model), "-a", str(Path(audio).resolve()),
        "--vad", str(vad), "--vad-maxseg", "30000", "--keep-tags",
    ]
    result = subprocess.run(command, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()[-600:]
        die(f"{Path(audio).name} 转写失败：{detail or 'SenseVoiceSmall 异常退出'}")
    return _parse_sensevoice_output(result.stdout)


def cmd_audio_transcribe(a):
    """长音频离线转文字：Windows 用 SenseVoiceSmall，macOS 用 Apple Speech。"""
    if IS_WIN:
        files = expand(a.files)
        for f in files:
            text, languages = _run_sensevoice(f)
            if not text:
                die(f"{f.name} 转写结果为空（可能是纯音乐或静音）")
            desired = Path(a.output) if (a.output and len(files) == 1) else f.with_suffix(".txt")
            out = available_output(desired, explicit=bool(a.output))
            out.write_text(text, encoding="utf-8")
            language = "、".join(languages) or "自动检测"
            print(f"{f.name} → {out.name}（{len(text)} 字符，识别语言 {language}）")
        ok(f"已用 SenseVoiceSmall Q8 离线转写 {len(files)} 个音频")
        return
    ff = ffmpeg_or_die()
    transcriber = _transcriber_binary()
    files = expand(a.files)
    import tempfile

    def transcribe_pieces(pieces, locale):
        texts = []
        for i, piece in enumerate(pieces):
            r = subprocess.run([str(transcriber), str(piece), locale],
                               capture_output=True, text=True)
            if r.returncode == 2:
                die("需要语音识别授权：请到 系统设置→隐私与安全性→语音识别 中允许，然后重试")
            if r.returncode in (134, -6):
                die("语音识别被系统隐私机制拦截：请确认是通过面板发起的任务，"
                    "并在弹出的授权对话框中点允许（或到 系统设置→隐私与安全性→语音识别 手动开启）")
            if r.returncode != 0:
                die(f"第 {i+1} 段转写失败：{r.stderr[-200:]}")
            texts.append(r.stdout.strip())
            print(f"[{i+1}/{len(pieces)}·{locale}] 已转写")
        return [t for t in texts if t]

    for f in files:
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_suffix(".txt")
        out = available_output(out, explicit=bool(a.output))
        with tempfile.TemporaryDirectory() as td:
            seg = Path(td) / "seg%04d.wav"
            run([ff, "-y", "-i", str(f), "-ac", "1", "-ar", "16000",
                 "-f", "segment", "-segment_time", "55", str(seg)])
            pieces = sorted(Path(td).glob("seg*.wav"))
            if not pieces:
                die("音频切分失败")

            locale = a.locale
            texts = transcribe_pieces(pieces, locale)
            # 空结果最常见原因是语言不匹配：自动换一种语言重试一次。
            if not texts:
                fallback = "en-US" if locale.startswith("zh") else "zh-CN"
                print(f"用 {locale} 未识别到内容，自动改用 {fallback} 重试…")
                texts = transcribe_pieces(pieces, fallback)
                locale = fallback
            if not texts:
                die(f"两种语言（{a.locale}/{locale}）都未识别到语音内容："
                    "该音频可能没有人声（如纯音乐/环境音），或语言不在支持范围。"
                    "可用 --locale 指定其他语言（如 ja-JP）重试。")

            out.write_text("\n".join(texts), encoding="utf-8")
        print(f"{f.name} → {out.name}（{out.stat().st_size} 字节，locale={locale}）")
    ok(f"已转写 {len(files)} 个音频（离线识别）")


def cmd_content_search(a):
    """跨格式全文搜索：txt/md/pdf/xlsx/docx/图片(OCR) 统一提取文本后查找。"""
    query = a.query.lower()
    files = expand(a.files)
    hits = 0

    def report(f, where, line):
        nonlocal hits
        hits += 1
        snippet = line.strip()
        if len(snippet) > 160:
            snippet = snippet[:160] + "…"
        print(f"{f.name} · {where}: {snippet}")

    for f in files:
        ext = f.suffix.lower()
        try:
            if ext in (".txt", ".md", ".csv", ".log", ".json"):
                for no, line in enumerate(f.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
                    if query in line.lower():
                        report(f, f"第{no}行", line)
            elif ext == ".pdf":
                from pypdf import PdfReader
                for pno, page in enumerate(PdfReader(str(f)).pages, 1):
                    for line in (page.extract_text() or "").splitlines():
                        if query in line.lower():
                            report(f, f"第{pno}页", line)
            elif ext in (".xlsx", ".xlsm"):
                import openpyxl
                wb = openpyxl.load_workbook(str(f), read_only=True)
                for ws in wb.worksheets:
                    for rno, row in enumerate(ws.iter_rows(values_only=True), 1):
                        joined = " | ".join(str(c) for c in row if c is not None)
                        if query in joined.lower():
                            report(f, f"{ws.title}!第{rno}行", joined)
            elif ext == ".docx":
                import zipfile
                with zipfile.ZipFile(str(f)) as z:
                    xml = z.read("word/document.xml").decode("utf-8", "ignore")
                text = re.sub(r"<w:p[ >].*?</w:p>", lambda m: re.sub(r"<[^>]+>", "", m.group(0)) + "\n", xml, flags=re.S)
                text = re.sub(r"<[^>]+>", "", text)
                for no, line in enumerate(text.splitlines(), 1):
                    if query in line.lower():
                        report(f, f"段落{no}", line)
            elif ext in (".png", ".jpg", ".jpeg", ".heic", ".webp", ".tiff", ".bmp"):
                if IS_WIN:
                    _ocr_out = _win_ocr_text(f)
                else:
                    _ocr_out = subprocess.run([*helper("ocr"), str(f)],
                                              capture_output=True, text=True).stdout
                for line in _ocr_out.splitlines():
                    if query in line.lower():
                        report(f, "图片OCR", line)
            else:
                print(f"跳过（不支持的类型）：{f.name}")
        except Exception as e:
            print(f"跳过（读取失败 {e.__class__.__name__}）：{f.name}")
    ok(f"共找到 {hits} 处包含「{a.query}」的内容" if hits else f"没有找到包含「{a.query}」的内容")


def cmd_docx_fill(a):
    """Word 模板批量填充：模板中 {{列名}} 占位符 + Excel/CSV 数据表 → 每行生成一份。"""
    from docx import Document
    template = Path(a.template)
    data_file = Path(a.data)

    # 读数据：首行为表头
    rows = []
    if data_file.suffix.lower() == ".csv":
        import csv as _csv
        with open(data_file, newline="", encoding="utf-8-sig") as fh:
            rows = list(_csv.reader(fh))
    else:
        import openpyxl
        ws = openpyxl.load_workbook(str(data_file), read_only=True).active
        rows = [[("" if c is None else str(c)) for c in r] for r in ws.iter_rows(values_only=True)]
    if len(rows) < 2:
        die("数据表需要表头 + 至少一行数据")
    headers = [str(h).strip() for h in rows[0]]

    def fill_paragraph(par, mapping):
        # 占位符可能被 Word 拆进多个 run：整段重组再替换。
        full = "".join(r.text for r in par.runs)
        if "{{" not in full:
            return
        new = full
        for key, val in mapping.items():
            new = new.replace("{{" + key + "}}", val)
        if new != full and par.runs:
            par.runs[0].text = new
            for r in par.runs[1:]:
                r.text = ""

    out_dir = available_output(Path(a.output_dir or (template.parent / (template.stem + "_filled"))), explicit=bool(a.output_dir))
    out_dir.mkdir(parents=True)
    count = 0
    for row in rows[1:]:
        mapping = {headers[i]: (row[i] if i < len(row) else "") for i in range(len(headers))}
        doc = Document(str(template))
        for par in doc.paragraphs:
            fill_paragraph(par, mapping)
        for table in doc.tables:
            for trow in table.rows:
                for cell in trow.cells:
                    for par in cell.paragraphs:
                        fill_paragraph(par, mapping)
        name_val = mapping.get(a.name_column or headers[0], f"row{count+1}") or f"row{count+1}"
        safe = re.sub(r'[/\\:*?"<>|]', "_", name_val)
        out = available_output(out_dir / f"{template.stem}_{safe}.docx")
        doc.save(str(out))
        count += 1
    ok(f"已按模板生成 {count} 份文档 → {out_dir.name}/")


def cmd_table_convert(a):
    """Excel ↔ CSV 互转：xlsx→每个工作表一个 csv；csv→xlsx。"""
    import openpyxl
    files = expand(a.files)
    if a.output and len(files) != 1:
        die("多个表格不能共用一个 --output；请分别处理")
    made = []
    for f in files:
        if f.suffix.lower() in (".xlsx", ".xlsm"):
            wb = openpyxl.load_workbook(str(f), read_only=True)
            if a.output and len(wb.worksheets) != 1:
                die("多工作表文件不能指定单个 CSV 输出名；请分别导出工作表")
            import csv as _csv
            for ws in wb.worksheets:
                suffix = f"_{ws.title}" if len(wb.worksheets) > 1 else ""
                out = Path(a.output) if a.output else f.with_name(f"{f.stem}{suffix}.csv")
                out = available_output(out, explicit=bool(a.output))
                with open(out, "w", newline="", encoding="utf-8-sig") as fh:
                    writer = _csv.writer(fh)
                    for row in ws.iter_rows(values_only=True):
                        writer.writerow(["" if c is None else c for c in row])
                made.append(out.name)
        elif f.suffix.lower() == ".xls":
            try:
                import xlrd
            except ImportError:
                die("XLS 转换组件缺失（xlrd）。请更新 Folderis 技能运行时")
            book = xlrd.open_workbook(str(f))
            if a.output and book.nsheets != 1:
                die("多工作表文件不能指定单个 CSV 输出名；请分别导出工作表")
            import csv as _csv
            for sheet in book.sheets():
                suffix = f"_{sheet.name}" if book.nsheets > 1 else ""
                out = Path(a.output) if a.output else f.with_name(f"{f.stem}{suffix}.csv")
                out = available_output(out, explicit=bool(a.output))
                with open(out, "w", newline="", encoding="utf-8-sig") as fh:
                    writer = _csv.writer(fh)
                    for ri in range(sheet.nrows):
                        row = []
                        for ci in range(sheet.ncols):
                            cell = sheet.cell(ri, ci)
                            value = cell.value
                            if cell.ctype == xlrd.XL_CELL_DATE:
                                value = xlrd.xldate_as_datetime(value, book.datemode).isoformat(sep=" ")
                            elif isinstance(value, float) and value.is_integer():
                                value = int(value)
                            row.append(value)
                        writer.writerow(row)
                made.append(out.name)
        elif f.suffix.lower() == ".csv":
            import csv as _csv
            wb = openpyxl.Workbook()
            ws = wb.active
            with open(f, newline="", encoding="utf-8-sig") as fh:
                for row in _csv.reader(fh):
                    ws.append(row)
            out = Path(a.output) if a.output else f.with_suffix(".xlsx")
            out = available_output(out, explicit=bool(a.output))
            wb.save(str(out))
            made.append(out.name)
        else:
            print(f"跳过（非表格）：{f.name}")
    ok(f"已转换：{', '.join(made)}" if made else "没有可转换的文件")


def cmd_av_frames(a):
    """视频截帧：每 N 秒一张（或指定时间点列表），输出 jpg。"""
    ff = ffmpeg_or_die()
    files = expand(a.files)
    for f in files:
        stem = f.stem
        if a.at:
            for i, ts in enumerate(a.at.split(","), 1):
                out = available_output(f.with_name(f"{stem}_frame{i:03d}.jpg"))
                run([ff, "-y", "-ss", ts.strip(), "-i", str(f), "-frames:v", "1", "-q:v", "2", str(out)])
            print(f"{f.name} → {len(a.at.split(','))} 帧")
        else:
            with tempfile.TemporaryDirectory(prefix="folderis-frames-") as temp:
                pattern = Path(temp) / f"{stem}_frame%03d.jpg"
                run([ff, "-y", "-i", str(f), "-vf", f"fps=1/{a.every}", "-q:v", "2", str(pattern)])
                generated = sorted(Path(temp).glob(f"{stem}_frame*.jpg"))
                for frame in generated:
                    shutil.move(str(frame), str(available_output(f.parent / frame.name)))
                n = len(generated)
            print(f"{f.name} → {n} 帧（每 {a.every} 秒）")
    ok(f"已完成 {len(files)} 个视频的截帧")


def cmd_doc_diff(a):
    """文档对比：提取两份文档（txt/docx/pdf）文本后做统一 diff。"""
    import difflib

    def text_of(p: Path) -> list:
        ext = p.suffix.lower()
        if ext == ".pdf":
            from pypdf import PdfReader
            return "\n".join((pg.extract_text() or "") for pg in PdfReader(str(p)).pages).splitlines()
        if ext == ".docx":
            from docx import Document
            return [par.text for par in Document(str(p)).paragraphs]
        return p.read_text(encoding="utf-8", errors="ignore").splitlines()

    a_path, b_path = Path(a.file_a), Path(a.file_b)
    left, right = text_of(a_path), text_of(b_path)
    diff = list(difflib.unified_diff(left, right, fromfile=a_path.name, tofile=b_path.name, lineterm=""))
    if not diff:
        ok("两份文档文本内容完全一致")
        return
    added = sum(1 for l in diff if l.startswith("+") and not l.startswith("+++"))
    removed = sum(1 for l in diff if l.startswith("-") and not l.startswith("---"))
    body = "\n".join(diff)
    if len(body) > 8000:
        body = body[:8000] + f"\n…（diff 过长已截断，完整版存至 {a_path.stem}_vs_{b_path.stem}.diff）"
        out = available_output(a_path.parent / f"{a_path.stem}_vs_{b_path.stem}.diff")
        out.write_text("\n".join(diff), encoding="utf-8")
    print(body)
    ok(f"差异：新增 {added} 行，删除 {removed} 行")


# ------------------------------------------------------------- components

def cmd_install_component(a):
    """按需安装可选组件（仅在用户明确同意后调用）。全部免 Homebrew、免管理员密码。"""
    import urllib.request
    bin_dir = SUPPORT_DIR / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    def fetch(url, dest):
        print(f"下载 {url} …")
        urllib.request.urlretrieve(url, dest)

    if a.component == "ffmpeg":
        import tempfile
        if IS_WIN:
            # gyan.dev release-essentials：含 ffmpeg.exe/ffprobe.exe
            with tempfile.TemporaryDirectory() as td:
                z = Path(td) / "ff.zip"
                fetch("https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip", z)
                with zipfile.ZipFile(z) as zf:
                    for m in zf.namelist():
                        base = Path(m).name
                        if base in ("ffmpeg.exe", "ffprobe.exe"):
                            (bin_dir / base).write_bytes(zf.read(m))
        else:
            with tempfile.TemporaryDirectory() as td:
                for name in ("ffmpeg", "ffprobe"):
                    z = Path(td) / f"{name}.zip"
                    url = ("https://evermeet.cx/ffmpeg/getrelease/zip" if name == "ffmpeg"
                           else "https://evermeet.cx/ffmpeg/get/ffprobe/zip")
                    fetch(url, z)
                    run(["unzip", "-oq", str(z), "-d", str(bin_dir)])
                    (bin_dir / name).chmod(0o755)
        r = subprocess.run([FFMPEG, "-version"], capture_output=True, text=True)
        ok(f"ffmpeg 安装完成：{r.stdout.splitlines()[0] if r.returncode == 0 else '校验失败'}")

    elif a.component == "pngquant":
        import tempfile
        if IS_WIN:
            with tempfile.TemporaryDirectory() as td:
                z = Path(td) / "pngquant.zip"
                fetch("https://pngquant.org/pngquant-windows.zip", z)
                with zipfile.ZipFile(z) as zf:
                    for m in zf.namelist():
                        if Path(m).name == "pngquant.exe":
                            (bin_dir / "pngquant.exe").write_bytes(zf.read(m))
            ok("pngquant 安装完成（PNG 无损压缩可用）")
        else:
            with tempfile.TemporaryDirectory() as td:
                tarball = Path(td) / "pngquant.tar.bz2"
                fetch("https://pngquant.org/pngquant.tar.bz2", tarball)
                run(["tar", "-xjf", str(tarball), "-C", str(bin_dir)])
                (bin_dir / "pngquant").chmod(0o755)
            ok("pngquant 安装完成（PNG 无损压缩可用）")

    elif a.component == "libreoffice":
        url = "https://www.libreoffice.org/download/"
        platform_hint = "Windows 版安装后" if IS_WIN else "macOS 版并拖入应用程序文件夹；安装后"
        ok(f"LibreOffice 体积较大（约 700MB），请引导用户到官网 {url} "
           f"下载{platform_hint} PDF↔Word 高保真转换自动可用，无需其他配置。")

    elif a.component == "sevenzip":
        if not IS_WIN:
            die("sevenzip 组件仅 Windows 需要")
        z = bin_dir / "7za.zip"
        fetch("https://www.7-zip.org/a/7za920.zip", z)
        with zipfile.ZipFile(z) as zf:
            (bin_dir / "7za.exe").write_bytes(zf.read("7za.exe"))
        z.unlink()
        ok("7-Zip 组件安装完成（分卷压缩/合并可用）")

    elif a.component == "sensevoice-small":
        if not IS_WIN:
            die("sensevoice-small 组件仅 Windows 需要（macOS 用系统语音识别）")
        root, executable, model, vad = _sensevoice_paths()
        marker = root / "VERSION"
        if _sensevoice_component_ready():
            ok("SenseVoiceSmall Q8 转写组件已经安装，无需重复下载")
            return
        executable.parent.mkdir(parents=True, exist_ok=True)
        model.parent.mkdir(parents=True, exist_ok=True)
        downloads = root / "downloads"
        downloads.mkdir(parents=True, exist_ok=True)
        try:
            runtime_zip = _download_verified(
                SENSEVOICE_RUNTIME_URL, downloads / "runtime.zip",
                SENSEVOICE_RUNTIME_SIZE, SENSEVOICE_RUNTIME_SHA256, "SenseVoice Windows 运行程序")
            _download_verified(
                SENSEVOICE_MODEL_URL, model,
                SENSEVOICE_MODEL_SIZE, SENSEVOICE_MODEL_SHA256, "SenseVoiceSmall Q8 模型")
            _download_verified(
                SENSEVOICE_VAD_URL, vad,
                SENSEVOICE_VAD_SIZE, SENSEVOICE_VAD_SHA256, "FSMN-VAD 长音频分段模型")
            with zipfile.ZipFile(runtime_zip) as archive:
                payload = archive.read("llama-funasr-sensevoice.exe")
            executable_tmp = executable.with_name(executable.name + ".tmp")
            executable_tmp.write_bytes(payload)
            if not _verified_file(executable_tmp, SENSEVOICE_EXE_SIZE, SENSEVOICE_EXE_SHA256):
                executable_tmp.unlink(missing_ok=True)
                raise RuntimeError("SenseVoice Windows 运行程序解压后校验失败")
            os.replace(executable_tmp, executable)
        except (OSError, RuntimeError, zipfile.BadZipFile, KeyError) as exc:
            die(f"SenseVoiceSmall 组件安装失败：{exc}")

        (root / "NOTICE.txt").write_text(
            "SenseVoiceSmall Q8 component for Folderis\n"
            "Model: FunAudioLLM/SenseVoiceSmall\n"
            "Runtime: FunAudioLLM/SenseVoice runtime/llama.cpp v0.1.4\n"
            "Source: https://github.com/FunAudioLLM/SenseVoice\n"
            "Model terms: https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE\n",
            encoding="utf-8")
        marker.write_text(SENSEVOICE_COMPONENT_VERSION, encoding="utf-8")
        if not _sensevoice_component_ready():
            die("SenseVoiceSmall 组件安装后校验失败，请重新安装组件。")
        shutil.rmtree(downloads, ignore_errors=True)

        legacy_qwen = SUPPORT_DIR / "components" / "qwen3-asr"
        if legacy_qwen.is_dir():
            shutil.rmtree(legacy_qwen, ignore_errors=True)
            print("已清理 Folderis 旧版 Qwen3-ASR 组件，释放本地空间。")
        ok("SenseVoiceSmall Q8 转写组件安装完成（Windows 本地 CPU 离线识别）")

    elif a.component == "rembg":
        if not IS_WIN:
            die("rembg 组件仅 Windows 需要（macOS 用 Vision 框架）")
        r = subprocess.run([sys.executable, "-m", "pip", "install", "--no-warn-script-location",
                            "rembg", "onnxruntime"], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"安装失败：{r.stderr[-300:]}")
        os.environ.setdefault("U2NET_HOME", str(SUPPORT_DIR / "models"))
        from rembg import remove
        from PIL import Image as _I
        import io as _io
        print("下载抠图模型（约 170MB）…")
        buf = _io.BytesIO(); _I.new("RGB", (8, 8), "white").save(buf, "PNG")
        remove(buf.getvalue())
        ok("抠图组件安装完成")

    else:
        die(f"未知组件：{a.component}（可选：ffmpeg / pngquant / libreoffice / sevenzip / sensevoice-small / rembg）")


# ---------------------------------------------------------------- sys/zip

def cmd_hash_files(a):
    files = expand(a.files)
    algo = getattr(hashlib, a.algo)
    results = {}
    for f in files:
        h = algo()
        with open(f, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        results[str(f)] = h.hexdigest()
        print(f"{h.hexdigest()}  {f}")
    dupes = {}
    for path, digest in results.items():
        dupes.setdefault(digest, []).append(path)
    groups = [v for v in dupes.values() if len(v) > 1]
    if groups:
        print(f"\n发现 {len(groups)} 组内容相同的文件：")
        for g in groups:
            print("  == " + " | ".join(g))
    else:
        print("\n无重复文件")


def cmd_zip_batch(a):
    files = expand(a.files)
    if a.mode == "extract":
        for f in files:
            dest = available_output(Path(a.output or f.stem), explicit=bool(a.output))
            dest.mkdir(parents=True)
            if IS_WIN:
                # Windows 无 unzip/ditto：用 stdlib（zip 支持传统加密解压）
                if f.suffix.lower() == ".zip":
                    with zipfile.ZipFile(f) as zf:
                        zf.extractall(dest, pwd=a.password.encode() if a.password else None)
                else:
                    import tarfile
                    with tarfile.open(f) as tf:
                        tf.extractall(dest)
            elif f.suffix.lower() == ".zip":
                cmd = ["ditto", "-x", "-k", str(f), str(dest)]
                if a.password:
                    cmd = ["unzip", "-o", "-P", a.password, str(f), "-d", str(dest)]
                run(cmd)
            else:
                run(["tar", "-xf", str(f), "-C", str(dest)])
            print(f"{f.name} → {dest}/")
        ok(f"已解压 {len(files)} 个压缩包")
    elif a.mode == "create-split":
        if IS_WIN:
            sz = SUPPORT_DIR / "bin" / "7za.exe"
            if not sz.exists():
                die("分卷组件未安装。请先询问用户：需一次性下载 7-Zip 命令行组件（约 1MB）。"
                    "用户同意后调用技能 install-component sevenzip；拒绝则说明无法分卷。")
            out = available_family_output(Path(a.output or "archive.7z"))
            run([str(sz), "a", f"-v{a.volume_size}", str(out), *[str(f) for f in files]])
            parts = sorted(out.parent.glob(out.name + ".*"))
            ok(f"已创建分卷压缩：{', '.join(p.name for p in parts)}")
            return
        out = available_family_output(Path(a.output or "archive.zip"))
        # zip 的分卷下限是 64k
        m = re.match(r"^(\d+)([kmgt]?)$", a.volume_size.lower())
        if m and m.group(2) in ("", "k") and int(m.group(1)) < 64:
            a.volume_size = "64k"
        run(["zip", "-r", "-s", a.volume_size, str(out), *[str(f) for f in files]])
        parts = sorted(out.parent.glob(out.stem + ".z*"))
        ok(f"已创建分卷压缩：{', '.join(p.name for p in parts)}")
    elif a.mode == "merge-split":
        if IS_WIN:
            sz = SUPPORT_DIR / "bin" / "7za.exe"
            if not sz.exists():
                die("分卷组件未安装。请先询问用户：需一次性下载 7-Zip 命令行组件（约 1MB）。"
                    "用户同意后调用技能 install-component sevenzip。")
            first = next((f for f in files if f.name.endswith(".001")), files[0])
            dest = available_output(Path(a.output or first.stem.replace(".7z", "").replace(".zip", "")), explicit=bool(a.output))
            dest.mkdir(parents=True)
            run([str(sz), "x", "-y", f"-o{dest}", str(first)])
            ok(f"已合并分卷并解压 → {dest}/")
            return
        # macOS 自带 zip 的 `-s 0` 合并会截断分卷（实测 bug）。
        # 可靠做法：按 z01..zNN + 主 .zip 顺序二进制拼接，unzip 会自动
        # 对偏移做 re-compensate。
        main = next((f for f in files if f.suffix.lower() == ".zip"), files[0])
        parts = sorted(main.parent.glob(main.stem + ".z[0-9][0-9]")) + [main]
        merged = Path(tempfile.gettempdir()) / f"folderis-merged-{uuid.uuid4().hex}.zip"
        with open(merged, "wb") as out_fh:
            for part in parts:
                out_fh.write(Path(part).read_bytes())
        dest = available_output(Path(a.output or main.stem), explicit=bool(a.output))
        dest.mkdir(parents=True)
        r = subprocess.run(["unzip", "-o", "-q", str(merged), "-d", str(dest)],
                           capture_output=True, text=True)
        # unzip 对偏移补偿会报非零码但照常解出——以结果为准。
        extracted = any(dest.rglob("*"))
        if not extracted:
            die(f"解压失败：{(r.stderr or r.stdout)[-300:]}")
        merged.unlink(missing_ok=True)
        ok(f"已合并 {len(parts)} 个分卷并解压 → {dest}/")


def cmd_zip_repair(a):
    f = Path(a.file)
    fixed = available_output(f.with_name(f.stem + "_fixed.zip"))
    r = subprocess.run(["zip", "-FF", str(f), "--out", str(fixed)],
                       input="y\n", capture_output=True, text=True)
    if not fixed.exists():
        die(f"修复失败：{r.stderr[-400:]}")
    try:
        bad = zipfile.ZipFile(fixed).testzip()
        status = "完整可用" if bad is None else f"部分恢复（{bad} 仍损坏）"
    except Exception:
        status = "已重建目录结构，内容尽力恢复"
    ok(f"修复完成 → {fixed.name}（{status}）")



def cmd_qr_make(a):
    out = available_output(Path(a.output or "qrcode.png"), explicit=bool(a.output))
    if IS_WIN:
        try:
            import qrcode
        except ImportError:
            die("缺少 qrcode 库（重装技能运行时即可）")
        img = qrcode.make(a.text)
        img = img.resize((a.size, a.size))
        img.save(out)
    else:
        run(helper("qr") + ["make", a.text, str(out), str(a.size)])
    ok(f"二维码已生成：{out}")


def cmd_qr_read(a):
    files = expand(a.files)
    if IS_WIN:
        try:
            import zxingcpp
            from PIL import Image as _I
        except ImportError:
            die("缺少 zxing-cpp 库（重装技能运行时即可）")
        found = 0
        for f in files:
            codes = zxingcpp.read_barcodes(_I.open(f))
            if not codes:
                print(f"{f}\t(未识别到二维码/条形码)")
            for c in codes:
                print(f"{f}\t{c.text}"); found += 1
        if found == 0:
            die("所有图片中都没有识别到二维码/条形码")
        ok(f"已识别 {len(files)} 张图片")
        return
    r = subprocess.run(helper("qr") + ["read"] + [str(f) for f in files],
                       capture_output=True, text=True)
    print(r.stdout, end="")
    if r.returncode == 2:
        die("所有图片中都没有识别到二维码/条形码")
    if r.returncode != 0:
        die(f"识别失败：{r.stderr[-400:]}")
    ok(f"已识别 {len(files)} 张图片")


def cmd_pdf_watermark(a):
    files = expand(a.files)
    for f in files:
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_name(f.stem + "-水印.pdf")
        out = available_output(out, explicit=bool(a.output))
        if IS_WIN:
            _win_pdf_watermark(f, out, a.text, a.opacity, a.font_size)
            continue
        run(helper("pdfmark") + ["watermark", str(f), str(out), a.text,
                                 str(a.opacity), str(a.font_size)])
    ok(f"已为 {len(files)} 个 PDF 加水印")


def cmd_pdf_stamp(a):
    files = expand(a.files)
    for f in files:
        out = Path(a.output) if (a.output and len(files) == 1) else f.with_name(f.stem + "-盖章.pdf")
        out = available_output(out, explicit=bool(a.output))
        if IS_WIN:
            _win_pdf_stamp(f, out, a.image, a.page, a.position, a.width)
            continue
        run(helper("pdfmark") + ["stamp", str(f), str(out), a.image,
                                 a.page, a.position, str(a.width)])
    ok(f"已为 {len(files)} 个 PDF 盖章")


def cmd_zip_encrypt(a):
    files = expand(a.files)
    if IS_WIN:
        try:
            import pyzipper
        except ImportError:
            die("缺少 pyzipper（重装技能运行时即可）")
        out = available_output(Path(a.output or "加密压缩包.zip"), explicit=bool(a.output))
        with pyzipper.AESZipFile(out, "w", compression=pyzipper.ZIP_DEFLATED,
                                 encryption=pyzipper.WZ_AES) as zf:
            zf.setpassword(a.password.encode())
            for f in files:
                if f.is_dir():
                    for p in f.rglob("*"):
                        if p.is_file():
                            zf.write(p, p.relative_to(f.parent))
                else:
                    zf.write(f, f.name)
        ok(f"已加密打包 {len(files)} 项 → {out}（AES 加密，解压需密码）")
        return
    out = available_output(Path(a.output or "加密压缩包.zip"), explicit=bool(a.output))
    # zip 传统加密：兼容所有解压工具；敏感度极高的内容建议另用专业加密
    names = [str(f) for f in files]
    run(["zip", "-r", "-P", a.password, str(out)] + names)
    ok(f"已加密打包 {len(files)} 项 → {out}（解压需密码）")


def cmd_excel_groupby(a):
    from openpyxl import load_workbook, Workbook
    wb = load_workbook(a.file, data_only=True)
    ws = wb[a.sheet] if a.sheet else wb.active
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        die("表是空的")
    header, data = (rows[0], rows[1:]) if not a.no_header else (None, rows)
    by = a.by - 1
    val = (a.value - 1) if a.value else None
    groups = {}
    for r in data:
        if by >= len(r):
            continue
        k = r[by]
        groups.setdefault(k, []).append(r)
    out_wb = Workbook()
    out_ws = out_wb.active
    by_name = (header[by] if header and header[by] else f"列{a.by}")
    if a.agg == "count":
        out_ws.append([by_name, "计数"])
        for k, rs in groups.items():
            out_ws.append([k, len(rs)])
    else:
        if val is None:
            die("sum/avg 需要 --value 指定数值列（1 起）")
        val_name = (header[val] if header and header[val] else f"列{a.value}")
        out_ws.append([by_name, f"{val_name}（{'求和' if a.agg == 'sum' else '平均'}）"])
        for k, rs in groups.items():
            nums = []
            for r in rs:
                try:
                    nums.append(float(r[val]))
                except (TypeError, ValueError, IndexError):
                    pass
            total = sum(nums)
            out_ws.append([k, total if a.agg == "sum" else (total / len(nums) if nums else 0)])
    out = available_output(Path(a.output or Path(a.file).with_name(Path(a.file).stem + "-汇总.xlsx")), explicit=bool(a.output))
    out_wb.save(out)
    ok(f"已按「{by_name}」{ {'sum':'求和','count':'计数','avg':'求平均'}[a.agg] }，{len(groups)} 组 → {out}")


def cmd_dir_inventory(a):
    from openpyxl import Workbook
    import datetime
    root = Path(a.dir or ".").resolve()
    wb = Workbook()
    ws = wb.active
    ws.append(["名称", "相对路径", "类型", "大小(字节)", "修改时间"])
    count = 0
    for p in sorted(root.rglob("*")):
        if any(part.startswith(".") for part in p.relative_to(root).parts):
            continue
        st = p.stat()
        ws.append([
            p.name,
            str(p.relative_to(root)),
            "文件夹" if p.is_dir() else (p.suffix.lstrip(".").lower() or "文件"),
            "" if p.is_dir() else st.st_size,
            datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M"),
        ])
        count += 1
        if count >= 20000:
            break
    out = available_output(Path(a.output or "文件清单.xlsx"), explicit=bool(a.output))
    wb.save(out)
    ok(f"已导出 {count} 项 → {out}")


def _read_excel_rows(path, sheet=None):
    """Read the first/selected sheet from xls or xlsx without changing it."""
    path = Path(path)
    if path.suffix.lower() == ".xls":
        try:
            import xlrd
        except ImportError:
            die("缺少 xlrd（重装技能运行时即可）")
        book = xlrd.open_workbook(str(path))
        worksheet = book.sheet_by_name(sheet) if sheet else book.sheet_by_index(0)
        rows = []
        for row_index in range(worksheet.nrows):
            values = []
            for column_index in range(worksheet.ncols):
                cell = worksheet.cell(row_index, column_index)
                if cell.ctype == xlrd.XL_CELL_DATE:
                    values.append(xlrd.xldate.xldate_as_datetime(cell.value, book.datemode))
                elif cell.ctype == xlrd.XL_CELL_BOOLEAN:
                    values.append(bool(cell.value))
                elif cell.ctype in (xlrd.XL_CELL_EMPTY, xlrd.XL_CELL_BLANK):
                    values.append(None)
                else:
                    values.append(cell.value)
            rows.append(tuple(values))
        return rows

    import openpyxl
    book = openpyxl.load_workbook(str(path), data_only=True, read_only=True)
    worksheet = book[sheet] if sheet else book.active
    return list(worksheet.iter_rows(values_only=True))


def _find_header_alias(header, requested, aliases, label):
    cleaned = ["" if value is None else str(value).strip() for value in header]
    if requested and requested.lower() != "auto":
        for index, value in enumerate(cleaned):
            if value.casefold() == requested.strip().casefold():
                return index
        if requested.isdigit() and 1 <= int(requested) <= len(cleaned):
            return int(requested) - 1
        die(f"找不到{label}「{requested}」（表头：{cleaned[:12]}）")
    alias_keys = {value.casefold() for value in aliases}
    for index, value in enumerate(cleaned):
        if value.casefold() in alias_keys:
            return index
    die(f"无法自动识别{label}（表头：{cleaned[:12]}）")


def _month_name(value):
    import calendar
    import datetime as dt
    if isinstance(value, (dt.datetime, dt.date)):
        return calendar.month_name[value.month]
    text = "" if value is None else str(value).strip()
    if not text:
        return ""
    for pattern in (
        "%d/%m/%Y", "%Y/%m/%d", "%m/%d/%Y", "%Y-%m-%d", "%d-%m-%Y",
        "%Y.%m.%d", "%d.%m.%Y", "%Y年%m月%d日", "%Y年%m月",
    ):
        try:
            return calendar.month_name[dt.datetime.strptime(text, pattern).month]
        except ValueError:
            pass
    match = re.search(r"(?:^|\D)(1[0-2]|0?[1-9])月", text)
    if match:
        return calendar.month_name[int(match.group(1))]
    die(f"无法解析日期「{text}」，请先统一日期格式")


def _safe_sheet_title(value, used):
    base = re.sub(r"[\\/*?:\[\]]", "_", str(value or "未分类")).strip() or "未分类"
    base = base[:31]
    candidate = base
    index = 2
    while candidate.casefold() in used:
        suffix = f"_{index}"
        candidate = base[:31 - len(suffix)] + suffix
        index += 1
    used.add(candidate.casefold())
    return candidate


def cmd_excel_derive_split_sheets(a):
    """Derive an English Month column from Date and split rows into sheets."""
    from openpyxl import Workbook
    src = Path(a.file).resolve()
    rows = _read_excel_rows(src, a.sheet)
    if len(rows) < 2:
        die("表格没有可处理的数据行")
    header = list(rows[0])
    date_index = _find_header_alias(
        header, a.date_column,
        ["date", "日期", "时间", "下单日期", "created at", "created_at"], "日期列")
    group_index = _find_header_alias(
        header, a.group_column,
        ["country", "region", "area", "location", "国家", "地区", "区域", "大区"], "分组列")

    derived_name = a.derived_column or "Month"
    derived_index = next(
        (index for index, value in enumerate(header)
         if value is not None and str(value).strip().casefold() == derived_name.casefold()),
        None)
    if derived_index is None:
        derived_index = len(header)
        header.append(derived_name)

    groups = {}
    for source_row in rows[1:]:
        row = list(source_row) + [None] * max(0, len(header) - len(source_row))
        row[derived_index] = _month_name(row[date_index])
        key = row[group_index] if group_index < len(row) else None
        groups.setdefault(key if key not in (None, "") else "未分类", []).append(row[:len(header)])
    if not groups:
        die("没有可拆分的数据行")

    output_book = Workbook()
    output_book.remove(output_book.active)
    used_titles = set()
    for key, group_rows in groups.items():
        worksheet = output_book.create_sheet(_safe_sheet_title(key, used_titles))
        worksheet.append(header)
        for row in group_rows:
            worksheet.append(row)
        worksheet.freeze_panes = "A2"
        worksheet.auto_filter.ref = worksheet.dimensions

    default_output = src.with_name(src.stem + "_按地区拆分.xlsx")
    output = available_output(Path(a.output) if a.output else default_output,
                              explicit=bool(a.output))
    output_book.save(output)
    ok(f"已新增「{derived_name}」列并按「{header[group_index]}」拆分为 {len(groups)} 个工作表 → {output}")


def cmd_excel_dummy(a):
    """Create a Unicode-safe sample workbook directly, without helper scripts."""
    from openpyxl import Workbook
    import datetime as dt
    rows = max(1, min(a.rows, 10000))
    categories = ["办公用品", "电子产品", "家居用品", "包装材料"]
    warehouses = ["上海仓", "北京仓", "广州仓", "成都仓"]
    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = "库存数据"
    worksheet.append(["SKU", "产品名称", "分类", "库存数量", "单价", "仓库", "更新日期"])
    for index in range(1, rows + 1):
        worksheet.append([
            f"SKU-{index:05d}", f"测试产品 {index}", categories[(index - 1) % len(categories)],
            (index * 17) % 500, round(9.9 + (index * 3.17) % 300, 2),
            warehouses[(index - 1) % len(warehouses)], dt.date(2026, 1 + (index - 1) % 12, 1 + (index - 1) % 28),
        ])
    worksheet.freeze_panes = "A2"
    worksheet.auto_filter.ref = worksheet.dimensions
    output = available_output(Path(a.output or "模拟库存数据.xlsx"), explicit=bool(a.output))
    workbook.save(output)
    ok(f"已直接生成 {rows} 行模拟库存数据 → {output}")



def _find_col(header, spec):
    """列定位：优先按表头名精确匹配，其次按 1 起列号。返回 0 起下标。"""
    for i, h in enumerate(header):
        if h is not None and str(h).strip() == str(spec).strip():
            return i
    if str(spec).isdigit():
        idx = int(spec) - 1
        if 0 <= idx < len(header):
            return idx
    die(f"找不到列「{spec}」（表头：{[str(h) for h in header if h is not None][:12]}）")


def cmd_excel_update_by_key(a):
    """按关联键把源表数据同步进目标表的对应列，目标表其余单元格（含公式）不动。"""
    import openpyxl
    swb = openpyxl.load_workbook(a.source, data_only=True)
    sws = swb[a.source_sheet] if a.source_sheet else swb.active
    srows = list(sws.iter_rows(values_only=True))
    if not srows:
        die("源表为空")
    sheader = list(srows[0])
    skey = _find_col(sheader, a.key)
    cols = [c.strip() for c in a.columns.split(",")] if a.columns else            [str(h) for i, h in enumerate(sheader) if i != skey and h is not None]
    scols = {c: _find_col(sheader, c) for c in cols}
    smap = {}
    for r in srows[1:]:
        k = r[skey]
        if k is not None:
            smap[str(k).strip()] = r

    twb = openpyxl.load_workbook(a.target)  # 不开 data_only：保住公式
    tws = twb[a.target_sheet] if a.target_sheet else twb.active
    theader = [c.value for c in tws[1]]
    tkey = _find_col(theader, a.key)
    tcols = {}
    for c in cols:
        try:
            tcols[c] = _find_col(theader, c)
        except SystemExit:
            # 目标表没有该列：追加到最右
            new_idx = len(theader)
            tws.cell(row=1, column=new_idx + 1, value=c)
            theader.append(c)
            tcols[c] = new_idx

    updated, missed = 0, []
    for row in tws.iter_rows(min_row=2):
        k = row[tkey].value
        if k is None:
            continue
        src = smap.get(str(k).strip())
        if src is None:
            missed.append(str(k).strip())
            continue
        for c, si in scols.items():
            tws.cell(row=row[0].row, column=tcols[c] + 1, value=src[si])
        updated += 1
    target = Path(a.target)
    out = available_output(Path(a.output) if a.output else target.with_name(target.stem + "-更新" + target.suffix), explicit=bool(a.output))
    twb.save(out)
    msg = f"已按「{a.key}」更新 {updated} 行 × {len(cols)} 列 → {out}"
    if missed:
        msg += f"；目标表中 {len(missed)} 个键在源表无匹配：{', '.join(missed[:8])}" + ("…" if len(missed) > 8 else "")
    ok(msg)


PATTERNS = {
    "phone": r"(?<!\d)1[3-9]\d{9}(?!\d)",
    "email": r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "idcard": r"(?<!\d)\d{17}[\dXx](?!\d)",
}


def cmd_extract_patterns(a):
    """从混杂表格里提取手机号/邮箱/身份证并去重，可带上同行的归属列。"""
    import openpyxl
    pattern = re.compile(a.regex if a.type == "custom" else PATTERNS[a.type])
    if a.type == "custom" and not a.regex:
        die("--type custom 需要 --regex")
    seen, results = set(), []
    for f in expand(a.files):
        if f.suffix.lower() == ".csv":
            raw = f.read_bytes()
            try:
                import chardet
                enc = chardet.detect(raw)["encoding"] or "utf-8"
            except ImportError:
                enc = "utf-8"
            rows = list(csv.reader(io.StringIO(raw.decode(enc, errors="ignore"))))
            sheets = {"CSV": rows}
        else:
            wb = openpyxl.load_workbook(str(f), data_only=True)
            sheets = {n: list(wb[n].iter_rows(values_only=True)) for n in wb.sheetnames}
        for sname, rows in sheets.items():
            header = [str(h) for h in (rows[0] if rows else [])]
            ctx_idx = None
            if a.context:
                try:
                    ctx_idx = _find_col(header, a.context)
                except SystemExit:
                    ctx_idx = None
            for ri, row in enumerate(rows, 1):
                for cell in row:
                    if cell is None:
                        continue
                    for m in pattern.findall(str(cell)):
                        if m in seen:
                            continue
                        seen.add(m)
                        ctx = (str(row[ctx_idx]) if ctx_idx is not None and ctx_idx < len(row)
                               and row[ctx_idx] is not None else "")
                        results.append((m, ctx, f.name, sname, ri))
    if not results:
        die("没有提取到任何匹配内容")
    out_wb = __import__("openpyxl").Workbook()
    ws = out_wb.active
    label = {"phone": "手机号", "email": "邮箱", "idcard": "身份证号", "custom": "匹配值"}[a.type]
    ws.append([label, a.context or "归属", "来源文件", "工作表", "行号"])
    for r in results:
        ws.append(list(r))
    out = available_output(Path(a.output or f"提取-{label}.xlsx"), explicit=bool(a.output))
    out_wb.save(out)
    ok(f"已提取 {len(results)} 个去重后的{label} → {out}")


def cmd_excel_split_column(a):
    """按某列的值把大表拆成多个文件，各自保留表头。"""
    import openpyxl
    src = Path(a.file)
    wb = openpyxl.load_workbook(str(src), data_only=True)
    ws = wb[a.sheet] if a.sheet else wb.active
    rows = list(ws.iter_rows(values_only=True))
    if len(rows) < 2:
        die("表内没有数据行")
    header = list(rows[0])
    idx = _find_col(header, a.by)
    groups = {}
    for r in rows[1:]:
        k = r[idx] if idx < len(r) else None
        groups.setdefault("（空）" if k is None else str(k).strip(), []).append(r)
    widths = {c: ws.column_dimensions[openpyxl.utils.get_column_letter(ci + 1)].width
              for ci, c in enumerate(header) if header}
    for k, rs in groups.items():
        nwb = openpyxl.Workbook()
        nws = nwb.active
        nws.title = ws.title
        nws.append(header)
        for r in rs:
            nws.append(list(r))
        for ci in range(len(header)):
            w = widths.get(header[ci])
            if w:
                nws.column_dimensions[openpyxl.utils.get_column_letter(ci + 1)].width = w
        safe = re.sub(r'[/\\:*?"<>|]', "_", k)[:60]
        nwb.save(available_output(src.with_name(f"{src.stem}-{safe}.xlsx")))
    ok(f"已按「{header[idx]}」拆成 {len(groups)} 个文件（各含表头，共 {len(rows) - 1} 行）")


def cmd_excel_fuzzy_merge(a):
    """两表键不完全一致时按相似度关联：B 表数据补进 A 表，带相似度列供复核。"""
    import openpyxl
    from difflib import SequenceMatcher
    awb = openpyxl.load_workbook(a.file_a)
    aws = awb.active
    arows = list(aws.iter_rows(values_only=True))
    bwb = openpyxl.load_workbook(a.file_b, data_only=True)
    bws = bwb.active
    brows = list(bwb.active.iter_rows(values_only=True))
    if len(arows) < 2 or len(brows) < 2:
        die("两表都需要至少一行数据")
    ah, bh = list(arows[0]), list(brows[0])
    ak = _find_col(ah, a.key_a or a.key)
    bk = _find_col(bh, a.key_b or a.key)
    cols = [c.strip() for c in a.columns.split(",")] if a.columns else            [str(h) for i, h in enumerate(bh) if i != bk and h is not None]
    bcols = {c: _find_col(bh, c) for c in cols}
    bkeys = [(str(r[bk]).strip(), r) for r in brows[1:] if r[bk] is not None]

    base = len(ah)
    for j, c in enumerate(cols):
        aws.cell(row=1, column=base + 1 + j, value=c)
    aws.cell(row=1, column=base + len(cols) + 1, value="匹配到")
    aws.cell(row=1, column=base + len(cols) + 2, value="相似度")

    matched = 0
    for row in aws.iter_rows(min_row=2):
        k = row[ak].value
        if k is None:
            continue
        key = str(k).strip()
        best, score = None, 0.0
        for bkey, br in bkeys:
            s = SequenceMatcher(None, key, bkey).ratio()
            if s > score:
                best, score = (bkey, br), s
        if best and score >= a.threshold:
            for j, c in enumerate(cols):
                aws.cell(row=row[0].row, column=base + 1 + j, value=best[1][bcols[c]])
            aws.cell(row=row[0].row, column=base + len(cols) + 1, value=best[0])
            aws.cell(row=row[0].row, column=base + len(cols) + 2, value=round(score, 2))
            matched += 1
        else:
            aws.cell(row=row[0].row, column=base + len(cols) + 2,
                     value=f"未匹配（最高{round(score, 2)}）")
    out = available_output(Path(a.output or Path(a.file_a).with_name(Path(a.file_a).stem + "-补全.xlsx")), explicit=bool(a.output))
    awb.save(out)
    ok(f"已模糊关联 {matched}/{len(arows) - 1} 行（阈值 {a.threshold}，附相似度列供复核）→ {out}")


def _md_escape_cell(v):
    return str(v).replace("|", "\\|").replace("\n", " ") if v is not None else ""


def cmd_doc_to_markdown(a):
    """docx/xlsx/csv/pdf/txt/html → Markdown（原生解析，零外部依赖）。"""
    outputs = []
    for f in expand(a.files):
        ext = f.suffix.lower()
        md = ""
        if ext == ".docx":
            import docx
            doc = docx.Document(str(f))
            parts = []
            for el in doc.element.body:
                if el.tag.endswith("}p"):
                    p = docx.text.paragraph.Paragraph(el, doc)
                    t = p.text.strip()
                    if not t:
                        continue
                    style = (p.style.name or "").lower()
                    m = re.search(r"heading (\d)", style)
                    parts.append(("#" * int(m.group(1)) + " " + t) if m else t)
                elif el.tag.endswith("}tbl"):
                    tbl = docx.table.Table(el, doc)
                    rows = [[_md_escape_cell(c.text) for c in r.cells] for r in tbl.rows]
                    if rows:
                        parts.append("| " + " | ".join(rows[0]) + " |")
                        parts.append("|" + "---|" * len(rows[0]))
                        for r in rows[1:]:
                            parts.append("| " + " | ".join(r) + " |")
            md = "\n\n".join(parts)
        elif ext in (".xlsx", ".xlsm"):
            import openpyxl
            wb = openpyxl.load_workbook(str(f), data_only=True)
            parts = []
            for name in wb.sheetnames:
                rows = list(wb[name].iter_rows(values_only=True))
                if not rows:
                    continue
                parts.append(f"## {name}")
                parts.append("| " + " | ".join(_md_escape_cell(v) for v in rows[0]) + " |")
                parts.append("|" + "---|" * len(rows[0]))
                for r in rows[1:2000]:
                    parts.append("| " + " | ".join(_md_escape_cell(v) for v in r) + " |")
                if len(rows) > 2001:
                    parts.append(f"…（其余 {len(rows) - 2001} 行略）")
            md = "\n".join(parts)
        elif ext == ".csv":
            raw = f.read_bytes()
            try:
                import chardet
                enc = chardet.detect(raw)["encoding"] or "utf-8"
            except ImportError:
                enc = "utf-8"
            rows = list(csv.reader(io.StringIO(raw.decode(enc, errors="ignore"))))
            if rows:
                lines = ["| " + " | ".join(_md_escape_cell(v) for v in rows[0]) + " |",
                         "|" + "---|" * len(rows[0])]
                lines += ["| " + " | ".join(_md_escape_cell(v) for v in r) + " |" for r in rows[1:2000]]
                md = "\n".join(lines)
        elif ext == ".pdf":
            md = "\n\n".join((p.extract_text() or "").strip()
                              for p in _reader(f, None).pages if (p.extract_text() or "").strip())
        elif ext in (".txt", ".md"):
            md = f.read_text(encoding="utf-8", errors="ignore")
        elif ext in (".html", ".htm"):
            import html as _html
            raw = f.read_text(encoding="utf-8", errors="ignore")
            raw = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", raw, flags=re.S | re.I)
            raw = re.sub(r"<h(\d)[^>]*>(.*?)</h\1>", lambda m: "\n" + "#" * int(m.group(1)) + " " + m.group(2) + "\n", raw, flags=re.S | re.I)
            raw = re.sub(r"<br\s*/?>|</p>", "\n", raw, flags=re.I)
            md = _html.unescape(re.sub(r"<[^>]+>", "", raw))
            md = re.sub(r"\n{3,}", "\n\n", md).strip()
        else:
            print(f"跳过（不支持的类型）：{f.name}")
            continue
        out = available_output(Path(a.output_dir or ".") / (f.stem + ".md"), explicit=False)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(md, encoding="utf-8")
        outputs.append(out.name)
        print(f"{f.name} → {out.name}（{len(md)} 字符）")
    if not outputs:
        die("没有可转换的文件")
    ok(f"已转换 {len(outputs)} 个文档为 Markdown")


# ----------------------------------------------------------------- parser

def build_parser():
    p = argparse.ArgumentParser(prog="skills")
    sub = p.add_subparsers(dest="skill", required=True)

    def add(name, fn, conf):
        sp = sub.add_parser(name)
        conf(sp)
        sp.add_argument("--overwrite-original", action="store_true", help=argparse.SUPPRESS)
        sp.set_defaults(fn=fn)

    add("rename-batch", cmd_rename_batch, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--template"),
        s.add_argument("--regex"), s.add_argument("--replace"),
        s.add_argument("--ext"), s.add_argument("--start", type=int, default=1),
        s.add_argument("--pad", type=int, default=3), s.add_argument("--dry-run", action="store_true")])
    add("pdf-split", cmd_pdf_split, lambda s: [
        s.add_argument("file"), s.add_argument("--ranges"), s.add_argument("--output"),
        s.add_argument("--password")])
    add("pdf-reorder", cmd_pdf_reorder, lambda s: [
        s.add_argument("file"), s.add_argument("order"),
        s.add_argument("--output"), s.add_argument("--password")])
    add("pdf-merge", cmd_pdf_merge, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output", required=True)])
    add("pdf-crypt", cmd_pdf_crypt, lambda s: [
        s.add_argument("mode", choices=["encrypt", "decrypt"]), s.add_argument("file"),
        s.add_argument("--password"), s.add_argument("--new-password"), s.add_argument("--output")])
    add("pdf-compress", cmd_pdf_compress, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--in-place", action="store_true")])
    add("pdf-convert", cmd_pdf_convert, lambda s: [
        s.add_argument("--file"), s.add_argument("--files", nargs="*", default=[]),
        s.add_argument("--to", required=True),
        s.add_argument("--output"), s.add_argument("--dpi", type=int, default=150),
        s.add_argument("--password"), s.add_argument("--pages")])
    add("pdf-ocr", cmd_pdf_ocr, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output"),
        s.add_argument("--dpi", type=int, default=220), s.add_argument("--password"),
        s.add_argument("--pages")])
    add("merge-docs", cmd_merge_docs, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output", required=True)])
    add("txt-clean", cmd_txt_clean, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--trim", action="store_true"),
        s.add_argument("--collapse-blank", action="store_true"),
        s.add_argument("--strip-all-blank", action="store_true"),
        s.add_argument("--in-place", action="store_true")])
    add("txt-split", cmd_txt_split, lambda s: [
        s.add_argument("file"), s.add_argument("--lines", type=int),
        s.add_argument("--chars", type=int), s.add_argument("--delimiter")])
    add("excel-split", cmd_excel_split, lambda s: [s.add_argument("file")])
    add("excel-merge", cmd_excel_merge, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output", required=True),
        s.add_argument("--into-one-sheet", action="store_true")])
    add("excel-dedupe", cmd_excel_dedupe, lambda s: [
        s.add_argument("file"), s.add_argument("--columns")])
    add("excel-diff", cmd_excel_diff, lambda s: [
        s.add_argument("file_a"), s.add_argument("file_b"), s.add_argument("--columns")])
    add("excel-transform", cmd_excel_transform, lambda s: [
        s.add_argument("file"), s.add_argument("--split-column", type=int),
        s.add_argument("--merge-columns"), s.add_argument("--delimiter"),
        s.add_argument("--regex"), s.add_argument("--drop-source", action="store_true"),
        s.add_argument("--sheet"), s.add_argument("--no-header", action="store_true"),
        s.add_argument("--in-place", action="store_true")])
    add("excel-derive-split-sheets", cmd_excel_derive_split_sheets, lambda s: [
        s.add_argument("file"), s.add_argument("--date-column", default="auto"),
        s.add_argument("--group-column", default="auto"),
        s.add_argument("--derived-column", default="Month"),
        s.add_argument("--sheet"), s.add_argument("--output")])
    add("excel-dummy", cmd_excel_dummy, lambda s: [
        s.add_argument("--rows", type=int, default=100), s.add_argument("--output")])
    add("csv-preview", cmd_csv_preview, lambda s: [
        s.add_argument("file"), s.add_argument("--rows", type=int, default=10),
        s.add_argument("--encoding", default="utf-8")])
    add("encoding-convert", cmd_encoding_convert, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--source"),
        s.add_argument("--target", default="utf-8"), s.add_argument("--in-place", action="store_true")])

    add("img-compress", cmd_img_compress, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--quality", type=int, default=72)])
    add("png-compress", cmd_png_compress, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--quality", default="65-90"),
        s.add_argument("--in-place", action="store_true")])
    add("jpg-compress", cmd_jpg_compress, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--quality", type=int, default=85),
        s.add_argument("--strict-lossless", action="store_true"),
        s.add_argument("--in-place", action="store_true")])
    add("img-resize", cmd_img_resize, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--width", type=int),
        s.add_argument("--height", type=int), s.add_argument("--percent", type=int),
        s.add_argument("--crop"), s.add_argument("--in-place", action="store_true")])
    add("img-convert", cmd_img_convert, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--to", required=True),
        s.add_argument("--output")])
    add("img-watermark", cmd_img_watermark, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--text"),
        s.add_argument("--logo"), s.add_argument("--position", default="br"),
        s.add_argument("--opacity", type=float, default=0.5), s.add_argument("--size", type=int)])
    add("img-remove-bg", cmd_img_remove_bg, lambda s: [s.add_argument("files", nargs="+")])
    add("img-split", cmd_img_split, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--parts", type=int, required=True),
        s.add_argument("--direction", default="vertical")])
    add("img-stitch", cmd_img_stitch, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output", required=True),
        s.add_argument("--direction", default="vertical")])
    add("img-rotate", cmd_img_rotate, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--angle", type=int, default=0),
        s.add_argument("--flip"), s.add_argument("--in-place", action="store_true")])
    add("img-ocr", cmd_img_ocr, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output")])
    add("img-to-ico", cmd_img_to_ico, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output")])

    add("av-extract-audio", cmd_av_extract_audio, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--to", default="mp3")])
    add("av-trim", cmd_av_trim, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--start", default="0"),
        s.add_argument("--end"), s.add_argument("--output"),
        s.add_argument("--fast", action="store_true")])
    add("av-convert", cmd_av_convert, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--to", required=True)])
    add("av-compress", cmd_av_compress, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--crf", type=int, default=28),
        s.add_argument("--width", type=int)])
    add("av-merge", cmd_av_merge, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output", required=True)])
    add("audio-trim", cmd_audio_trim, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--start", default="0"),
        s.add_argument("--end"), s.add_argument("--output"),
        s.add_argument("--fast", action="store_true", default=True)])
    add("audio-concat", cmd_audio_concat, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output", required=True)])
    add("audio-convert", cmd_audio_convert, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--to", required=True)])
    add("audio-denoise", cmd_audio_denoise, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--strength", type=int, default=12),
        s.add_argument("--output")])
    add("av-gif", cmd_av_gif, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--fps", type=int, default=12),
        s.add_argument("--width", type=int, default=480), s.add_argument("--start"),
        s.add_argument("--duration", type=float), s.add_argument("--output")])
    add("av-subtitles", cmd_av_subtitles, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--subtitles"),
        s.add_argument("--soft", action="store_true"), s.add_argument("--output")])

    add("audio-transcribe", cmd_audio_transcribe, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--locale", default="zh-CN"),
        s.add_argument("--output")])
    add("content-search", cmd_content_search, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--query", required=True)])
    add("docx-fill", cmd_docx_fill, lambda s: [
        s.add_argument("template"), s.add_argument("data"),
        s.add_argument("--name-column"), s.add_argument("--output-dir")])
    add("table-convert", cmd_table_convert, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output")])
    add("av-frames", cmd_av_frames, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--every", type=int, default=10),
        s.add_argument("--at")])
    add("doc-diff", cmd_doc_diff, lambda s: [
        s.add_argument("file_a"), s.add_argument("file_b")])
    add("install-component", cmd_install_component, lambda s: [
        s.add_argument("component", choices=[
            "ffmpeg", "pngquant", "libreoffice", "sevenzip", "sensevoice-small", "rembg"
        ])])
    add("hash-files", cmd_hash_files, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--algo", default="md5")])
    add("zip-batch", cmd_zip_batch, lambda s: [
        s.add_argument("mode", choices=["extract", "create-split", "merge-split"]),
        s.add_argument("files", nargs="+"), s.add_argument("--output"),
        s.add_argument("--password"), s.add_argument("--volume-size", default="100m")])
    add("zip-repair", cmd_zip_repair, lambda s: [s.add_argument("file")])
    add("qr-make", cmd_qr_make, lambda s: [
        s.add_argument("text"), s.add_argument("--output"),
        s.add_argument("--size", type=int, default=512)])
    add("qr-read", cmd_qr_read, lambda s: [s.add_argument("files", nargs="+")])
    add("pdf-watermark", cmd_pdf_watermark, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--text", required=True),
        s.add_argument("--opacity", type=float, default=0.15),
        s.add_argument("--font-size", type=int, default=42),
        s.add_argument("--output")])
    add("pdf-stamp", cmd_pdf_stamp, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--image", required=True),
        s.add_argument("--page", default="all"),
        s.add_argument("--position", default="br"),
        s.add_argument("--width", type=int, default=150),
        s.add_argument("--output")])
    add("zip-encrypt", cmd_zip_encrypt, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--password", required=True),
        s.add_argument("--output")])
    add("excel-groupby", cmd_excel_groupby, lambda s: [
        s.add_argument("file"), s.add_argument("--by", type=int, required=True),
        s.add_argument("--agg", choices=["sum", "count", "avg"], default="sum"),
        s.add_argument("--value", type=int), s.add_argument("--sheet"),
        s.add_argument("--no-header", action="store_true"), s.add_argument("--output")])
    add("excel-update-by-key", cmd_excel_update_by_key, lambda s: [
        s.add_argument("--source", required=True), s.add_argument("--target", required=True),
        s.add_argument("--key", required=True), s.add_argument("--columns"),
        s.add_argument("--source-sheet"), s.add_argument("--target-sheet"),
        s.add_argument("--output")])
    add("extract-patterns", cmd_extract_patterns, lambda s: [
        s.add_argument("files", nargs="+"),
        s.add_argument("--type", choices=["phone", "email", "idcard", "custom"], default="phone"),
        s.add_argument("--regex"), s.add_argument("--context"),
        s.add_argument("--output")])
    add("excel-split-column", cmd_excel_split_column, lambda s: [
        s.add_argument("file"), s.add_argument("--by", required=True),
        s.add_argument("--sheet")])
    add("excel-fuzzy-merge", cmd_excel_fuzzy_merge, lambda s: [
        s.add_argument("file_a"), s.add_argument("file_b"),
        s.add_argument("--key"), s.add_argument("--key-a"), s.add_argument("--key-b"),
        s.add_argument("--columns"), s.add_argument("--threshold", type=float, default=0.6),
        s.add_argument("--output")])
    add("doc-to-markdown", cmd_doc_to_markdown, lambda s: [
        s.add_argument("files", nargs="+"), s.add_argument("--output-dir")])
    add("local-dispatch", cmd_local_dispatch, lambda s: [
        s.add_argument("--request", required=True),
        s.add_argument("--files", nargs="*", required=True)])
    add("dir-inventory", cmd_dir_inventory, lambda s: [
        s.add_argument("dir", nargs="?"), s.add_argument("--output")])
    return p


def _normalized_path(value):
    resolved = str(Path(value).expanduser().resolve(strict=False))
    return unicodedata.normalize("NFC", resolved).casefold()


def _same_path(left, right):
    return _normalized_path(left) == _normalized_path(right)


_OUTPUT_RESERVATION_HANDLES = []
_OUTPUT_RESERVATION_KEYS = set()
_OUTPUT_RESERVATION_GUARD = threading.Lock()


def _release_output_reservations():
    while _OUTPUT_RESERVATION_HANDLES:
        try:
            _OUTPUT_RESERVATION_HANDLES.pop().close()
        except OSError:
            pass


atexit.register(_release_output_reservations)


def _output_family_root(path):
    path = Path(path)
    name = path.name
    root = re.sub(r"\.(?:7z|zip)\.\d{3,}$", "", name, flags=re.I)
    root = re.sub(r"\.z\d{2,}$", "", root, flags=re.I)
    if root == name:
        root = path.stem
    return path.parent / root


def _reserve_output(path):
    """Atomically reserve an output and its multipart family namespace."""
    identities = {_normalized_path(path), _normalized_path(_output_family_root(path)) + "\0family"}
    keys = sorted(hashlib.sha256(identity.encode("utf-8")).hexdigest()
                  for identity in identities)
    with _OUTPUT_RESERVATION_GUARD:
        if any(key in _OUTPUT_RESERVATION_KEYS for key in keys):
            return False
        lock_root = Path(tempfile.gettempdir()) / "folderis-output-reservations"
        lock_root.mkdir(parents=True, exist_ok=True)
        acquired = []
        try:
            for key in keys:
                handle = open(lock_root / f"{key}.lock", "a+b")
                try:
                    handle.seek(0, os.SEEK_END)
                    if handle.tell() == 0:
                        handle.write(b"0")
                        handle.flush()
                    handle.seek(0)
                    if IS_WIN:
                        import msvcrt
                        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired.append(handle)
                except (OSError, IOError):
                    handle.close()
                    raise
        except (OSError, IOError):
            for handle in acquired:
                handle.close()
            return False
        _OUTPUT_RESERVATION_KEYS.update(keys)
        _OUTPUT_RESERVATION_HANDLES.extend(acquired)
        return True


def available_output(path, explicit=False):
    """Return a free output path without replacing an earlier result.

    Explicit names are still versioned when occupied. Naming an output is not
    permission to destroy an earlier result.
    """
    path = Path(path)
    for index in range(1, 10000):
        candidate = path if index == 1 else path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists() and _reserve_output(candidate):
            return candidate
    die(f"无法为 {path.name} 生成不重复的输出名")


def available_family_output(path):
    """Return a free base name for outputs that create a family of parts."""
    path = Path(path)
    for index in range(1, 10000):
        candidate = path if index == 1 else path.with_name(f"{path.stem}_{index}{path.suffix}")
        occupied = (
            candidate.exists()
            or any(candidate.parent.glob(candidate.name + ".*"))
            or any(candidate.parent.glob(candidate.stem + ".z[0-9]*"))
        )
        if not occupied and _reserve_output(candidate):
            return candidate
    die(f"无法为 {path.name} 生成不重复的分卷输出名")


def _route_number(text, patterns, cast=float):
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.I)
        if match:
            return cast(match.group(1))
    return None


def _requested_output(request, extensions, inputs):
    """Return an explicit output filename from the request, in the input folder."""
    ext_pattern = "|".join(re.escape(ext.lstrip(".")) for ext in extensions)
    candidates = []
    for pattern in [
        rf"`([^`\n]+\.(?:{ext_pattern}))`",
        rf"[\"'“‘]([^\"'”’\n]+\.(?:{ext_pattern}))[\"'”’]",
        rf"(?<![\w.-])([^\s`\"'<>/\\]+\.(?:{ext_pattern}))(?!\w)",
    ]:
        candidates.extend(re.findall(pattern, request, flags=re.I))

    input_names = {Path(p).name.casefold() for p in inputs}
    for candidate in candidates:
        name = Path(candidate.strip().rstrip("，。,:;；）)]}")).name
        if name.casefold() in input_names:
            continue
        if Path(name).suffix.lower().lstrip(".") in {ext.lower().lstrip(".") for ext in extensions}:
            return Path(inputs[0]).resolve().parent / name
    return None


def _strict_local_plan(request, files):
    """Match only single-purpose tasks with explicit, unambiguous parameters."""
    text = request.strip().lower()
    paths = [Path(p) for p in files]
    if not paths:
        asks_excel = any(term in text for term in ["excel", "xlsx", "表格", "工作簿"])
        asks_sample = any(term in text for term in ["dummy", "sample", "test data", "模拟", "假数据", "测试数据", "示例数据"])
        asks_inventory = any(term in text for term in ["inventory", "stock", "库存", "存货"])
        asks_creation = any(term in text for term in [
            "生成", "创建", "新建", "做一份", "做一个", "做个", "给我一份", "给我一个",
            "create", "generate", "make me", "build me",
        ])
        if asks_creation and asks_excel and asks_sample and asks_inventory:
            count = _route_number(text, [r"(\d+)\s*(?:行|rows?)"], int) or 100
            return {
                "skill": "excel-dummy",
                "args": ["--rows", str(count)],
                "stage": "生成模拟库存 Excel",
            }
        return None
    if any(not p.is_file() for p in paths):
        return None
    if any(term in text for term in [
        "翻译", "translate", "ocr", "识别文字", "水印", "watermark", "比较", "compare",
        "合并", "merge", "重命名", "rename", "整理", "organize", "总结", "summarize",
        "覆盖原文件", "原地修改", "overwrite", "in place"
    ]):
        return None

    exts = {p.suffix.lower() for p in paths}
    image_exts = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp"}
    video_exts = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v"}

    if (len(paths) == 1 and exts <= {".xls", ".xlsx", ".xlsm"}
            and any(term in text for term in ["month", "月份", "月份列"])
            and any(term in text for term in ["date", "日期"])
            and any(term in text for term in ["sheet", "工作表"])
            and any(term in text for term in ["拆", "split", "分组", "按地区", "按国家", "按区域"])):
        return {
            "skill": "excel-derive-split-sheets",
            "args": [str(paths[0]), "--date-column", "auto", "--group-column", "auto",
                     "--derived-column", "Month"],
            "stage": "生成 Month 列并按地区拆分工作表",
        }

    if exts <= image_exts and any(k in text for k in ["裁剪", "裁成", "crop"]):
        size = re.search(
            r"(?:裁剪?(?:成|为)?|crop(?:\s+to)?)\s*(\d+)\s*[x×*]\s*(\d+)\s*(?:px|像素)?",
            text, flags=re.I)
        origin = re.search(
            r"(?:从|起点(?:为|是)?|坐标(?:为|是)?|from|starting\s+at|origin(?:\s+at)?)\s*"
            r"[（(]?\s*(\d+)\s*[,，]\s*(\d+)\s*[）)]?",
            text, flags=re.I)
        if size and (origin or any(k in text for k in ["左上角", "top-left", "top left"])):
            width, height = int(size.group(1)), int(size.group(2))
            x, y = (int(origin.group(1)), int(origin.group(2))) if origin else (0, 0)
            if width > 0 and height > 0:
                return {
                    "skill": "img-resize",
                    "args": [*map(str, paths), "--crop", f"{width},{height},{x},{y}"],
                    "stage": f"从左上角坐标 ({x},{y}) 裁剪为 {width}x{height}",
                }

    if exts <= image_exts and any(k in text for k in ["转换", "转为", "转成", "convert"]):
        if any(k in text for k in ["压缩", "compress", "改尺寸", "resize", "裁剪", "crop"]):
            return None
        target = next((fmt for fmt in ["webp", "heic", "png", "jpeg", "jpg"]
                       if re.search(rf"(?:为|成|to)\s*\.?{fmt}\b|\b{fmt}\s*(?:格式|format)", text)), None)
        if target:
            args = [*map(str, paths), "--to", target]
            output = _requested_output(request, [target], paths) if len(paths) == 1 else None
            if output:
                args += ["--output", str(output)]
            return {"skill": "img-convert", "args": args,
                    "stage": "转换图片格式"}

    if exts <= {".xls", ".xlsx", ".xlsm", ".csv"} and any(k in text for k in ["转换", "转为", "转成", "convert"]):
        wants_csv = bool(re.search(r"(?:为|成|to)\s*\.?csv\b|\bcsv\s*(?:格式|format)", text))
        wants_xlsx = bool(re.search(r"(?:为|成|to)\s*\.?xlsx\b|\bxlsx\s*(?:格式|format)", text))
        if (wants_csv and exts <= {".xls", ".xlsx", ".xlsm"}) or (wants_xlsx and exts == {".csv"}):
            args = list(map(str, paths))
            output_ext = "csv" if wants_csv else "xlsx"
            output = _requested_output(request, [output_ext], paths) if len(paths) == 1 else None
            if output:
                args += ["--output", str(output)]
            return {"skill": "table-convert", "args": args,
                    "stage": "转换表格格式"}

    if len(paths) == 1 and exts == {".pdf"} and any(k in text for k in ["抽取", "提取", "拆出", "另存", "extract"]):
        match = re.search(r"第?\s*(\d+)\s*[-–—~到至]\s*(\d+)\s*页", text)
        if not match:
            match = re.search(r"pages?\s*(\d+)\s*(?:-|–|—|~|to)\s*(\d+)", text)
        if match:
            lo, hi = int(match.group(1)), int(match.group(2))
            if 1 <= lo <= hi:
                args = [str(paths[0]), "--ranges", f"{lo}-{hi}"]
                output = _requested_output(request, ["pdf"], paths)
                if output:
                    args += ["--output", str(output)]
                return {"skill": "pdf-split", "args": args,
                        "stage": f"抽取 PDF 第 {lo}-{hi} 页"}
        single = re.search(r"第\s*(\d+)\s*页", text) or re.search(r"page\s*(\d+)\b", text)
        if single and int(single.group(1)) >= 1:
            page = int(single.group(1))
            args = [str(paths[0]), "--ranges", str(page)]
            output = _requested_output(request, ["pdf"], paths)
            if output:
                args += ["--output", str(output)]
            return {"skill": "pdf-split", "args": args,
                    "stage": f"抽取 PDF 第 {page} 页"}

    if (exts <= video_exts
            and any(k in text for k in ["压缩", "压小", "压一下", "压成", "compress"])
            and not any(k in text for k in [
                "gif", "截", "剪", "trim", "转", "convert", "提取", "extract",
                "字幕", "subtitle", "帧", "frame",
                "打包", "压缩包", "归档", "加密", "zip", "archive", "密码", "password",
            ])):
        crf = _route_number(text, [r"crf\s*(\d+)"], int) or 28
        width = _route_number(
            text, [r"(?:宽|宽度)\s*(\d+)\s*(?:px|像素)?",
                   r"(?:width|wide)\s*(?:of\s*)?(\d+)\s*(?:px|pixels?)?"], int)
        if not width:
            res = _route_number(text, [r"(\d{3,4})\s*p\b"], int)
            width = {2160: 3840, 1440: 2560, 1080: 1920, 720: 1280, 480: 854, 360: 640}.get(res)
        args = [*map(str, paths), "--crf", str(crf)]
        if width:
            args += ["--width", str(width)]
        return {"skill": "av-compress", "args": args, "stage": "压缩视频"}

    if exts <= video_exts and "gif" in text:
        duration = _route_number(text, [r"前\s*(\d+(?:\.\d+)?)\s*秒", r"first\s+(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)\b"])
        if duration and duration > 0:
            width = _route_number(text, [r"(?:宽|宽度)\s*(\d+)\s*(?:px|像素)?", r"(?:width|wide)\s*(?:of\s*)?(\d+)\s*(?:px|pixels?)?"], int) or 480
            fps = _route_number(text, [r"(\d+)\s*fps", r"每秒\s*(\d+)\s*帧"], int) or 12
            args = [*map(str, paths), "--start", "0", "--duration", str(duration), "--width", str(width), "--fps", str(fps)]
            output = _requested_output(request, ["gif"], paths) if len(paths) == 1 else None
            if output:
                args += ["--output", str(output)]
            return {"skill": "av-gif", "args": args,
                    "stage": "生成 GIF"}
    return None


def cmd_local_dispatch(a):
    marker = "__FOLDERIS_LOCAL_RESULT__"
    plan = _strict_local_plan(a.request, a.files)
    if not plan:
        print(marker + json.dumps({"matched": False}, ensure_ascii=False))
        return

    roots = {Path(p).resolve().parent for p in a.files} or {Path.cwd().resolve()}
    before = {str(p.resolve()) for root in roots for p in root.iterdir() if p.is_file()}
    started = datetime.now()
    command = [sys.executable, str(Path(__file__).resolve()), plan["skill"], *plan["args"]]
    task_id = uuid.uuid4().hex
    child_env = os.environ.copy()
    child_env["FOLDERIS_TASK_ID"] = task_id
    popen_options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if IS_WIN else {"start_new_session": True}
    child = subprocess.Popen(command, cwd=os.getcwd(), stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, encoding="utf-8",
                             errors="replace", env=child_env,
                             **popen_options)

    def clean_partials():
        for partial in Path(tempfile.gettempdir()).glob(f"folderis-{task_id}-*"):
            try:
                partial.unlink()
            except OSError:
                pass

    def terminate_tree():
        if child.poll() is not None:
            return
        if IS_WIN:
            subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                           capture_output=True, text=True)
            return
        try:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait(timeout=3)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def stop_child(_signum, _frame):
        terminate_tree()
        clean_partials()
        raise SystemExit(130)

    previous_term = signal.signal(signal.SIGTERM, stop_child)
    previous_int = signal.signal(signal.SIGINT, stop_child)
    try:
        stdout, stderr = child.communicate()
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)
        clean_partials()
    after = {str(p.resolve()) for root in roots for p in root.iterdir() if p.is_file()}
    created = sorted(after - before)
    details = (stdout + stderr).strip()
    payload = {
        "matched": True,
        "success": child.returncode == 0 and bool(created),
        "skill": plan["skill"],
        "stage": plan["stage"],
        "outputs": created,
        "details": details[-2000:],
        "elapsed": round((datetime.now() - started).total_seconds(), 2),
    }
    if child.returncode == 0 and not created:
        payload["details"] = "技能没有生成新的结果文件。" + (("\n" + details) if details else "")
    print(marker + json.dumps(payload, ensure_ascii=False))


def enforce_output_policy(args):
    """Keep source files untouched unless the user explicitly authorized it."""
    allow_overwrite = getattr(args, "overwrite_original", False)

    if getattr(args, "in_place", False) and not allow_overwrite:
        die("默认会另存为新文件，不覆盖原文件。只有用户明确要求覆盖/原地修改时，才可同时传 --in-place 和 --overwrite-original。")

    if args.skill == "rename-batch" and not getattr(args, "dry_run", False) and not allow_overwrite:
        die("批量重命名会修改原文件名。请先用 --dry-run 预览；只有用户明确要求重命名原文件时，才可传 --overwrite-original。")

    if allow_overwrite:
        return

    source_values = []
    for name in ("file", "files", "file_a", "file_b", "source", "template", "data", "image", "subtitles"):
        value = getattr(args, name, None)
        if isinstance(value, (list, tuple)):
            source_values.extend(value)
        elif value:
            source_values.append(value)
    if args.skill == "excel-update-by-key" and getattr(args, "target", None):
        source_values.append(args.target)

    output = getattr(args, "output", None)
    if output and any(_same_path(output, source) for source in source_values):
        die("输出路径不能与输入文件相同；默认必须另存为新文件。只有用户明确要求覆盖原文件时，才可传 --overwrite-original。")


if __name__ == "__main__":
    args = build_parser().parse_args()
    enforce_output_policy(args)
    args.fn(args)
