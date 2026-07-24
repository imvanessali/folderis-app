Folderis Windows QA 工具包
==========================
前置：已安装最新 Folderis-Setup.exe 并完成运行时安装（ffmpeg 也装好）。

步骤：
1. 把 test-fixtures 里的 7 个 "Test *" 素材文件夹复制成一个测试副本目录
   （例如 C:\Users\你\Downloads\Test Folderis）。不要直接在母本上测。
2. PowerShell 运行：
   python run_qa_windows.py "C:\Users\你\Downloads\Test Folderis"
   （脚本定位安装目录里的 runtime，缺失时才按 App 规则回退，并打印所用 skills.py 的哈希）
3. 结束后把 qa-windows-results.json 发回（尤其有 FAIL 时）。

说明：
- 转写/抠图/分卷等重组件如未安装会 FAIL 并提示 install-component，属预期；
  想全绿可先在面板里让 AI 装齐组件再跑。
- W-12 依赖本机装有 Word 或 WPS。
