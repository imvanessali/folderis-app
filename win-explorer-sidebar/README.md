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

## 自动更新（NetSparkleUpdater）

> 状态：代码与发版脚本完成，**待 Windows 真机冒烟**（静默下载、`/S` 安装、
> 装完自动重启这三步在 macOS 上无法验证）。

机制（与 macOS 端 Sparkle 2 同一套约定）：

| 环节 | 实现 |
|---|---|
| feed | `https://dl.folderis.app/win/appcast.xml`（`FOLDERIS_APPCAST_URL` 可覆盖） |
| 签名 | Ed25519，`SecurityMode.Strict`；appcast 与安装器都必须验签通过 |
| 检查 | 启动后 20 秒开始，之后每 24 小时一次，全程静默 |
| 下载 | 发现新版立即后台下载，用户无感 |
| 提示 | 下载就绪后面板顶部出温和横幅「新版本 X 已就绪，重启生效」，中英双语；**AI 正在回复/跑工具循环时挂起不显示**，空闲后再出现；「稍后」收起本次运行的横幅，下次启动仍会提示 |
| 安装 | 用户点「立即重启」才装：`Folderis-Setup-<版本>.exe /S`（NSIS 静默，零 UI） |
| 重启 | 由 NetSparkle 生成的批处理负责（`RelaunchAfterUpdate=true`），安装器不做重启 |

绝不弹模态对话框：NetSparkle 的界面包（`NetSparkleUpdater.UI.*`）没有引入，
`UIFactory` 为 `null`，所有提示都走自研横幅。更新日志落
`%LOCALAPPDATA%\Sider\update.log`。

### 1. 生成并备份密钥（只做一次）

```bash
dotnet tool install -g NetSparkleUpdater.Tools.AppCastGenerator --version 2.5.0
export FOLDERIS_NETSPARKLE_KEYS="$HOME/.folderis-release/netsparkle"   # 默认值
netsparkle-generate-appcast --generate-keys --key-path "$FOLDERIS_NETSPARKLE_KEYS"
netsparkle-generate-appcast --export --key-path "$FOLDERIS_NETSPARKLE_KEYS"  # 打印公钥
```

`NetSparkle_Ed25519.priv` **必须离线备份**（1Password / 加密 U 盘）：私钥丢失后
已装机的老版本再也无法收到能通过验签的更新，只能引导用户手动重装。私钥永远不进仓库。

### 2. 把公钥内置进应用

把上一步导出的公钥（base64 单行）填进 `src/Sider/UpdaterService.cs`：

```csharp
public const string PublicKey = "REPLACE_WITH_ED25519_PUBLIC_KEY";   // ← 换成真实公钥
```

占位符状态下更新器**整体禁用**并写日志，绝不会降级成「不校验签名」。
`build_release.sh` 生成 appcast 前会校验这个常量与密钥目录里的 `.pub` 是否配对，
不配对就按缺失处理（发出去的更新会被客户端拒绝，不如不发）。

### 3. 发版产出 appcast

```bash
export FOLDERIS_APP_VERSION=1.2.0        # 版本单一来源：注入 csproj 与 NSIS
export FOLDERIS_APPCAST_REQUIRE=1        # 正式发布：产不出 appcast 直接失败
./win-explorer-sidebar/build_release.sh
```

`FOLDERIS_APPCAST_REQUIRE=1` 时**必须显式给 `FOLDERIS_APP_VERSION`**：沿用默认值 1.1.0
会打出一个与线上同版本号的包，appcast 照样生成，但所有客户端都判定「无更新」，
发了等于没发。非 require 模式下沿用默认值只会打印警告。
构建号（设置页显示，不参与更新比对）来自 `FOLDERIS_BUILD_VERSION`，默认按当天日期生成。

产物（`dist/`）：

