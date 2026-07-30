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
`~/.dotnet-folderis`；不需要 sudo，也不会覆盖已有的 `~/.dotnet`。GitHub Actions
的 `Windows Build` 工作流会在真实 `windows-latest` runner 上执行同样的编译门禁。

## 发布签名（Authenticode）

未签名的安装器和应用会触发 Unknown Publisher / SmartScreen 警告（2026-07-23 QA D3）。
`build_release.sh` 支持在 macOS 上用 [osslsigncode](https://github.com/mtrojnar/osslsigncode)
（`brew install osslsigncode`）对内部 `Folderis.exe` 及安装器签名：

```bash
export FOLDERIS_SIGN_PFX=/path/to/codesign.pfx     # 代码签名证书
export FOLDERIS_SIGN_PASSWORD=…                     # 证书密码（可选）
export FOLDERIS_SIGN_REQUIRE=1                      # 正式发布：缺证书直接失败
./win-explorer-sidebar/build_release.sh
```

时间戳服务器默认 `http://timestamp.digicert.com`，可用
`FOLDERIS_SIGN_TIMESTAMP_URL` 覆盖。未设置证书时脚本会构建成功但在结尾输出
显著的未签名警告。

## 版本公告（更新提示）

> 产品决策(2026-07-30):砍掉 NetSparkleUpdater 静默下载安装方案,
> 改用与 macOS 端同一条轻量公告通道。原因:静默安装链路需要 R2/域名/
> 签名密钥/真机冒烟一整套基建,而公告横幅零基建、发布者完全可控。

机制(与 macOS 端 `AnnouncementManager` 同一套约定与 JSON 格式):

- 启动 20 秒后(此后每 24h)拉取
  `https://folderis-announce.folderis.workers.dev/announce.json`
  (`FOLDERIS_ANNOUNCE_URL` 环境变量可覆盖,测试用);
- `win.version` 比装机构建号(`ProductInfo.Build`,如 20260727.4;本地 dev 构建按 0 处理)新 → 面板顶部横幅
  「新版本 X 已发布 → 前往下载」,点击用默认浏览器打开 `win.url`;
- 「稍后」把版本号记进 `%LOCALAPPDATA%\Sider\announce.dismissed`,
  该版本内(含重启)不再提醒,下发更新的版本号后重新亮起;
- 不下载、不安装、无签名验签;AI 回复期间横幅自动挂起,空闲再出现;
- 断网/JSON 坏了/公告撤回:静默,不打扰用户;日志落
  `%LOCALAPPDATA%\Sider\announce.log`。

实现:`src/Sider/AnnouncementService.cs` + `MainPanel` 顶部横幅。
下发/撤回公告的操作见仓库根 README「版本公告」一节(`publish_notice.sh`)。

### 本地测试(伪造公告)

```bash
cd /tmp && mkdir -p fake && cat > fake/announce.json <<'JSON'
{ "win": { "version": "99999999.9", "url": "https://example.com" } }
JSON
python3 -m http.server 8900 --directory fake &
FOLDERIS_ANNOUNCE_URL=http://localhost:8900/announce.json Folderis.exe
```

约 20 秒后应出现横幅;点「前往下载」开浏览器;点「稍后」后重启不再提示,
把 version 再调大一档会重新亮起。

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
| 版本公告（更新提示） | ✅ 完成 | announce.json 轮询 + 横幅引导网页下载；与 mac 同通道 |
