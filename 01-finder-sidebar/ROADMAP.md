# Folderis Roadmap

## P0 · 当前版本收尾（进行中）
- [x] 公证发布管线（构建→签名→DMG→公证→装订）
- [ ] 首次公证通过，产出可分发 DMG（Apple 审核中）
- [ ] 朋友圈小范围试用，收集一轮反馈

## P1 · Claude Code / Codex / Cursor 后端模式 ✅ 已实现（2026-07-23，三平台代码就绪）
**一句话**：面板的"大脑"可切换——内置 API（现状）/ 本机 Claude Code / 本机 Codex / 本机 Cursor Agent，开发者直接复用自己的订阅额度。

- 后端适配器抽象：`send(上下文, cwd, 流式回调, 权限回调)`；设置页增加"大脑"选择，检测本机 `claude`/`codex`/`cursor-agent` 可用性
- Claude Code 适配：`claude -p --output-format stream-json`，cwd=绑定文件夹；技能目录经 `--append-system-prompt` 注入；确认卡桥接其权限机制
- Codex 适配：`codex exec` + JSON 输出，同构复用适配层
- Cursor 适配：`cursor-agent -p --output-format stream-json`，支持登录态订阅、流式输出与会话续聊
- **验收标准（灵魂功能）：会话双向互通**
  - [x] 面板发起的任务 = Claude Code 该文件夹项目下的正式会话，终端 `claude --resume` 可见可续（真实 CLI + cwd 天然达成；面板侧持久化 session_id 续聊）
  - [x] 终端里开始的会话，面板历史列表可见可续（历史页新增"Claude Code 终端会话"区，点开导入气泡流并经官方 --resume 续聊；解析失败静默降级）
  - 会话映射只走官方接口（session_id / resume），不依赖解析内部存档格式
- 风险：订阅条款对程序化驱动的表述需在动工时复核；CLI 接口版本容错

## P2 · Intel Mac 支持
- 主程序与 Swift 组件：编双架构合成 universal（swiftc 双 target + lipo）
- ffmpeg/ffprobe：x86_64 版另取（martin-riedl/evermeet 均有），pngquant 已是 universal
- Python 运行时：python-build-standalone 有 x86_64 版；依赖用 `pip download --platform macosx_x86_64 --only-binary :all:` 拉取（无需 Rosetta 即可打包）
- 分发形态：**双 DMG**（Apple Silicon / Intel 各一），`make_release.sh` 加 ARCH 参数
- 风险：本机无 Intel 环境，需 Rosetta 冒烟或找 Intel 机器实测

## P3 · Windows 版（待 macOS 验证 PMF 后立项）
- 定性：**姊妹产品而非移植**，UI 层全部重写；核心概念（贴靠面板/选中即上下文/技能库/代理循环）完整移植
- 关键可行性（比 macOS 还顺）：`IShellWindows`/`IFolderView2` COM 接口可直接拿到资源管理器窗口、当前目录、**选中项**——不需要 AppleScript 这类轮询 hack
- 技术选型倾向：原生 C#/WinUI3（产品灵魂是原生感）；技能层 Python 工具箱可直接复用（Windows 嵌入式 Python + win 版 ffmpeg/pngquant；OCR→Windows.Media.Ocr；转写→whisper.cpp）
- 估算：3-6 周级，独立排期

## Backlog
- MCP 生态接入（后端模式落地后天然获得）
- git 感知安全网（自动建分支再动手）
- Intel/Windows 之后：Linux 文件管理器适配探索
