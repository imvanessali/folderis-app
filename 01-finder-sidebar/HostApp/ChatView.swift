import SwiftUI
import AppKit

struct ChatView: View {
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        // 标题和设置按钮在窗口自己的原生工具栏里（FloatingPanelController）；
        // 这里只负责内容区。设置页做成内嵌切换，不用 sheet（悬浮面板上
        // sheet 行为不可靠）。
        if chat.showSettings {
            SettingsView(onDone: { chat.showSettings = false })
        } else if chat.showHistory {
            HistoryListView(chat: chat)
        } else {
            chatBody
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(chat.messages) { message in
                                MessageBubble(message: message, folder: chat.boundFolder)
                                    .id(message.id)
                            }
                            // 忙碌行只出现在运行中任务所在的会话里。
                            if chat.isViewingRunningTask {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        // 只显示"在做事"的感觉，不铺陈每一步细节。
                                        Text(statusText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    // 运行中的子代理：数量、轮次、当前动作一目了然。
                                    ForEach(chat.subagents) { agent in
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.triangle.branch")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(L("子代理 · 第\(agent.round)轮 · \(agent.lastAction)", "Subagent · round \(agent.round) · \(agent.lastAction)"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.leading, 18)
                                        .help(agent.task)
                                    }
                                }
                                .id("loading-row")
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("chat-bottom")
                        }
                        .padding()
                    }

