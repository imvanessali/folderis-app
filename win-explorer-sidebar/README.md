# Sider（Windows 版）

FinderSidebar 的 Windows 姊妹项目：AI 面板贴靠资源管理器右缘，选中即上下文，
复用与 macOS 版**完全相同**的 Python 技能库。

> 状态：**可编译骨架**（在 macOS 上经 `dotnet build` 交叉编译验证 0 错误），
> 尚未在 Windows 真机运行过。核心风险点（Explorer COM 追踪、贴靠）代码已完成，
> 待真机验证。

## 架构

```
MainPanel (WPF)          聊天面板：气泡流 / 输入条 / 设置
 ├─ ExplorerTracker      Shell.Application COM → 窗口、当前目录、选中项（正式接口，无轮询 hack）
 ├─ PanelDocker          Win32 SetWindowPos 贴靠跟随（骨架为 150ms 轮询，正式版换 SetWinEventHook）
 ├─ AgentClient          OpenAI 兼容 SSE 流式 + 工具循环（run_skill 单入口）
 ├─ SkillRunner          spawn python skills.py —— 与 macOS 版同一份工具箱
 └─ Settings             API Key 用 DPAPI 加密落盘（等价 macOS 钥匙串）
```

## 在 Windows 上构建运行

1. 装 [.NET 8 SDK](https://dotnet.microsoft.com/download)
2. `dotnet run --project src/Sider`
3. 技能运行时放到 `%LOCALAPPDATA%\Sider\`：
   - `python\`：[Windows 嵌入式 Python 3.12](https://www.python.org/downloads/windows/)（embeddable 包）+ pip 装 `pypdf openpyxl Pillow chardet python-docx`
   - `skills\`：拷贝 macOS 仓库 `01-finder-sidebar/skills/` 下的 `skills.py` 与 `catalog.txt`
   - `bin\`：win 版 [ffmpeg](https://www.gyan.dev/ffmpeg/builds/)、[pngquant](https://pngquant.org/)

## 在 macOS 上交叉编译

交叉编译会检查 Windows/WPF 代码能否通过编译，但不能在 macOS 上运行或验证界面、
Explorer 集成和 DPAPI。发布前仍需在 Windows 真机冒烟测试。

```bash
./win-explorer-sidebar/install_mac_cross_sdk.sh
./win-explorer-sidebar/build_on_mac.sh
```

安装脚本从 Microsoft 下载固定版本并校验 SHA-512，然后解包到
`~/.dotnet-folderis`；不需要 sudo，也不会覆盖已有的 `~/.dotnet`。构建脚本会依次
编译 Folderis Full 和 Lite。GitHub Actions 的 `Windows Build` 工作流会在真实
`windows-latest` runner 上执行同样的双变体编译门禁。

## 移植状态表

| 能力 | 状态 | 备注 |
|---|---|---|
| Explorer 窗口/目录/选中追踪 | ✅ 代码完成 | Shell.Application COM，待真机验证 |
| 面板贴靠跟随 | ✅ 骨架完成 | 轮询版；正式版换 SetWinEventHook 事件驱动 |
| 流式聊天（OpenAI/DeepSeek） | ✅ 完成 | SSE + 工具循环 |
| 技能库（49 个） | ✅ 直接复用 | 纯 Python 部分全兼容；macOS 专属组件见下 |
| run_skill 工具入口 | ✅ 完成 | function calling |
| Anthropic 协议 | ⬜ 待移植 | 照 macOS 版 buildRequest 翻译 |
| 文件工具组（read/edit/write…） | ⬜ 待移植 | macOS ChatViewModel 逐一翻译 |
| OCR | ⬜ 需替换 | Vision → Windows.Media.Ocr |
| 录音转文字 | ✅ | SenseVoiceSmall Q8 原生离线识别（首次按需安装约 260MB） |
| 抠图/PDF渲染/doc2pdf | ⬜ 需替换 | Vision/PDFKit/AppKit → win 等价方案（doc2pdf 可走 Word COM/LibreOffice） |
| 会话按目录绑定 / 历史列表 | ⬜ 待移植 | 逻辑照抄 macOS 版 |
| 命令确认卡 / 审批模式 | ⬜ 待移植 | |
| 打包（MSIX/Inno Setup） | ⬜ 未开始 | |
