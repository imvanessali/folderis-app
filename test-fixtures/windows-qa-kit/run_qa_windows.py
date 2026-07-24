#!/usr/bin/env python3
"""Folderis Windows 技能 QA（真机执行）。

关键：按 App 的真实解析顺序找运行时——
  1) 安装目录 %LOCALAPPDATA%\Programs\Folderis*\runtime\（exe 旁,每次安装都是新的）
  2) 兜底 %LOCALAPPDATA%\Sider\（仅当上者缺失,与 SkillRunner.ActiveRuntimeRoot 一致）
用法（PowerShell）:
  python run_qa_windows.py "C:\\path\\to\\Test Folderis副本"
"""
import argparse, json, os, subprocess, sys, time, hashlib
from pathlib import Path

def parse_args():
    parser = argparse.ArgumentParser(description="Folderis Windows 技能 QA")
    parser.add_argument("work", nargs="?", default=str(Path.home() / "Downloads" / "Test Folderis"))
    return parser.parse_args()

def find_runtime():
    local = Path(os.environ["LOCALAPPDATA"])
    candidates = [local / "Programs" / "Folderis" / "runtime"]
    candidates.append(local / "Sider")  # 兜底,顺序与 SkillRunner 一致
    for root in candidates:
        py = root / "python" / "python.exe"
        sk = root / "skills" / "skills.py"
        if py.exists() and sk.exists():
            return py, sk, root
    sys.exit("找不到技能运行时。先装 Folderis 并让它完成运行时安装,或确认安装目录。")

ARGS = parse_args()
PY, SKILLS, ROOT = find_runtime()
print(f"运行时: {ROOT}")
print(f"skills.py sha256: {hashlib.sha256(SKILLS.read_bytes()).hexdigest()}")

WORK = Path(ARGS.work)
MARK = "__FOLDERIS_LOCAL_RESULT__"
results = []

def run(id_, instr, cwd, args, expect_output=None):
    t0 = time.time()
    try:
        r = subprocess.run([str(PY), str(SKILLS)] + args, cwd=str(cwd),
                           capture_output=True, text=True, timeout=180, encoding="utf-8", errors="replace")
        out = (r.stdout or "") + (r.stderr or "")
        ok = r.returncode == 0 and (expect_output is None or (Path(cwd)/expect_output).exists())
        st = "PASS" if ok else "FAIL"
        note = out.strip()[-250:]
    except subprocess.TimeoutExpired:
        st, note = "FAIL", "超时"
    results.append(dict(id=id_, instr=instr, status=st, elapsed=round(time.time()-t0,2), note=note))
    print(f"[{st}] {id_} {instr}")

def dispatch(id_, instr, cwd, request, files, expect_matched):
    r = subprocess.run([str(PY), str(SKILLS), "local-dispatch", "--request", request, "--files", *files],
                       cwd=str(cwd), capture_output=True, text=True, timeout=180,
                       encoding="utf-8", errors="replace")
    try:
        p = json.loads(r.stdout.split(MARK,1)[1])
        ok = p.get("matched") == expect_matched and (not expect_matched or p.get("success"))
    except Exception:
        ok, p = False, {"raw": r.stdout[-200:]}
    st = "PASS" if ok else "FAIL"
    results.append(dict(id=id_, instr=instr, status=st, note=json.dumps(p, ensure_ascii=False)[:250]))
    print(f"[{st}] {id_} {instr}")

IMG = WORK/"Test Image"; XLS = WORK/"Test Excel"; PDF = WORK/"Test PDF"
VID = WORK/"Test Video"; DOC = WORK/"Test Docs"; AUD = WORK/"Test Audio"; OTH = WORK/"Test Misc"
JPG = "michail-sapiton-alCEnNmzhPE-unsplash.jpg"
PNG = "marko-brecic-Z9P2g8TuTdA-unsplash.png"
MP4 = "file_example_MP4_1280_10MG.mp4"