                    if chat.messages.isEmpty && !chat.isViewingRunningTask {
                        GeometryReader { geometry in
                            EmptyStateView(availableHeight: geometry.size.height)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .clipped()
                // 会话切换不硬切：旧内容先淡出露出白底，新内容再淡入（渐白过渡）。
                .id(chat.conversationID)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.1)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))
                ))
                .animation(.default, value: chat.conversationID)
                // .id 切换会重建滚动视图：新会话出现时直接定位到底部（最新消息）。
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: chat.messages.count) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: chat.isSending) { sending in
                    guard sending else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }

            if let error = chat.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            // Claude Code 式命令确认卡：AI 请求执行 shell 命令时挂起等待。
            // 只在查看任务会话时显示；切走时任务停在审批上，切回可继续决策。
            if chat.isViewingRunningTask, let pending = chat.pendingCommand {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.orange)
                        Text(L("AI 请求执行命令", "AI wants to run a command"))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    if let purpose = pending.purpose, !purpose.isEmpty {
                        Text(purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(pending.command)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    HStack {
                        Spacer()
                        Button(L("拒绝", "Deny")) {
                            chat.decidePendingCommand(allow: false)
                        }
                        Button(L("允许执行", "Allow")) {
                            chat.decidePendingCommand(allow: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            // 苹果“信息”App 风格的聊天输入条：圆角胶囊 + 内嵌圆形发送按钮。
            // 回车发送，Option+回车换行。
            HStack(alignment: .center, spacing: 6) {
                TextField(chat.isSending && !chat.isViewingRunningTask
                              ? L("另一个对话的任务进行中，完成后可发送…", "A task is running in another chat…")
                              : L("描述操作…", "Describe a task…"),
                          text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(2...8)
                    .padding(.leading, 14)
                    .padding(.vertical, 12)
                    .onSubmit { chat.send() }

                // 空闲时是发送按钮；查看运行中任务的会话时变成停止按钮
                // （对齐 Claude Code 的可中断性）。查看其他会话时禁用（单任务并发）。
                Button {
                    chat.isViewingRunningTask ? chat.cancelSending() : chat.send()
                } label: {
                    Image(systemName: chat.isViewingRunningTask ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 25))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(chat.isViewingRunningTask || canSend ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(!chat.isViewingRunningTask && !canSend)
                .padding(.trailing, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isSending
    }

    private var statusText: String {
        let stage = chat.activity ?? L("思考中…", "Thinking…")
        let elapsed = L("\(chat.elapsedSeconds) 秒", "\(chat.elapsedSeconds)s")
        if chat.elapsedSeconds >= 30 {
            return L("\(stage) · \(elapsed) · 任务仍在正常运行", "\(stage) · \(elapsed) · still running normally")
        }
        return "\(stage) · \(elapsed)"
    }
}

/// The conversation history page for the current exact binding.
private struct HistoryListView: View {
    @ObservedObject var chat: ChatViewModel

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Button {
                chat.newConversation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text(L("新建对话", "New Chat"))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Divider()

            if chat.conversationList.isEmpty && chat.ccSessionList.isEmpty {
                Spacer()
                Text(L("当前绑定还没有历史对话", "No chat history for this binding yet"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chat.conversationList) { meta in
                            HistoryRow(
                                meta: meta,
                                isCurrent: meta.id == chat.conversationID,
                                relativeDate: Self.dateFormatter.localizedString(for: meta.updatedAt, relativeTo: Date()),
                                onOpen: { chat.switchConversation(meta.id) },
                                onDelete: { chat.deleteConversation(meta.id) }
                            )
                            Divider().padding(.leading, 12)
                        }

                        // 终端里用 Claude Code 开的会话：点开导入并可续聊
                        if !chat.ccSessionList.isEmpty {
                            HStack {
                                Text(L("CLAUDE CODE 终端会话", "CLAUDE CODE TERMINAL SESSIONS"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                            ForEach(chat.ccSessionList) { session in
                                // 与 HistoryRow 相同的可点击行布局：行内文字保持可选中，
                                // 点击空白处导入会话。
                                HStack(spacing: 8) {
                                    Image(systemName: "terminal")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 13))
                                            .lineLimit(1)
                                        Text(Self.dateFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture { chat.importCCSession(session) }
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { chat.refreshCCSessionList() }
    }
}

private struct HistoryRow: View {
    let meta: ChatViewModel.ConversationMeta
    let isCurrent: Bool
    let relativeDate: String
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(relativeDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Text(L("当前", "Current"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            if hovering {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("删除此对话", "Delete this chat"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }
}

private struct EmptyStateView: View {
    let availableHeight: CGFloat

    private var logoSize: CGFloat {
        if availableHeight >= 190 { return 96 }
        if availableHeight >= 140 { return 56 }
        if availableHeight >= 100 { return 36 }
        return 0
    }

    var body: some View {
        VStack(spacing: availableHeight < 160 ? 4 : 10) {
            if logoSize > 0 {
                ChatBrandLogo(size: logoSize)
            }
            Text(L("在 Finder 中选中文件/文件夹\n描述你想要的操作", "Select files or folders in Finder,\nthen describe the operation you want"))
                .font(availableHeight < 140 ? .caption : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if availableHeight >= 90 {
                Link(L("查看示例操作 >", "View example operations >"),
                     destination: URL(string: "https://folderis.app/skills")!)
                    .font(.caption)
            }
        }
    }
}

private struct ChatBrandLogo: View {
    @EnvironmentObject private var settings: AppSettings
    let size: CGFloat

    var body: some View {
        Group {
            if let logo = BrandLogo.image(choice: settings.logoChoice, preferTransparent: true) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // 自定义/Clippy 多为不透明方图，轻裁圆角；默认透明 orb 不受影响。
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let folder: URL?

    var isUser: Bool { message.role == .user }

    var body: some View {
        if message.role == .system {
            // 工具活动行（浏览/读取/写入文件），弱化显示。
            HStack {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, 4)
        } else if isUser {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 3) {
                    if let taskID = message.taskID {
                        TaskIDChip(taskID: taskID)
                    }
                    bubbleText(message.text)
                }
            }
        } else if message.text.isEmpty {
            // 流式气泡在收到第一个字前是空的——不渲染，避免闪现灰色小胶囊。
            EmptyView()
        } else {
            // 助手消息可能包含 create-file 文件块：文字进气泡，
            // 文件块渲染成带“创建”按钮的卡片。
            VStack(alignment: .leading, spacing: 8) {
                ForEach(MessageSegment.parse(message.text)) { segment in
                    switch segment.kind {
                    case .text(let text):
                        HStack {
                            bubbleText(text)
                            Spacer(minLength: 40)
                        }
                    case .file(let name, let content):
                        FileBlockView(fileName: name, content: content, folder: folder)
                    }
                }
            }
        }
    }

    /// 任务编号 chip：点击复制编号到剪贴板，并短暂提示如何引用该任务。
    private struct TaskIDChip: View {
        let taskID: String
        @State private var copied = false
        @State private var hideTask: Task<Void, Never>?

        var body: some View {
            HStack(spacing: 5) {
                if copied {
                    Text(L("已复制 · 在任意对话输入该编号即可引用此任务",
                           "Copied — type it in any chat to reference this task"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Text(taskID)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(taskID, forType: .string)
                withAnimation { copied = true }
                hideTask?.cancel()
                hideTask = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation { copied = false }
                }
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(L("点击复制任务编号", "Click to copy the task ID"))
        }
    }

    private func bubbleText(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            .foregroundStyle(isUser ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// One piece of an assistant message: plain text, or a create-file block.
private struct MessageSegment: Identifiable {
    enum Kind {
        case text(String)
        case file(name: String, content: String)
    }

    let id: Int
    let kind: Kind

    /// Splits a message on ```create-file:<name> … ``` fenced blocks.
    static func parse(_ text: String) -> [MessageSegment] {
        let pattern = "```create-file:([^\\n`]+)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [MessageSegment(id: 0, kind: .text(text))]
        }

        var segments: [MessageSegment] = []
        var cursor = text.startIndex
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard let full = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else { continue }

            let before = String(text[cursor..<full.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                segments.append(MessageSegment(id: segments.count, kind: .text(before)))
            }
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            segments.append(MessageSegment(id: segments.count, kind: .file(name: name, content: String(text[contentRange]))))
            cursor = full.upperBound
        }

        let tail = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty || segments.isEmpty {
            segments.append(MessageSegment(id: segments.count, kind: .text(tail.isEmpty ? text : tail)))
        }
        return segments
    }
}

/// A code-file card with a create button that writes into the bound folder.
private struct FileBlockView: View {
    let fileName: String
    let content: String
    let folder: URL?

    @State private var status: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                Text(fileName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(failed ? .red : .green)
                }
                Button(fileExists ? L("覆盖", "Overwrite") : L("创建", "Create")) {
                    createFile()
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))

            Divider()

            Text(content.count > 3000 ? String(content.prefix(3000)) + "\n…" : content)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(16)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var targetURL: URL? {
        guard let folder else { return nil }
        let target = folder.appendingPathComponent(fileName).standardizedFileURL
        // Path-safety: the resolved target must stay inside the bound folder.
        guard target.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
        return target
    }

    private var fileExists: Bool {
        guard let targetURL else { return false }
        return FileManager.default.fileExists(atPath: targetURL.path)
    }

    private func createFile() {
        guard let targetURL else {
            status = folder == nil ? L("未绑定文件夹", "No folder bound") : L("文件名不合法", "Invalid file name")
            failed = true
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: targetURL, options: .atomic)
            status = L("已创建 ✓", "Created ✓")
            failed = false
        } catch {
            status = L("失败：\(error.localizedDescription)", "Failed: \(error.localizedDescription)")
            failed = true
        }
    }
}
