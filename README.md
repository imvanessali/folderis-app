# FinderSidebar — 给真 Finder 加一个 AI 聊天侧边栏

**产品形态（方案1，主线）**：启动 App 后它常驻菜单栏，你照常用系统 Finder 打开任何文件夹，一个 AI 聊天面板自动贴靠在 Finder 窗口左侧、跟随移动和缩放。可以把 Finder 里选中的文件"附到对话"，让 AI 读取内容后回答问题。

方案2和方案3是探索期的独立文件浏览器原型，已放弃并删除（2026-07）。

## 快速开始

有两个可用的构建产物，功能核心相同，选一个用即可：

- **`FinderSidebar-Full.app`（推荐）** —— 用 Xcode 编译的完整版，额外内嵌 Finder Sync 扩展（Finder 工具栏按钮，可显示/隐藏面板）。重新构建：`xcodebuild -project FinderSidebar.xcodeproj -scheme FinderSidebarHost -configuration Release -derivedDataPath .xcbuild CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual build`
- **`FinderSidebar.app`** —— SwiftPM 编译的核心版（无扩展、无需 Xcode）。重新构建：`./build_app.sh`

```bash
cd 01-finder-sidebar
open FinderSidebar-Full.app
```

扩展如果没自动启用，可运行 `pluginkit -e use -i com.local.findersidebar.host.FinderSidebarExt`，或去 系统设置 → 隐私与安全性 → 扩展 → Finder 里勾选。

首次运行需要授权两项系统权限（都会自动弹提示，面板里也有文字引导）：

1. **辅助功能**（系统设置 → 隐私与安全性 → 辅助功能）：用于读取 Finder 窗口位置，让面板贴边跟随。不授权时面板不会跟随 Finder。
2. **自动化控制 Finder**（系统设置 → 隐私与安全性 → 自动化）：用于读取当前文件夹路径和选中的文件。

如果 Gatekeeper 拦截（"无法验证开发者"），右键 App → 打开，确认一次即可。

## macOS 可分发包

发布机准备好 Developer ID、`notary` 钥匙串凭据和完整运行时后，用一个命令同时生成 Full 与 Lite：

```bash
cd 01-finder-sidebar
RUNTIME_SRC=/path/to/release-runtime ARCH=arm64 ./make_release_matrix.sh
```

脚本会依次构建两个版本，并分别完成 App 公证/装订、DMG 公证/装订和 Gatekeeper/映像校验。最终产物和 SHA-256 清单位于 `01-finder-sidebar/dist/`。仅测试构建流程、不提交 Apple 公证时，可增加 `SKIP_NOTARIZE=1`。

## 使用

- 菜单栏有一个气泡图标：显示/隐藏面板、退出。
- 面板顶部显示 Finder 当前文件夹路径；在 Finder 里选中文件后，面板会出现"选中 N 项 → 附到对话"按钮。
- 附上的文件：≤100KB 的文本文件会把完整内容发给 AI；更大或二进制文件只发路径和大小。
- 聊天设置（右上角齿轮）：Provider 支持 Anthropic、DeepSeek、OpenAI 兼容 API，Base URL / Model 可改，**API Key 存 macOS 钥匙串**，不落明文。

## 工程结构

```
01-finder-sidebar/
├── Package.swift            # SwiftPM 构建核心 App（无需 Xcode）
├── build_app.sh             # 打包 FinderSidebar.app
├── HostApp/                 # 全部核心源码
│   ├── FinderWindowTracker  #   Accessibility API 轮询 Finder 窗口位置
│   ├── FinderContext        #   AppleScript 轮询当前文件夹 + 选中文件
│   ├── FloatingPanelController # 贴边悬浮面板（非激活式 NSPanel）
│   ├── ChatViewModel        #   聊天 + 文件附件 + 两种 API 协议
│   └── …
├── FinderExtension/         # 可选增强：Finder Sync 扩展（工具栏按钮）
├── project.yml              # XcodeGen 配置（仅扩展路线需要）
└── FinderSidebar.xcodeproj  # 已生成，含扩展 target，需完整 Xcode 编译
```

## 技术边界（PM 视角需要知道的）