# local-dispatch 五正五负
dispatch("LD-01","本地裁剪", IMG, "从（100，50）开始裁剪成800×600px", [JPG], True)
dispatch("LD-02","本地转webp", IMG, "把这张图转成 webp", [JPG], True)
dispatch("LD-03","本地xlsx转csv", XLS, "转换为 csv 格式", ["样例数据.xlsx"], True)
dispatch("LD-04","本地PDF抽页", PDF, "抽取第2-5页另存", ["ai_agents_handbook.pdf"], True)
dispatch("LD-05","本地转gif", VID, "把前5秒做成 gif，宽480", [MP4], True)
dispatch("LD-06","模糊拒接", IMG, "处理一下这张图", [JPG], False)
dispatch("LD-07","水印拒接", IMG, "加个水印再裁剪成800×600", [JPG], False)
dispatch("LD-08","缺参拒接", IMG, "帮我裁剪一下", [JPG], False)
dispatch("LD-09","覆盖拒接", IMG, "转成webp并覆盖原文件", [JPG], False)
dispatch("LD-10","混合拒接", IMG, "转成webp顺便压缩一下", [JPG], False)
dispatch("LD-11","本地视频压缩", VID, "压缩这个视频", [MP4], True)
dispatch("LD-12","视频打包拒接", VID, "把这个视频打包压缩", [MP4], False)