- `Folderis-Setup-1.2.0.exe` → 上传到 `https://dl.folderis.app/win/Folderis-Setup-1.2.0.exe`
- `appcast.xml` + `appcast.xml.signature` → 上传到 `https://dl.folderis.app/win/`
- `Folderis-Setup.exe`（同一个文件的不带版本号副本，QA 脚本沿用老名字）

`appcast.xml.signature` 必须一起上传：客户端在 Strict 模式下会先下载它验 appcast，
缺了就整条 feed 作废。工具或密钥缺失时脚本默认打印醒目警告后跳过（和 Authenticode
签名一个风格），`FOLDERIS_APPCAST_REQUIRE=1` 时直接失败。回退的 .NET 安装器
（`INSTALLER_MODE=dotnet`）一定会弹窗、不能无人值守安装，此时脚本不产 appcast。

其他环境变量：`FOLDERIS_UPDATE_BASE_URL`（默认 `https://dl.folderis.app`）、
`FOLDERIS_NETSPARKLE_KEYS`、`FOLDERIS_APPCAST_PUBKEY_CHECK=0`（本地测试用测试密钥时跳过配对校验）。

### 4. 本地测试（伪造 appcast）

```bash
# ① 测试密钥（别用发布密钥）
netsparkle-generate-appcast --generate-keys --key-path /tmp/nskeys
netsparkle-generate-appcast --export --key-path /tmp/nskeys      # 记下公钥

# ② 造一个“新版本”，feed 指向本机
FOLDERIS_APP_VERSION=9.9.9 FOLDERIS_NETSPARKLE_KEYS=/tmp/nskeys \
FOLDERIS_UPDATE_BASE_URL=http://192.168.x.x:8000 FOLDERIS_APPCAST_PUBKEY_CHECK=0 \
  ./win-explorer-sidebar/build_release.sh

# ③ 起静态服务器（目录结构必须有 win/）
mkdir -p /tmp/feed/win
cp win-explorer-sidebar/dist/appcast.xml* win-explorer-sidebar/dist/Folderis-Setup-9.9.9.exe /tmp/feed/win/
(cd /tmp/feed && python3 -m http.server 8000)
```

Windows 真机上跑**旧版本**，用环境变量指到这个假 feed：

```cmd
set FOLDERIS_APPCAST_URL=http://192.168.x.x:8000/win/appcast.xml
set FOLDERIS_NETSPARKLE_PUBKEY=<② 里的测试公钥>
Folderis.exe
```

`FOLDERIS_NETSPARKLE_PUBKEY` 只是换一把公钥，**验签仍是 Strict**。
观察 `%LOCALAPPDATA%\Sider\update.log`：应看到「发现新版本 9.9.9 → 已下载并验签通过」，
面板顶部随后出现横幅；点「立即重启」后应用退出、静默装完自动拉起新版本。

### 5. 回滚（有边界，先看清楚再用）

把 `appcast.xml`（连同 `.signature`）重新生成成指向上一个版本的安装器再上传。
**它只对「还没下载到坏版本」的客户端有效**，分三种情况：

| 客户端状态 | 回滚后的实际行为 |
|---|---|
| 还没检查到坏版本 | ✅ 看到的是旧版本，且旧版本 ≤ 本机版本 → 判定无更新，不再提示 |
| 已下载、横幅还挂着没点 | ❌ 横幅不会消失，点「立即重启」照装坏版本——更新器一旦进入「就绪」状态就不再检查 feed（避免装到一半换包）。只有用户重启应用后才会重新按新 feed 检查 |
| 已经装上坏版本 | ❌ 回滚救不回来。必须发一版版本号继续往上走的修复版（例：1.2.0 坏 → 发 1.2.1，内容可以是 1.1.0 的代码） |

所以回滚是止血、不是撤回：能拦住尚未升级的大多数人，拦不住已经升上去的。
发版前务必先在真机把「静默下载 → 横幅 → 立即重启 → 装完自动拉起」跑一遍。

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
| 自动更新（无感升级） | ✅ 代码完成 | NetSparkle 2.3.0 + Ed25519 Strict；待真机冒烟 |