- **macOS 不允许第三方把 UI 真正嵌进 Finder 窗口内部**。本方案是"两个窗口视觉贴合"：Accessibility API 以 0.35s 间隔轮询 Finder 窗口 frame，拖动 Finder 时面板有轻微跟随延迟，这是系统层面无法消除的。
- 核心 App 用 SwiftPM 构建即可，**分发给用户时用户不需要 Xcode**；正式对外分发需要 Apple Developer Program（$99/年）+ Developer ID 签名 + 公证，否则用户要手动绕过 Gatekeeper。
- `FinderExtension/`（Finder 工具栏按钮）是可选锦上添花，必须用完整 Xcode 编译嵌入，且用户要在系统设置里手动启用扩展。核心体验不依赖它。
- 当前为非流式回复（等完整回答后一次显示）；文件附件只支持文本内容，不做 OCR/解析二进制格式。

## 功能现状

- ✅ **文件与编码代理模式（类 Claude Code）**：当前 Finder 文件夹即工作目录。AI 拥有 10 个工具——`list_files` / `search_files`（正则全文搜索，跳过 node_modules/.git 等）/ `read_file` / `edit_file`（精确字符串替换，要求唯一匹配，修改文件的首选方式）/ `write_file` / `move_file` / `copy_file` / `trash_file` / `make_directory` / `run_command`，可自主多轮循环（上限 40 轮）完成搜索、读写、精确编辑、批量重命名、运行脚本、git、构建等任务；工具活动实时显示，**发送按钮在 agent 工作时变为停止按钮，随时可中断**。两种 Provider（Anthropic tool use / OpenAI function calling）都支持流式工具调用，代理循环、文件操作、编辑/搜索与 shell 执行均有独立测试覆盖。
- ✅ **命令执行确认机制（对齐 Claude Code）**：AI 每次想执行 shell 命令，面板会弹出橙色确认卡（显示完整命令 + 目的说明），你点"允许执行"或"拒绝"后代理才继续；命令以 zsh 在工作目录执行，输出上限 50KB、超时 120 秒强制终止；拒绝会如实回传给 AI 并要求它尊重决定。文件工具的路径仍锁死在绑定文件夹内；`trash_file` 只进废纸篓不做永久删除。注意：shell 命令本身不受文件夹沙箱限制（与 Claude Code 一致），确认卡就是安全闸门，看清命令再点允许。
- ✅ **DeepSeek 支持**：Provider 里直接选 DeepSeek，自动配好 `api.deepseek.com` + `deepseek-chat`，走 OpenAI 兼容协议，完整支持工具调用与代理循环。
- ✅ **自动压缩上下文**：会话字符数超过阈值时，自动把较早的对话调用模型摘要成要点、只保留最近若干轮，长会话不再撑爆上下文；压缩时对话流会显示"🗜️ 已压缩较早的对话"。
- ✅ **子代理**：AI 可用 `spawn_subagent` 把自包含的子任务外包给独立子代理（拥有独立上下文和文件工具，但不能执行命令或再派生子代理），只把结论回传，主上下文保持精简；子代理循环与 DeepSeek 路由已用 mock 端到端验证。
- ✅ 会话与文件夹绑定（每个 Finder 文件夹一份独立聊天记录，切换文件夹自动切换；流式回复中切走会安全取消）
- ✅ AI 在当前文件夹创建文件（工具直写为主；`create-file` 卡片作为工具不可用时的后备，支持子目录，拒绝 `../` 路径穿越）

- ✅ 流式输出（回答逐字显示，SSE 双协议解析已用本地 mock 服务器验证）
- ✅ 会话历史持久化（存于 `~/Library/Application Support/FinderSidebar/history.json`，纯文本，不含图片；菜单栏可"清空对话"）
- ✅ 图片视觉理解（jpg/png/gif/webp 直发，heic/tiff/bmp 自动转 JPEG；超过 API 5MB 上限的自动降分辨率压缩，用户无感）
- ✅ Finder 选中自动附到对话（手动移除的芯片在选中变化前不会被加回）
- ✅ 原生窗口镀铬（真实标题栏 + NSToolbar，圆角/阴影/高度与 Finder 由同一套系统渲染保证一致）
- ✅ 附件处理在后台线程（大图不卡 UI）
- ✅ 稳定开发者签名（重编译不再丢辅助功能授权）

## 已知待办

- 面板贴左/贴右可配置；多显示器边缘处理
- Markdown 渲染（当前纯文本显示回答）