# 跨平台技能回归（Windows 可用集）
run("W-01","水印", IMG, ["img-watermark", JPG, "--text","(c) 2026","--position","br"])
run("W-02","旋转", IMG, ["img-rotate", JPG, "--angle","90"])
run("W-03","JPG压缩", IMG, ["jpg-compress", JPG])
run("W-04","转PNG", IMG, ["img-convert", JPG, "--to","png"])
run("W-05","改宽1920", IMG, ["img-resize", JPG, "--width","1920"])
run("W-06","系统OCR", IMG, ["img-ocr", JPG])
run("W-07","拼长图", IMG, ["img-stitch", JPG, JPG, "--direction","vertical","--output","stitched.jpg"], "stitched.jpg")
run("W-08","crop W,H,X,Y", IMG, ["img-resize", JPG, "--crop","800,600,100,50"])
run("W-09","切3段", IMG, ["img-split", JPG, "--parts","3"])
run("W-10","生成ico", IMG, ["img-to-ico", PNG])
run("W-11","docx合并", DOC, ["merge-docs","采购合同A.docx","采购合同B.docx","--output","合并.docx"], "合并.docx")
run("W-12","docx转PDF(Word/WPS)", DOC, ["pdf-convert","--file","采购合同A.docx","--to","pdf"], "采购合同A.pdf")
run("W-13","txt清理", DOC, ["txt-clean","待清理.txt","--trim","--collapse-blank","--in-place","--overwrite-original"])
run("W-14","GBK转UTF8", DOC, ["encoding-convert","销售说明_gbk.txt","--source","gbk","--target","utf-8"])
run("W-15","txt切分", DOC, ["txt-split","长日志.txt","--lines","1000"])
run("W-16","模板填充", DOC, ["docx-fill","聘书模板.docx","名单.xlsx"])
run("W-17","PDF合并", PDF, ["pdf-merge","ai_agents_handbook_pages_2-5.pdf","ai_agents_handbook_pages_2-5-v1.1.pdf","--output","merged.pdf"], "merged.pdf")
run("W-18","PDF压缩", PDF, ["pdf-compress","ai_agents_handbook.pdf"])
run("W-19","PDF加密", PDF, ["pdf-crypt","encrypt","ai_agents_handbook_pages_2-5.pdf","--new-password","abc123","--output","加密.pdf"], "加密.pdf")
run("W-20","PDF解密", PDF, ["pdf-crypt","decrypt","加密.pdf","--password","abc123","--output","解密.pdf"], "解密.pdf")
run("W-21","每页拆分", PDF, ["pdf-split","ai_agents_handbook_pages_2-5.pdf"])
run("W-22","重排3,1,2", PDF, ["pdf-reorder","ai_agents_handbook_pages_2-5.pdf","3,1,2","--output","reordered.pdf"], "reordered.pdf")
run("W-23","PDF转txt", PDF, ["pdf-convert","--file","ai_agents_handbook_pages_2-5.pdf","--to","txt"])
run("W-24","PDF转图", PDF, ["pdf-convert","--file","ai_agents_handbook_pages_2-5.pdf","--to","png","--pages","all"])
run("W-25","PDF水印", PDF, ["pdf-watermark","ai_agents_handbook_pages_2-5.pdf","--text","机密"])
run("W-26","PDF盖章", PDF, ["pdf-stamp","ai_agents_handbook_pages_2-5.pdf","--image",str((OTH/"印章.png").resolve()),"--page","last","--position","br"])
run("W-27","xlsx转csv", XLS, ["table-convert","样例数据.xlsx"])
run("W-28","工作表拆分", XLS, ["excel-split","Free_Test_Data_1MB_XLSX.xlsx"])
run("W-29","按列去重", XLS, ["excel-dedupe","样例数据.xlsx","--columns","2"])
run("W-30","两表对比", XLS, ["excel-diff","星辰科技_2025年上半年财务数据.xlsx","星辰科技_2025年下半年财务数据.xlsx"])
run("W-31","列拆分", XLS, ["excel-transform","待拆分示例.xlsx","--split-column","1","--delimiter","-"])
run("W-32","分组求和", XLS, ["excel-groupby","样例数据.xlsx","--by","5","--agg","sum","--value","6"])
run("W-33","同比更新", XLS, ["excel-update-by-key","--source","星辰科技_2025年下半年财务数据.xlsx","--target","星辰科技_2025年上半年财务数据.xlsx","--key","1","--output","同比.xlsx"], "同比.xlsx")
run("W-34","CSV预览", XLS, ["csv-preview","file_example_XLS_100.csv"])
run("W-35","按列拆文件", XLS, ["excel-split-column","样例数据.xlsx","--by","5"])
run("W-36","模糊匹配", XLS, ["excel-fuzzy-merge","样例数据.xlsx","样例数据.xlsx","--key","1"])
run("W-37","提取信息", XLS, ["extract-patterns","待提取示例.xlsx","--type","email","--context","分公司"])
run("W-38","视频转码", VID, ["av-convert",MP4,"--to","mkv"])
run("W-39","提音轨", VID, ["av-extract-audio",MP4,"--to","mp3"])
run("W-40","截帧", VID, ["av-frames",MP4,"--every","10"])
run("W-41","转GIF", VID, ["av-gif",MP4,"--width","480","--duration","5"])
run("W-42","音频转m4a", AUD, ["audio-convert","clip_a.wav","--to","m4a"])
run("W-43","音频拼接", AUD, ["audio-concat","clip_a.wav","clip_b.wav","--output","joined.wav"], "joined.wav")
run("W-44","清单Excel", IMG, ["dir-inventory",".","--output",str((OTH/"清单.xlsx").resolve())])
run("W-45","MD5查重", IMG, ["hash-files",JPG,PNG,"--algo","md5"])
run("W-46","AES加密打包", OTH, ["zip-encrypt",str((IMG/JPG).resolve()),"--password","abc123","--output","enc.zip"], "enc.zip")
run("W-47","二维码生成", OTH, ["qr-make","https://folderis.app","--output","qr.png"], "qr.png")
run("W-48","二维码识别", OTH, ["qr-read","qr.png"])
run("W-49","转Markdown", OTH, ["doc-to-markdown",str((XLS/"样例数据.xlsx").resolve())])
run("W-50","doc-diff", PDF, ["doc-diff","ai_agents_handbook_pages_2-5.pdf","ai_agents_handbook_pages_2-5-v1.1.pdf"])

p = sum(1 for r in results if r["status"]=="PASS")
f = len(results) - p
print(f"\n通过 {p} / 失败 {f} / 合计 {len(results)}")
report = Path(__file__).parent / "qa-windows-results.json"
report.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"结果已写入 {report}（失败项请把此文件发回）")
