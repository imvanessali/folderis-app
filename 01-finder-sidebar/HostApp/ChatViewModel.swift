import Foundation
import AppKit
import CryptoKit
import Darwin

private final class SkillProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var attachedFiles: [URL] = []
    /// Short label of what the agent is doing right now (e.g. "读取 main.py").
    /// Shown inline next to the loading spinner instead of a full message row,
    /// so intermediate steps convey activity without cluttering the transcript.
    @Published var activity: String?
    @Published var elapsedSeconds = 0
    /// Whether the panel is showing the settings page instead of the chat.
    /// Lives here (not view-local @State) because the window toolbar's gear
    /// button toggles it from outside the SwiftUI hierarchy.
    @Published var showSettings = false

    /// Max bytes of a text file inlined into the prompt; larger files are
    /// summarized by metadata only, to protect the context window and the bill.
    nonisolated private static let inlineTextLimit = 100_000

    /// The Finder folder this conversation is bound to. Each folder has its
    /// own persisted history; nil = the global (no-folder) conversation.
    @Published private(set) var boundFolder: URL?
    /// The exact, order-independent Finder selection that owns this history.
    /// Empty means the folder itself; selecting every child is still a distinct
    /// binding from selecting the folder.
    @Published private(set) var boundSelection: [URL] = []
    /// Convenience projection for single regular-file UI and legacy keys.
    @Published private(set) var boundFile: URL?
    /// 当前绑定的会话目录 key。绑定建立时按文件身份（设备号+inode）算好并缓存：
    /// 目标随后被重命名/移动，目录也不变，历史不丢。
    private var boundKey = "global"

    // MARK: 任务态与显示态解耦
    // 面板显示永远跟随当前选中；任务在启动时捕获自己的会话身份与工作目录，
    // 显示切走后输出写入后台缓冲，切回时恢复，完成后按捕获的身份落盘。

    /// 任务启动时捕获的工作目录/选中集：任务执行期间显示切到别的绑定，
    /// 工具与 CLI 仍作用于这里。
    private var taskFolder: URL?
    private var taskSelection: [URL] = []

    /// 任务会话被显示切走后的暂存（身份 + 消息缓冲）；nil = 任务会话在前台。
    struct DetachedRun {
        var conversationID: UUID
        var key: String
        var folder: URL?
        var selection: [URL]
        var sessions: [String: String]
        var messages: [ChatMessage]
    }
    @Published private(set) var detachedRun: DetachedRun?

    /// 是否正在查看运行中任务所在的会话——停止按钮/忙碌行/审批卡只在此时显示。
    var isViewingRunningTask: Bool { isSending && detachedRun == nil }

    /// 任务侧消息读写入口：任务会话在前台写 messages，被切走写后台缓冲。
    private var taskMessages: [ChatMessage] {
        get { detachedRun?.messages ?? messages }
        set {
            if detachedRun != nil { detachedRun!.messages = newValue }
            else { messages = newValue }
        }
    }

    /// 任务侧 CLI 会话 id 读写入口（同上）。
    private var taskSessions: [String: String] {
        get { detachedRun?.sessions ?? backendSessionIDs }
        set {
            if detachedRun != nil { detachedRun!.sessions = newValue }
            else { backendSessionIDs = newValue }
        }
    }

    /// 任务侧错误报告：任务会话在前台走 errorMessage 横幅；在后台则记入
    /// 会话正文，切回来能看到失败原因。
    private func reportTaskError(_ text: String) {
        if detachedRun == nil { errorMessage = text }
        else { taskMessages.append(ChatMessage(role: .system, text: "❌ " + text)) }
    }

    /// 显示即将切走时，把正在前台的运行中任务会话挪进后台缓冲。
    private func detachRunningTaskIfNeeded() {
        guard isSending, detachedRun == nil else { return }
        detachedRun = DetachedRun(conversationID: conversationID, key: boundKey,
                                  folder: boundFolder, selection: boundSelection,
                                  sessions: backendSessionIDs, messages: messages)
    }

    /// A shell command the model wants to run, awaiting the user's decision.
    /// The agent loop is suspended on the continuation until approve/deny.
    struct PendingCommand: Identifiable {
        let id = UUID()
        let command: String
        let purpose: String?
        let continuation: CheckedContinuation<Bool, Never>
    }
    @Published var pendingCommand: PendingCommand?

    func decidePendingCommand(allow: Bool) {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        pending.continuation.resume(returning: allow)
    }

    /// Deny-and-clear used when the session is cancelled/switched while a
    /// confirmation is still on screen, so the continuation never leaks.
    private func cancelPendingCommand() {
        decidePendingCommand(allow: false)
    }

    /// User-initiated stop (the ■ button): aborts the agent loop, keeps
    /// whatever partial reply already streamed in.
    func cancelSending() {
        sendTask?.cancel()
        terminateCLIProcess()
        cancelPendingCommand()
        isSending = false
        activity = nil
        elapsedSeconds = 0
        subagents = []
        saveTaskHistory()
    }

    private let settings: AppSettings
    private var sendTask: Task<Void, Never>?

    // MARK: Multi-conversation state

    struct ConversationMeta: Identifiable, Equatable {
        let id: UUID
        var title: String
        var updatedAt: Date
    }

    /// Conversations of the current folder, newest first.
    @Published private(set) var conversationList: [ConversationMeta] = []
    /// 终端里用 Claude Code 在当前文件夹开过的会话（只读发现，best-effort）。
    struct CCSessionMeta: Identifiable, Equatable {
        let id: String          // CC session UUID（文件名）
        var title: String
        var updatedAt: Date
    }
    @Published private(set) var ccSessionList: [CCSessionMeta] = []
    /// Whether the panel is showing the history list page.
    @Published var showHistory = false
    private(set) var conversationID = UUID()

    // MARK: Live subagent progress (transient, not persisted)

    struct SubagentStatus: Identifiable, Equatable {
        let id: UUID
        let task: String
        var round: Int
        var lastAction: String
    }
    /// Currently running subagents with their step counts and last action.
    @Published var subagents: [SubagentStatus] = []

    init(settings: AppSettings) {
        self.settings = settings
        loadFolder()
    }

    func clearConversation() {
        messages = []
        errorMessage = nil
        saveHistory()
    }

    /// Starts a fresh conversation in the current folder (current one is
    /// already persisted incrementally).
    func newConversation() {
        // 对着运行中任务的会话新建 = 停止该任务；查看其他会话时任务不受影响。
        if isViewingRunningTask { cancelSending() }
        saveHistory()
        conversationID = UUID()
        messages = []
        backendSessionIDs = [:]
        errorMessage = nil
        showHistory = false
    }

    func switchConversation(_ id: UUID) {
        guard id != conversationID else {
            showHistory = false
            return
        }
        detachRunningTaskIfNeeded()
        saveHistory()
        if let run = detachedRun, run.conversationID == id, run.key == boundKey {
            // 切回运行中任务的会话：恢复在途状态（含未落盘的流式输出）。
            conversationID = run.conversationID
            backendSessionIDs = run.sessions
            messages = run.messages
            detachedRun = nil
        } else {
            openConversation(id)
        }
        showHistory = false
    }

    func deleteConversation(_ id: UUID) {
        if detachedRun?.conversationID == id || (isViewingRunningTask && id == conversationID) {
            cancelSending()          // 会话被删，任务一并停止
            detachedRun = nil
        }
        try? FileManager.default.removeItem(at: conversationFileURL(id))
        refreshConversationList()
        if id == conversationID {
            conversationID = UUID()
            messages = []
        }
    }

    /// Switches the conversation to the session bound to (folder, exact selection).
    /// 显示永远跟随当前选中；运行中的任务已捕获自己的会话与工作目录，
    /// 切换只影响显示、不打断任务，切回时恢复其在途输出。
    func switchTarget(folder: URL?, selection: [URL]) {
        let normalizedFolder = folder?.standardizedFileURL
        let normalizedSelection = Self.normalizeSelection(selection)
        let normalizedFile = Self.singleRegularFile(in: normalizedSelection)
        guard normalizedFolder != boundFolder || normalizedSelection != boundSelection else {
            // Same target — but it may have been deleted out from under us.
            validateBoundTarget()
            return
        }
        detachRunningTaskIfNeeded()
        // 旧绑定的历史一律保存保留：旧路径此刻不存在多半是刚被重命名
        // （文件身份不变，同一目录会随新路径接回）；真删除留下的孤儿目录无害。
        saveHistory()
        boundFolder = normalizedFolder
        boundSelection = normalizedSelection
        boundFile = normalizedFile
        boundKey = Self.historyKey(folder: normalizedFolder, selection: normalizedSelection,
                                   file: normalizedFile, token: Self.bindingToken, sortTokens: true)
        errorMessage = nil
        showHistory = false
        if let run = detachedRun, run.key == boundKey {
            // 切回运行中任务绑定的会话：恢复在途状态（含未落盘的流式输出）。
            conversationID = run.conversationID
            backendSessionIDs = run.sessions
            messages = run.messages
            detachedRun = nil
            refreshConversationList()
            refreshCCSessionList()
        } else {
            loadFolder()
        }
    }

    nonisolated private static func normalizeSelection(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func singleRegularFile(in selection: [URL]) -> URL? {
        guard selection.count == 1, let url = selection.first else { return nil }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? nil : url
    }

    /// Called on every Finder poll tick; detaches the session in place when the
    /// file/folder it is bound to no longer exists at its old path. 历史文件
    /// 一律保留在磁盘上：路径消失很可能只是重命名（文件身份不变，下次轮询
    /// 会经由身份 key 自动接回同一份历史），删除会造成不可恢复的丢失。
    func validateBoundTarget() {
        // 正在查看运行中任务的会话时不动绑定：路径变化很可能是任务自己的
        // 重命名/生成，完成后的下一次轮询会应用最新的 Finder 上下文。
        // 任务被切到后台时这里只影响显示，不再取消任务。
        guard !isViewingRunningTask else { return }
        if !boundSelection.isEmpty,
           boundSelection.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            boundSelection = []
            boundFile = nil
            boundKey = Self.historyKey(folder: boundFolder, selection: [], file: nil,
                                       token: Self.bindingToken, sortTokens: true)
            messages = []
            errorMessage = nil
            loadFolder()
            return
        }
        guard let folder = boundFolder,
              !FileManager.default.fileExists(atPath: folder.path) else { return }
        messages = []
        boundFolder = nil
        boundSelection = []
        boundFile = nil
        boundKey = "global"
        errorMessage = nil
        loadFolder()
    }

    func attach(_ urls: [URL]) {
        for url in urls where !attachedFiles.contains(url) {
            attachedFiles.append(url)
        }
    }

    func removeAttachment(_ url: URL) {
        attachedFiles.removeAll { $0 == url }
    }

    private var lastSyncedSelection: [URL] = []

    /// Mirrors the Finder selection into the attachment list automatically.
    /// Only reacts when the selection actually changes, so a chip the user
    /// removed by hand stays removed until they select something else.
    func syncSelection(_ urls: [URL]) {
        // 显示跟随选中：任务执行中绑定与 chips 也照常切换（任务已捕获
        // 自己的目录与会话，不受影响）。
        guard urls != lastSyncedSelection else { return }
        lastSyncedSelection = urls
        attachedFiles = urls
    }

    func insertPathMention(_ url: URL) {
        let mention = "`\(url.path)` "
        if draft.isEmpty {
            draft = mention
        } else {
            draft += (draft.hasSuffix(" ") ? "" : " ") + mention
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        let usesCLI = settings.backend != .builtinAPI
        guard usesCLI || !settings.apiKey.isEmpty else {
            errorMessage = L("请先在设置里填写 API Key", "Set your API key in Settings first")
            return
        }

        let taskID = nextTaskID()
        let referencedTask = referencedTaskContext(in: text)
        let files = Self.normalizeSelection(attachedFiles)
        let effectiveFolder = Self.taskWorkingDirectory(boundFolder: boundFolder, attachments: files)
        registerTask(taskID, text: text, folder: effectiveFolder, selection: files)
        if !usesCLI,
           !settings.provider.supportsVision,
           let notice = Self.deepSeekCapabilityNotice(request: text, files: files) {
            let fileContext = files.isEmpty ? nil :
                Self.attachmentScopeHeader + files.map { "文件 `\($0.path)`" }.joined(separator: "\n")
            let contextBlock = [fileContext, referencedTask].compactMap { $0 }.joined(separator: "\n\n")
            messages.append(ChatMessage(role: .user, taskID: taskID, text: text,
                                        promptContext: contextBlock.isEmpty ? nil : contextBlock))
            messages.append(ChatMessage(role: .assistant, text: notice))
            draft = ""
            errorMessage = nil
            saveHistory()
            return
        }

        attachedFiles = []
        draft = ""
        errorMessage = nil
        isSending = true
        elapsedSeconds = 0
        // 捕获任务的工作目录与选中集：此后显示切到哪个绑定都不影响本任务。
        taskFolder = effectiveFolder
        taskSelection = files

        // CLI 后端（Claude Code 能自己读图）不做视觉降级。
        let allowImages = usesCLI || settings.provider.supportsVision
        sendTask = Task {
            let startedAt = Date()
            let elapsedTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { break }
                    guard !Task.isCancelled else { break }
                    self?.elapsedSeconds = max(1, Int(Date().timeIntervalSince(startedAt)))
                }
            }
            defer {
                elapsedTask.cancel()
                activity = nil
                elapsedSeconds = 0
                isSending = false
                // 取消/错误提前 return 的路径也把在途内容按任务身份落盘。
                saveTaskHistory()
                detachedRun = nil
            }

            // File reading and image re-encoding can be slow (large photos),
            // so it runs off the main actor to keep the panel responsive.
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepareAttachments(files, allowImages: allowImages && !usesCLI,
                                        cliReadsFiles: usesCLI)
            }.value

            // 文件上下文只送给模型，不在气泡里复读（用户自己选的文件）。
            let fileContext: String? = prepared.descriptions.isEmpty
                ? nil
                : Self.attachmentScopeHeader + prepared.descriptions.joined(separator: "\n\n")
            let combinedContext = [fileContext, referencedTask].compactMap { $0 }.joined(separator: "\n\n")

            let userMessage = ChatMessage(
                role: .user, taskID: taskID, text: text,
                promptContext: combinedContext.isEmpty ? nil : combinedContext,
                images: prepared.images)
            taskMessages.append(userMessage)
            saveTaskHistory()

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activity = L("匹配内置技能…", "Matching a built-in skill…")
                if let local = await Self.runLocalDispatch(
                       request: text, files: files, cwd: taskFolder,
                       onStage: { [weak self] stage in
                           // 匹配成功即把标签换成执行阶段，任务被停止后不再回写。
                           Task { @MainActor [weak self] in
                               guard let self, self.isSending else { return }
                               self.activity = stage
                           }
                       }),
                   local.matched {
                    activity = local.stage ?? L("本地处理…", "Processing locally…")
                    let reply: String
                    if local.success == true, let outputs = local.outputs, !outputs.isEmpty {
                        reply = Self.localSkillCompletionReply(
                            skill: local.skill ?? "local",
                            elapsed: local.elapsed ?? 0,
                            outputs: outputs,
                            details: local.details
                        )
                    } else if local.success == true,
                              let detail = local.details?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !detail.isEmpty {
                        // 信息查询类技能（csv-preview/qr-read/hash 检测等）成功但天然
                        // 不产文件：答案在 details 里，不能包装成“未完成”。
                        let skill = local.skill ?? "local"
                        let elapsed = String(format: "%.2f", local.elapsed ?? 0)
                        reply = L(
                            "已通过内置技能完成，没有调用 AI（信息查询，无新文件）。\n技能：\(skill) · \(elapsed) 秒\n\(detail)",
                            "Completed with a built-in skill without calling AI (informational; no new files).\nSkill: \(skill) · \(elapsed)s\n\(detail)"
                        )
                    } else {
                        let detail = local.details?.trimmingCharacters(in: .whitespacesAndNewlines)
                        reply = L("内置技能未完成：\(detail?.isEmpty == false ? detail! : "未知错误")",
                                  "The built-in skill did not complete: \(detail?.isEmpty == false ? detail! : "unknown error")")
                    }
                    taskMessages.append(ChatMessage(role: .assistant, text: reply))
                    if usesCLI { taskSessions[settings.backend.rawValue] = nil }
                    saveTaskHistory()
                    return
                }
                // Cancelling the local dispatcher can leave no result marker.
                // Do not mistake that for "not matched" and launch an AI CLI.
                guard !Task.isCancelled else { return }
            }

            if usesCLI {
                // CLI 自己管理会话记忆（resume），无需压缩与本地代理循环。
                do {
                    try await runCLIBackendTurn(userMessage: userMessage)
                } catch is CancellationError {
                    return
                } catch {
                    reportTaskError(describe(error))
                }
            } else {
                // 单一来源 fail-safe：内置代理循环的产物政策同样只来自 catalog
                // （system prompt 整段注入）。政策缺失即拒绝，避免无政策裸跑。
                guard Self.sharedArtifactPolicy != nil else {
                    reportTaskError(L(
                        "技能运行时损坏或缺失（无法加载「全局产物规则」），文件处理已停用。请重新安装应用或修复技能组件。",
                        "The skills runtime is missing or corrupted (global artifact policy unavailable), so file processing is disabled. Reinstall the app or repair the skills component."))
                    return
                }
                // Auto-compact: summarize old turns when the conversation grows
                // too large, so long sessions don't blow the context window.
                do {
                    try await compactIfNeeded()
                } catch is CancellationError {
                    return
                } catch {
                    // Compaction is best-effort; fall through with full history.
                }

                let history = taskMessages

                do {
                    try await streamReply(history: history)
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    reportTaskError(describe(error))
                }
            }
            // Drop an assistant bubble that never received any content
            // (e.g. connection failed before the first token).
            if let last = taskMessages.last, last.role == .assistant, last.text.isEmpty {
                taskMessages.removeLast()
            }
            saveTaskHistory()
        }
    }

    private struct LocalDispatchResult: Decodable {
        let matched: Bool
        let success: Bool?
        let skill: String?
        let stage: String?
        let outputs: [String]?
        let details: String?
        let elapsed: Double?
    }

    /// B8（20260805.3 case61）：完成卡片必须透出技能自身的完成文案（ok() 输出，
    /// 例如 zip-encrypt 的「AES-256；需用 7-Zip、Keka 等支持 AES 的工具解压」）。
    /// details 已由 local-dispatch 截到末尾 2000 字符，这里全文展示不再截断。
    nonisolated static func localSkillCompletionReply(
        skill: String,
        elapsed: Double,
        outputs: [String],
        details: String?
    ) -> String {
        let elapsedText = String(format: "%.2f", elapsed)
        let paths = outputs.joined(separator: "\n")
        var reply = L(
            "已通过内置技能完成，没有调用 AI，也没有覆盖原文件。\n技能：\(skill) · \(elapsedText) 秒\n结果文件：\n\(paths)",
            "Completed with a built-in skill without calling AI or overwriting the originals.\nSkill: \(skill) · \(elapsedText)s\nOutput:\n\(paths)"
        )
        let notes = (details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            reply += L("\n技能说明：\n\(notes)", "\nSkill notes:\n\(notes)")
        }
        return reply
    }

    nonisolated private static func runLocalDispatch(
        request: String,
        files: [URL],
        cwd: URL?,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async -> LocalDispatchResult? {
        guard let cwd else { return nil }
        let args = ["--request", request, "--files"] + files.map(\.path)
        let output = await runSkill(skill: "local-dispatch", args: args, cwd: cwd, onStage: onStage)
        let marker = "__FOLDERIS_LOCAL_RESULT__"
        guard let range = output.range(of: marker, options: .backwards),
              let data = String(output[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LocalDispatchResult.self, from: data)
    }

    /// DeepSeek is currently text-only. Block requests whose success depends
    /// on inspecting or recreating pixels before any intermediate files exist.
    nonisolated private static func deepSeekCapabilityNotice(request: String, files: [URL]) -> String? {
        let text = request.lowercased()
        let extensions = Set(files.map { $0.pathExtension.lowercased() })
        let hasPDF = extensions.contains("pdf")
        let hasImage = !extensions.isDisjoint(with: [
            "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"
        ])
        let hasVideo = !extensions.isDisjoint(with: ["mp4", "mov", "mkv", "avi", "webm", "m4v"])

        func containsAny(_ terms: [String]) -> Bool {
            terms.contains(where: text.contains)
        }

        let acceptedDowngrade = containsAny([
            "只翻译文字", "仅翻译文字", "接受近似", "近似排版", "不需要保持", "不用保持",
            "不要求一致", "无需一致", "text only", "approximate layout"
        ])
        let requestsTranslation = containsAny(["翻译", "translate"])
        let requestsVisualFidelity = containsAny([
            "样式一致", "风格一致", "保持样式", "保留样式", "保持版式", "保留版式",
            "保持排版", "保留排版", "原pdf一致", "完全一致", "高保真",
            "same style", "preserve layout", "keep the layout", "pixel-perfect"
        ])
        if hasPDF && requestsTranslation && requestsVisualFidelity && !acceptedDowngrade {
            return L(
                "当前使用的是 DeepSeek API。它不能查看 PDF 页面的视觉画面，Folderis 目前无法可靠完成“翻译内容并保持原 PDF 版式一致”，所以我没有开始处理，也不会生成页面图片。\n\n你可以改为：\n1. 只提取并翻译指定页文字；\n2. 生成近似排版的新 PDF，但不保证与原版一致；\n3. 在完整版中切换 Claude Code、Codex 或 Cursor 后再尝试。",
                "The current DeepSeek API cannot inspect the visual appearance of PDF pages, so Folderis cannot reliably translate content while preserving the original layout. Nothing has been processed and no page images were created.\n\nYou can instead request: 1. text-only translation of specified pages; 2. a new PDF with approximate layout; or 3. switch to Claude Code, Codex, or Cursor in the full version."
            )
        }

        let requestsVisualInspection = containsAny([
            "描述画面", "分析画面", "查看样式", "看看样式", "视觉比较", "比较外观",
            "图里是什么", "图片里是什么", "什么风格", "分析配色", "看图回答",
            "describe the image", "analyze the image", "visual comparison", "what is in the image"
        ])
        if (hasImage || hasPDF || hasVideo) && requestsVisualInspection {
            return L(
                "当前使用的是 DeepSeek API，它不能直接查看图片、PDF 页面或视频画面，因此我无法可靠完成这项视觉理解任务，也没有开始创建文件。OCR 文字提取、格式转换、压缩、裁剪等不需要理解画面的操作仍然可以完成。",
                "The current DeepSeek API cannot directly inspect images, PDF pages, or video frames, so this visual-understanding request cannot be completed reliably. No files were created. OCR, conversion, compression, and cropping are still supported."
            )
        }

        let requestsImageGeneration = containsAny([
            "生成图片", "生成一张图", "画一张", "绘制图片", "生成插画", "设计海报",
            "生成logo", "生成 logo", "做一个logo", "做一个 logo",
            "generate an image", "create an illustration", "design a poster", "generate a logo"
        ])
        if requestsImageGeneration {
            return L(
                "当前 DeepSeek API 和 Folderis 的内置工具不具备图片生成能力，因此我不能完成这项任务，也不会创建占位图片。图片压缩、转换、改尺寸、裁剪、加水印、抠图和 OCR 仍然可用。",
                "The current DeepSeek API and Folderis tools do not support image generation, so this request cannot be completed and no placeholder image will be created. Compression, conversion, resizing, cropping, watermarking, background removal, and OCR remain available."
            )
        }
        return nil
    }

    nonisolated private static func prepareAttachments(
        _ files: [URL],
        allowImages: Bool,
        cliReadsFiles: Bool = false
    ) -> (images: [ImageAttachment], descriptions: [String]) {
        var images: [ImageAttachment] = []
        var descriptions: [String] = []
        for url in files {
            if allowImages, let image = imageAttachment(for: url) {
                images.append(image)
                descriptions.append("图片 `\(url.path)`（见附图）")
            } else if !allowImages && isImageFile(url) {
                // CLI 代理（Claude Code 等）能按路径自行读图，不能沿用
                // “模型不支持看图”的降级话术，否则会错误拒绝视觉类任务。
                descriptions.append(cliReadsFiles
                    ? "图片 `\(url.path)`（需要查看画面内容时可直接读取该文件）"
                    : "图片 `\(url.path)`（当前模型不支持理解图片画面内容；但压缩、格式转换、改尺寸、加水印、OCR 等文件级操作照常可用，请正常调用相应技能。只有当用户要求你描述/理解画面内容时，才说明当前模型无法看图。）")
            } else {
                descriptions.append(describeFile(url))
            }
        }
        return (images, descriptions)
    }

    nonisolated private static func isImageFile(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    /// Hard API-side ceiling (Anthropic: 5MB/image). Not exposed to the user:
    /// oversized or unsupported-format images are transparently downscaled
    /// and re-encoded as JPEG until they fit.
    nonisolated private static let imageSizeLimit = 5_000_000

    nonisolated private static func imageAttachment(for url: URL) -> ImageAttachment? {
        let directTypes = [
            "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "png": "image/png", "gif": "image/gif", "webp": "image/webp"
        ]
        let convertibleTypes: Set<String> = ["heic", "heif", "tiff", "tif", "bmp"]
        let ext = url.pathExtension.lowercased()
        guard directTypes.keys.contains(ext) || convertibleTypes.contains(ext) else { return nil }

        // Small files in natively supported formats pass through untouched.
        if let mediaType = directTypes[ext],
           let data = try? Data(contentsOf: url),
           data.count <= imageSizeLimit {
            return ImageAttachment(mediaType: mediaType, base64: data.base64EncodedString(), fileName: url.lastPathComponent)
        }

        // Unsupported format or oversized: re-encode as JPEG, halving the
        // resolution each round until it fits under the API ceiling.
        guard let image = NSImage(contentsOf: url) else { return nil }
        var maxDimension: CGFloat = 2048
        for _ in 0..<6 {
            if let jpeg = jpegData(from: image, maxDimension: maxDimension, quality: 0.85),
               jpeg.count <= imageSizeLimit {
                return ImageAttachment(mediaType: "image/jpeg", base64: jpeg.base64EncodedString(), fileName: url.lastPathComponent)
            }
            maxDimension /= 2
        }
        return nil
    }

    nonisolated private static func jpegData(from image: NSImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Renders one attached file as prompt context: full content for
    /// reasonably-sized text files, metadata only for everything else.
    nonisolated private static func describeFile(_ url: URL) -> String {
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return "文件 `\(path)`（已不存在）"
        }
        if isDir.boolValue {
            if let denied = Self.accessDeniedHint(for: url) { return denied }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            let listing = entries.prefix(100).joined(separator: "\n")
            return "文件夹 `\(path)`，包含 \(entries.count) 项：\n\(listing)"
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0

        if size <= inlineTextLimit,
           let data = FileManager.default.contents(atPath: path),
           let content = String(data: data, encoding: .utf8) {
            return "文件 `\(path)`（\(size) 字节）内容：\n```\n\(content)\n```"
        }

        let kind: String
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": kind = "视频"
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg": kind = "音频"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": kind = "压缩包"
        case "pdf": kind = "PDF"
        case "doc", "docx": kind = "Word 文档"
        case "xls", "xlsx", "xlsm", "numbers": kind = "表格"
        case "ppt", "pptx", "key": kind = "演示文稿"
        case "app", "dmg", "pkg": kind = "应用/安装包"
        default:
            // 大文本文件与未知二进制分开表述
            if let data = FileManager.default.contents(atPath: path),
               String(data: data.prefix(4096), encoding: .utf8) != nil {
                kind = "文本文件（内容较大未展开）"
            } else {
                kind = "文件"
            }
        }
        return "\(kind) `\(path)`"
    }

    private func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.message
        }
        return error.localizedDescription
    }

    // MARK: - CLI 后端（Claude Code / Codex / Cursor）：驱动本机已登录的代理 CLI，
    // 用量走用户订阅；任务以绑定文件夹为 cwd，自动进入其项目会话列表。

    /// 每个会话对应的 CLI session id（用于 resume），随历史持久化。
    var backendSessionIDs: [String: String] = [:]
    private var cliProcess: Process?

    /// 附件上下文的统一开头：明确“选中/附上的文件 = 本次任务的全部输入范围”，
    /// 防止模型以“任务未指定单张”为由扩大到同文件夹的其他文件。
    nonisolated static let attachmentScopeHeader =
        "以下是用户选中/附上的文件，它们就是本次任务的全部输入范围。" +
        "任务描述没有点名对象时，对象就是这些文件，而不是所在文件夹；" +
        "除非用户明确要求，绝不能把操作扩大到范围之外的其他文件，即使它们相似或适用同样的操作：\n\n"

    /// 测试专用只读入口：断言 CLI 提示词不内嵌共享政策正文。
    nonisolated static var cliScopePolicyForTesting: String { cliScopePolicy }

    /// CLI 后端专属增量。产物去向/碰撞/覆盖/删除安全等共享政策不在此重复：
    /// 唯一来源是 catalog.txt 的「全局产物规则」段，经技能简报送达（缺失即拒绝执行）。
    private static let cliScopePolicy = """
    执行边界：严格按用户指定的文件、页码、数量和格式处理，不擅自扩大为全量或批量。用户消息中列出的选中/附上文件就是本次任务的全部输入范围：任务未点名对象时即以这些文件为对象，绝不能因为同文件夹其他文件相似或“批量处理更一致”而扩大到列表之外。只要求查看/回答内容时直接回复，不创建文件；转换、压缩、OCR、转写、总结为纪要、差异对比、二维码识别、重命名或去重等动作本身就要求生成可交付文件，聊天文字不能替代产物。产物的保留、命名、目录去向、覆盖边界与删除/去重安全要求，一律以技能目录开头的「全局产物规则」为准；用户指定输出名不等于允许覆盖。不得创建未要求的副本、拆分页、逐页图片或全量文本；必要中间文件必须放在操作系统临时目录并在结束前清理，最终多产物 Output 不属于临时目录。范围歧义会导致不同产物时先简短询问。提取 PDF 文字必须逐页 OCR，且只 OCR 用户指定页码。不要把计划、准备步骤或“我先……”当作最终回复；必须实际完成任务并验证最终文件后再结束。回复必须精简并明确列出最终文件或 Output 完整路径。
    """

    func runCLIBackendTurn(userMessage: ChatMessage) async throws {
        let bubbleID = startBubble()
        defer { finishBubble(bubbleID) }

        let backend = settings.backend
        // Claude Code 经 --append-system-prompt 注入技能简报；codex/cursor 无对应
        // 参数，简报并入提示词开头，保证三个后端看到同一份技能边界。
        let skillsBrief = Self.cliSkillsBrief
        // 单一来源 fail-safe：产物政策只经 catalog（技能简报）送达。加载不到
        // 完整政策段时按约定拒绝执行，绝不允许无政策裸跑文件任务。
        guard !skillsBrief.isEmpty, Self.sharedArtifactPolicy != nil else {
            throw APIError.server(status: 0, body: L(
                "技能运行时损坏或缺失（无法加载「全局产物规则」），文件处理已停用。请重新安装应用或修复技能组件。",
                "The skills runtime is missing or corrupted (global artifact policy unavailable), so file processing is disabled. Reinstall the app or repair the skills component."))
        }
        let briefInPrompt = (backend == .claudeCode || skillsBrief.isEmpty) ? "" : skillsBrief + "\n\n"
        let prompt = briefInPrompt + Self.cliScopePolicy + "\n\n用户请求：\n" + Self.apiText(of: userMessage)
        let cwd = taskFolder ?? FileManager.default.homeDirectoryForCurrentUser

        let cliPath: String?
        switch backend {
        case .claudeCode: cliPath = settings.claudeCLIPath
        case .codex: cliPath = settings.codexCLIPath
        case .cursor: cliPath = settings.cursorCLIPath
        case .builtinAPI: cliPath = nil
        }
        guard let cliPath else {
            throw APIError.server(status: 0, body: L("未检测到 \(backend.displayName) CLI，请确认已安装并登录", "\(backend.displayName) CLI not found — make sure it is installed and logged in"))
        }

        var args: [String]
        let sessionKey = backend.rawValue
        if backend == .claudeCode {
            args = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
            if !skillsBrief.isEmpty {
                args += ["--append-system-prompt", skillsBrief]
            }
            if let sid = taskSessions[sessionKey] {
                args += ["--resume", sid]
            }
            switch settings.approvalMode {
            case .yolo: args += ["--dangerously-skip-permissions"]
            default: args += ["--permission-mode", "acceptEdits"]
            }
        } else if backend == .codex {
            if let sid = taskSessions[sessionKey] {
                args = ["exec", "resume", sid, "--json"]
            } else {
                args = ["exec", "--json"]
            }
            if settings.approvalMode == .yolo {
                args += ["--dangerously-bypass-approvals-and-sandbox"]
            } else {
                args += ["--full-auto"]
            }
            args.append(prompt)
        } else {
            args = [
                "-p", prompt,
                "--output-format", "stream-json",
                "--stream-partial-output"
            ]
            if let sid = taskSessions[sessionKey] {
                args += ["--resume", sid]
            }
            // Cursor print mode only writes files when --force is enabled.
            if settings.approvalMode == .yolo {
                args += ["--force"]
            }
        }

        activity = L("\(backend.displayName) 运行中…", "\(backend.displayName) running…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.currentDirectoryURL = cwd
        // 干净环境：去掉嵌套会话/API Key 类变量，避免干扰 CLI 自身认证。
        var env = BackendKind.environmentForCLI(at: cliPath)
        for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE")
            || key.hasPrefix("OPENAI_") || key == "CURSOR_API_KEY" {
            env.removeValue(forKey: key)
        }
        // 技能简报中承诺的专用工具目录（ffmpeg/pngquant 等）对 CLI 可见。
        let skillsBin = Self.supportRoot.appendingPathComponent("bin").path
        if FileManager.default.fileExists(atPath: skillsBin) {
            var parts = (env["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            if !parts.contains(skillsBin) { parts.append(skillsBin) }
            env["PATH"] = parts.joined(separator: ":")
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Drain stderr concurrently. Leaving a redirected pipe unread can fill
        // its buffer and stall a long-running CLI task.
        let stderrTask = Task.detached(priority: .utility) {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        cliProcess = process
        defer { cliProcess = nil }

        var completedNormally = false
        var streamedFailure: String?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let eventType = object["type"] as? String
            if backend == .codex {
                if eventType == "turn.completed" { completedNormally = true }
                if eventType == "turn.failed" || eventType == "error" {
                    streamedFailure = Self.cliErrorText(in: object)
                        ?? L("Codex 任务失败", "Codex task failed")
                }
            } else if eventType == "result" {
                completedNormally = true
                if object["is_error"] as? Bool == true {
                    streamedFailure = (object["result"] as? String)
                        ?? L("\(backend.displayName) 任务失败", "\(backend.displayName) task failed")
                }
            }
            handleCLIEvent(object, backend: backend, sessionKey: sessionKey, bubbleID: bubbleID)
        }
        process.waitUntilExit()
        let stderrText = await stderrTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let streamedFailure {
            throw APIError.cli(exitCode: Int(process.terminationStatus), body: streamedFailure)
        }
        if process.terminationStatus != 0 {
            let isCursorAuthFailure = backend == .cursor
                && (stderrText.localizedCaseInsensitiveContains("authentication required")
                    || stderrText.localizedCaseInsensitiveContains("not logged in")
                    || stderrText.localizedCaseInsensitiveContains("not authenticated"))
            let detail = isCursorAuthFailure
                ? L("Cursor 未登录：请打开终端运行 cursor-agent login，完成后重试",
                    "Cursor is not signed in — run `cursor-agent login` in Terminal, then retry")
                : stderrText.isEmpty
                ? L("进程异常退出", "process exited unexpectedly")
                : String(stderrText.prefix(500))
            throw APIError.cli(exitCode: Int(process.terminationStatus),
                               body: "\(backend.displayName): \(detail)")
        }
        if !completedNormally {
            throw APIError.cli(
                exitCode: nil,
                body: L("\(backend.displayName) 未正常完成任务，请重试。已显示的内容只是中间进度，不代表文件已生成。",
                        "\(backend.displayName) did not complete normally. Retry the task; any text shown above was progress, not a completed file."))
        }
    }

    nonisolated private static func cliErrorText(in object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["detail"] as? String)
        }
        return nil
    }

    func terminateCLIProcess() {
        guard let process = cliProcess else { return }
        // CLI agents may have shell commands running below them. Signal every
        // descendant so Stop does not leave orphan work behind.
        for pid in Self.descendantProcessIDs(of: process.processIdentifier).reversed() {
            Darwin.kill(pid, SIGTERM)
        }
        if process.isRunning { process.terminate() }
        cliProcess = nil
    }

    nonisolated private static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [rootPID]
        var visited = Set<pid_t>()
        while let parent = pending.popLast() {
            guard visited.insert(parent).inserted else { continue }
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-P", String(parent)]
            let output = Pipe()
            probe.standardOutput = output
            probe.standardError = Pipe()
            guard (try? probe.run()) != nil else { continue }
            probe.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let children = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0) }
            result.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return result
    }

    private func handleCLIEvent(_ object: [String: Any], backend: BackendKind,
                                sessionKey: String, bubbleID: UUID) {
        if let sid = object["session_id"] as? String {
            taskSessions[sessionKey] = sid
        }
        if backend == .claudeCode || backend == .cursor {
            switch object["type"] as? String {
            case "system":
                if let sid = object["session_id"] as? String {
                    taskSessions[sessionKey] = sid
                }
            case "assistant":
                // Cursor partial mode also emits buffered copies. Only these
                // events are real deltas; final text remains a result fallback.
                if backend == .cursor,
                   object["timestamp_ms"] == nil || object["model_call_id"] != nil {
                    return
                }
                guard let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                for block in content {
                    if block["type"] as? String == "text", let text = block["text"] as? String {
                        let separator = backend == .cursor ? "" : textSeparatorIfNeeded(bubbleID)
                        appendToBubble(bubbleID, separator + text)
                    } else if block["type"] as? String == "tool_use",
                              let name = block["name"] as? String {
                        activity = "🔧 \(name)"
                    }
                }
            case "result":
                if let sid = object["session_id"] as? String {
                    taskSessions[sessionKey] = sid
                }
                if object["is_error"] as? Bool == true {
                    let raw = (object["result"] as? String) ?? L("未知错误", "unknown error")
                    if raw.lowercased().contains("authenticat") || raw.lowercased().contains("logged in") {
                        reportTaskError(backend == .cursor
                            ? L("Cursor 未登录：请打开终端运行 cursor-agent login，完成后重试", "Cursor is not signed in — run `cursor-agent login` in Terminal, then retry")
                            : L("Claude Code 登录已过期：请打开终端运行 claude（会引导重新登录），完成后重试", "Claude Code login expired — run `claude` in Terminal to sign in again, then retry"))
                    } else {
                        reportTaskError(L("\(backend.displayName) 出错：\(raw.prefix(200))", "\(backend.displayName) error: \(raw.prefix(200))"))
                    }
                    return
                }
                // 兜底：全程没有 assistant 文本时用 result 字段
                if let i = taskMessages.firstIndex(where: { $0.id == bubbleID }),
                   taskMessages[i].text.isEmpty,
                   let result = object["result"] as? String {
                    appendToBubble(bubbleID, result)
                }
            default:
                if backend == .cursor,
                   object["type"] as? String == "tool_call",
                   object["subtype"] as? String == "started",
                   let toolCall = object["tool_call"] as? [String: Any],
                   let toolName = toolCall.keys.first {
                    activity = "🔧 \(toolName)"
                }
                break
            }
        } else {
            // Codex exec --json：宽容解析，覆盖版本差异。
            if let threadID = (object["thread_id"] as? String)
                ?? ((object["thread"] as? [String: Any])?["id"] as? String) {
                taskSessions[sessionKey] = threadID
            }
            if let item = object["item"] as? [String: Any] {
                if item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    appendToBubble(bubbleID, textSeparatorIfNeeded(bubbleID) + text)
                } else if let t = item["type"] as? String, t.contains("command") {
                    activity = "🔧 \(t)"
                }
            }
        }
    }

    private func textSeparatorIfNeeded(_ bubbleID: UUID) -> String {
        guard let i = taskMessages.firstIndex(where: { $0.id == bubbleID }) else { return "" }
        return taskMessages[i].text.isEmpty ? "" : "\n\n"
    }

    // MARK: - 终端 Claude Code 会话的反向发现与导入（best-effort 只读）

    /// CC 的项目目录命名：cwd 路径的 `/` 与 `.` 替换为 `-`。
    nonisolated private static func ccProjectDir(for folder: URL) -> URL {
        let slug = folder.standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)
    }

    /// 扫描绑定文件夹对应的 CC 会话（标题=首条用户文本，时间=文件 mtime）。
    /// 任何解析失败都静默跳过——这是无文档格式的展示层，不能拖垮面板。
    func refreshCCSessionList() {
        guard let folder = boundFolder, boundSelection.isEmpty else {
            ccSessionList = []
            return
        }
        let dir = Self.ccProjectDir(for: folder)
        Task.detached(priority: .utility) { [weak self] in
            var found: [CCSessionMeta] = []
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: sessionID) != nil else { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let title = Self.firstUserText(inTranscript: file) ?? L("终端会话", "Terminal session")
                found.append(CCSessionMeta(
                    id: sessionID,
                    title: title.count > 24 ? String(title.prefix(24)) + "…" : title,
                    updatedAt: mtime))
            }
            let sorted = found.sorted { $0.updatedAt > $1.updatedAt }
            await MainActor.run { [weak self] in
                // 已被导入过的（session id 挂在某个面板会话上）不再重复列出
                guard let self,
                      self.boundSelection.isEmpty,
                      self.boundFolder == folder else { return }
                let imported = Set(self.conversationImportedCCSessionIDs())
                self.ccSessionList = sorted.filter { !imported.contains($0.id) }
            }
        }
    }

    private func conversationImportedCCSessionIDs() -> [String] {
        var ids: [String] = []
        if let sid = backendSessionIDs[BackendKind.claudeCode.rawValue] { ids.append(sid) }
        for meta in conversationList {
            guard let data = try? Data(contentsOf: conversationFileURL(meta.id)),
                  let payload = try? JSONDecoder().decode(PersistedHistory.self, from: data),
                  let sid = payload.backendSessions?[BackendKind.claudeCode.rawValue] else { continue }
            ids.append(sid)
        }
        return ids
    }

    nonisolated private static func firstUserText(inTranscript file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 64_000)
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t.split(separator: "\n").first.map(String.init) }
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "text" {
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty {
                        return t.split(separator: "\n").first.map(String.init)
                    }
                }
            }
        }
        return nil
    }

    /// 把一个终端 CC 会话导入为面板会话：重建气泡流 + 绑定 resume id。
    func importCCSession(_ meta: CCSessionMeta) {
        guard let folder = boundFolder, boundSelection.isEmpty else { return }
        if isSending { cancelSending() }
        saveHistory()

        let file = Self.ccProjectDir(for: folder).appendingPathComponent("\(meta.id).jsonl")
        var imported: [ChatMessage] = []
        if let content = try? String(contentsOf: file, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = object["type"] as? String,
                      let message = object["message"] as? [String: Any] else { continue }
                var text = ""
                if let s = message["content"] as? String {
                    text = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    text = blocks.compactMap {
                        $0["type"] as? String == "text" ? $0["text"] as? String : nil
                    }.joined(separator: "\n")
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if type == "user" {
                    // 工具结果也是 user 角色：带 tool_result 块的跳过
                    if let blocks = message["content"] as? [[String: Any]],
                       blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                    imported.append(ChatMessage(role: .user, text: trimmed))
                } else if type == "assistant" {
                    imported.append(ChatMessage(role: .assistant, text: trimmed))
                }
            }
        }

        conversationID = UUID()
        messages = imported.isEmpty
            ? [ChatMessage(role: .system, text: L("（终端会话导入：正文解析为空，继续对话仍会衔接原上下文）", "(Imported terminal session: transcript body was empty; new messages will still continue the original context)"))]
            : imported
        backendSessionIDs = [BackendKind.claudeCode.rawValue: meta.id]
        errorMessage = nil
        showHistory = false
        saveHistory()
        refreshCCSessionList()
    }

    // MARK: - Agentic reply loop (Claude Code-style, cwd = bound folder)

    /// Runs the agent loop: the model can browse, read, and write files in
    /// the bound folder via tools, across multiple rounds, until it produces
    /// a final text answer.
    private func streamReply(history: [ChatMessage]) async throws {
        var apiMessages = initialAPIMessages(history: history)
        let taskID = history.last(where: { $0.role == .user })?.taskID
        var rounds = 0
        while true {
            try Task.checkCancellation()
            rounds += 1
            if rounds > 40 {
                let label = taskID.map { L("任务 \($0)：", "Task \($0): ") } ?? ""
                taskMessages.append(ChatMessage(role: .system, text: label + L("工具调用达到 40 轮上限，已停止",
                    "tool calls reached the 40-round limit and stopped")))
                break
            }
            let needsAnotherTurn: Bool
            if settings.provider.usesOpenAIProtocol {
                needsAnotherTurn = try await runOpenAITurn(&apiMessages)
            } else {
                needsAnotherTurn = try await runAnthropicTurn(&apiMessages)
            }
            if !needsAnotherTurn { break }
        }
    }

    // MARK: - Context compaction (auto-compact长会话)

    /// Rough char budget across the conversation before we summarize. Keeps a
    /// margin under typical context windows without needing a real tokenizer.
    private static let compactionCharBudget = 48_000
    /// How many of the most recent messages to preserve verbatim.
    private static let recentToKeep = 6

    private func compactIfNeeded() async throws {
        let conversation = taskMessages.filter { $0.role != .system }
        let totalChars = conversation.reduce(0) { $0 + $1.text.count }
        guard totalChars > Self.compactionCharBudget,
              conversation.count > Self.recentToKeep + 2,
              !settings.apiKey.isEmpty else { return }

        let splitIndex = conversation.count - Self.recentToKeep
        let older = Array(conversation[..<splitIndex])
        let recent = Array(conversation[splitIndex...])

        let transcript = older.map { m in
            let who = m.role == .user ? L("用户", "User") : L("助手", "Assistant")
            return "\(who)：\(Self.apiText(of: m))"
        }.joined(separator: "\n\n")

        let summary = try await summarize(transcript: transcript)
        try Task.checkCancellation()

        taskMessages.insert(
            ChatMessage(role: .system, text: L("🗜️ 已压缩较早的对话以节省上下文", "🗜️ Earlier messages were compacted to save context")),
            at: 0
        )
        var rebuilt: [ChatMessage] = [
            ChatMessage(role: .assistant, text: L("（之前对话的摘要）\n\(summary)", "(Summary of earlier conversation)\n\(summary)"))
        ]
        rebuilt.append(contentsOf: recent)
        // Preserve the compaction marker at the top, then summary + recent.
        taskMessages = [taskMessages[0]] + rebuilt
        saveTaskHistory()
    }

    /// One-shot, non-streaming completion used only for summarization.
    private func summarize(transcript: String) async throws -> String {
        var request = try endpointRequest()
        let instruction = L("请把下面这段助手与用户的对话压缩成简洁的中文要点摘要，保留关键事实、已做的操作、涉及的文件和未决事项，供后续对话参考：\n\n\(transcript)", "Compress the following assistant/user conversation into concise English bullet points, keeping key facts, actions taken, files involved, and open items, for later reference:\n\n\(transcript)")

        if settings.provider.usesOpenAIProtocol {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": settings.model,
                "messages": [["role": "user", "content": instruction]]
            ] as [String: Any])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkStatus(response, data: data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = object?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            return (message?["content"] as? String) ?? L("（摘要为空）", "(empty summary)")
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": settings.model,
                "max_tokens": 1024,
                "messages": [["role": "user", "content": instruction]]
            ] as [String: Any])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkStatus(response, data: data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]]
            let text = content?.compactMap { $0["text"] as? String }.joined()
            return (text?.isEmpty == false ? text! : L("（摘要为空）", "(empty summary)"))
        }
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw APIError.server(status: http.statusCode, body: String(body.prefix(300)))
    }

    /// The panel behaves like a coding agent whose working directory is the
    /// Finder folder the user is looking at.
    private var systemPrompt: String {
        // 用任务捕获的目录/选中集：执行期间显示切走也不改变任务的作用范围。
        let folderDesc = taskFolder?.path ?? "（当前未绑定文件夹，工具不可用）"
        let selectionLine = taskSelection.isEmpty ? "" :
            "\n本对话精准绑定在用户当前选择的这些项目上（选择集合不可扩大或缩小）：\n" +
            taskSelection.map(\.path).joined(separator: "\n")
        return """
        你是嵌在 macOS 访达（Finder）窗口旁的文件与编码助手（当前驱动模型：\(settings.model)。历史消息可能由其他模型生成，被问到身份时以本行为准）。工作方式类似 Claude Code：用户当前打开的文件夹就是你的工作目录：\(folderDesc)。\(selectionLine)

        你的工具（路径一律相对于工作目录）：
        - list_files：浏览目录结构
        - search_files：按正则在文件内容中搜索，返回 文件:行号:内容
        - read_file：读取文本文件内容
        - edit_file：对已有文件做精确字符串替换（首选的修改方式）
        - write_file：创建新文件；目标已存在时默认自动使用 _2、_3 等新名称。只有用户明确要求覆盖该文件时才可传 overwrite=true
        - move_file：移动或重命名文件/文件夹
        - copy_file：复制文件/文件夹
        - trash_file：把文件/文件夹移到废纸篓（可恢复的删除）
        - make_directory：新建文件夹
        - run_command：在工作目录执行一条 zsh 命令（每条命令都需要用户在界面上确认后才会执行）
        - run_skill：运行预置技能脚本（免确认、已验证）。遇到下方技能目录覆盖的任务时优先用它，不要自己写脚本或命令
        - spawn_subagent：派生子代理处理自包含的子任务，只把结论返回给你

        技能目录（run_skill 的 skill 与 args 用法）：
        \(Self.skillsCatalog)

        处理任务的方式：
        - 严格遵守用户指定的对象、页码、数量和输出格式，只做完成请求必需的操作；用户只问一页就只处理该页，绝不能擅自扩展为整个文件或所有页面。
        - 用户消息中列出的“选中/附上的文件”就是本次任务的全部输入范围：任务描述没有点名对象时，对象就是这些文件，而不是所在文件夹；绝不能因为文件夹里其他文件相似、或“批量处理更一致”而扩大到列表之外。
        - 用户只要求查看、读取、分析或回答内容时，直接在聊天中返回结果，不创建文件。转换、压缩、OCR、转写、总结为纪要、差异对比、二维码识别、重命名或去重等动作本身就要求生成可交付文件，聊天文字不能替代产物。
        - 产物的保留、命名、目录去向、覆盖边界与删除/去重安全要求，一律以上方技能目录开头的「全局产物规则」为准；run_skill 传参同样受其约束（--overwrite-original/--in-place 只在用户明确要求覆盖时使用，禁止把 --output 指向输入文件）。
        - 不创建用户没要求的副本、拆分页、逐页图片、全量文本或其他衍生物。工具确需中间文件时只能放系统临时目录，并在结束前清理。
        - 如果目标范围不明确且不同理解会产生不同文件或批量操作，先问一个简短的澄清问题，不要自行选择最大范围。
        - 提取 PDF 文字必须用 pdf-ocr；传入用户指定的 --pages。未要求保存时不要传 --output，也不要先调用 PDF 拆分或转图片技能。
        - 当前内置 API 是纯文本模型，不能查看工具生成的图片画面。不得声称“看到了图片样式”。用户要求高保真复刻 PDF/图片视觉版式，而现有技能不能直接完成时，先如实说明限制并询问是否接受只翻译文字或近似排版；不要把 PDF 转图片当作已经完成视觉检查。
        - 先用 list_files / search_files 定位目标，再用 read_file 查看相关文件，不要凭空猜测文件内容。
        - 只有用户明确要求修改已有文件时才使用 edit_file 或 write_file 的 overwrite=true；否则一律创建唯一的新文件。修改时先读取，然后优先用 edit_file 做精确替换（old_string 必须在文件中唯一）。
        - 批量操作（如批量重命名）先浏览目录确认对象，再逐个执行。
        - 需要运行脚本、git、构建、安装依赖等时用 run_command；命令的工作目录就是绑定文件夹。一次给出完整的一条命令并在 purpose 里说明目的，不要把命令拆碎来规避确认。用户拒绝时尊重决定，改用其他方式或询问。
        - 遇到可以拆分成互不依赖子任务的大工作（如"分别为多个模块生成测试"、"先大范围调研目录结构再动手"），用 spawn_subagent 把子任务外包出去，保持你自己的上下文精简。
        - 只有用户要求的最终文件确实已经生成且工具返回成功，才能说任务完成。预览图、OCR 文本和临时文件都不算最终产物。完成后用一两句话总结做了什么，并明确最终文件名。
        - 与文件无关的普通问题正常回答，不必调用工具。
        - 始终使用与用户消息相同的语言回复（Always respond in the same language the user writes in）。

        如果工具不可用（未绑定文件夹或调用失败），可以退而用如下格式输出文件，界面会显示"创建"按钮：
        ```create-file:相对文件名
        文件完整内容
        ```
        """
    }

    // MARK: Request scaffolding

    private func endpointRequest() throws -> URLRequest {
        guard let url = URL(string: settings.baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if settings.provider.usesOpenAIProtocol {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    /// Maps the UI history into provider format. UI-only rows (.system tool
    /// activity) are excluded — they are not part of the model conversation.
    /// 模型看到的完整用户消息 = 附件上下文 + 正文（界面只显示正文）。
    nonisolated private static func apiText(of message: ChatMessage) -> String {
        var sections: [String] = []
        if let taskID = message.taskID { sections.append("任务编号：\(taskID)") }
        if let context = message.promptContext, !context.isEmpty { sections.append(context) }
        sections.append(message.text)
        return sections.joined(separator: "\n\n---\n\n")
    }

    private func initialAPIMessages(history: [ChatMessage]) -> [[String: Any]] {
        var visible = history.filter { $0.role != .system }
        // A non-vision provider must never see image blocks, including ones
        // left in the conversation from when a vision provider was active.
        if !settings.provider.supportsVision {
            visible = visible.map { message in
                var stripped = message
                stripped.images = []
                return stripped
            }
        }
        if settings.provider.usesOpenAIProtocol {
            var result: [[String: Any]] = [["role": "system", "content": systemPrompt]]
            result += visible.map { message in
                guard !message.images.isEmpty else {
                    return ["role": message.role.rawValue, "content": Self.apiText(of: message)]
                }
                var blocks: [[String: Any]] = message.images.map { image in
                    [
                        "type": "image_url",
                        "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64)"]
                    ]
                }
                blocks.append(["type": "text", "text": Self.apiText(of: message)])
                return ["role": message.role.rawValue, "content": blocks]
            }
            return result
        } else {
            return visible.map { message in
                let role = message.role == .assistant ? "assistant" : "user"
                guard !message.images.isEmpty else {
                    return ["role": role, "content": Self.apiText(of: message)]
                }
                var blocks: [[String: Any]] = message.images.map { image in
                    [
                        "type": "image",
                        "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64]
                    ]
                }
                blocks.append(["type": "text", "text": Self.apiText(of: message)])
                return ["role": role, "content": blocks]
            }
        }
    }

    /// Opens the SSE stream; gateway-class errors (5xx / 529 overloaded) are
    /// retried twice with backoff before surfacing to the user.
    private static func openSSE(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var lastError: Error = APIError.server(status: 0, body: "")
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
                    return bytes
                }
                var body = ""
                for try await line in bytes.lines {
                    body += line
                    if body.count > 2000 { break }
                }
                let error = APIError.server(status: http.statusCode, body: body)
                logFailure(request: request, attempt: attempt, status: http.statusCode, body: body)
                // Retry only transient upstream failures; 4xx are permanent.
                if http.statusCode >= 500 || http.statusCode == 429 {
                    lastError = error
                    continue
                }
                throw error
            } catch let error as APIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                // Connection-level failure: also worth one more attempt.
                logFailure(request: request, attempt: attempt, status: -1, body: String(describing: error))
                lastError = error
            }
        }
        throw lastError
    }

    /// Appends request-failure diagnostics (no payload contents) to
    /// ~/Library/Application Support/FinderSidebar/error.log.
    nonisolated private static func logFailure(request: URLRequest, attempt: Int, status: Int, body: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderSidebar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("error.log")

        let formatter = ISO8601DateFormatter()
        let host = request.url?.host ?? "?"
        let size = request.httpBody?.count ?? 0
        let entry = "[\(formatter.string(from: Date()))] attempt=\(attempt) host=\(host) bodyBytes=\(size) status=\(status)\n\(body.prefix(2000))\n---\n"

        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
    }

    // MARK: Streaming bubble helpers

    private func startBubble() -> UUID {
        let bubble = ChatMessage(role: .assistant, text: "", isStreaming: true)
        taskMessages.append(bubble)
        return bubble.id
    }

    private func appendToBubble(_ id: UUID, _ text: String) {
        guard let i = taskMessages.firstIndex(where: { $0.id == id }) else { return }
        taskMessages[i].text += text
    }

    /// Ends a streaming bubble; removes it entirely if it never got text
    /// (e.g. a round that only called tools).
    private func finishBubble(_ id: UUID) {
        guard let i = taskMessages.firstIndex(where: { $0.id == id }) else { return }
        taskMessages[i].isStreaming = false
        if taskMessages[i].text.isEmpty {
            taskMessages.remove(at: i)
        }
    }

    // MARK: Anthropic turn (Messages API, streaming, tool use)

    private struct PendingToolCall {
        let id: String
        let name: String
        var inputJSON: String = ""
    }

    private func runAnthropicTurn(_ apiMessages: inout [[String: Any]]) async throws -> Bool {
        var request = try endpointRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.model,
            "max_tokens": 8192,
            "stream": true,
            "system": systemPrompt,
            "tools": Self.anthropicTools,
            "messages": apiMessages
        ] as [String: Any])

        let bytes = try await Self.openSSE(request)
        let bubbleID = startBubble()
        defer { finishBubble(bubbleID) }

        var textAccum = ""
        var toolBlocks: [Int: PendingToolCall] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            switch object["type"] as? String {
            case "content_block_start":
                if let index = object["index"] as? Int,
                   let block = object["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use",
                   let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    toolBlocks[index] = PendingToolCall(id: id, name: name)
                }
            case "content_block_delta":
                guard let index = object["index"] as? Int,
                      let delta = object["delta"] as? [String: Any] else { continue }
                if let text = delta["text"] as? String {
                    textAccum += text
                    appendToBubble(bubbleID, text)
                } else if let partial = delta["partial_json"] as? String {
                    toolBlocks[index]?.inputJSON += partial
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            default:
                break
            }
        }

        let calls = toolBlocks.sorted { $0.key < $1.key }.map(\.value)
        guard stopReason == "tool_use", !calls.isEmpty else { return false }

        // Echo the assistant turn (text + tool_use blocks) back to the API,
        // then answer each call with a tool_result.
        var assistantContent: [[String: Any]] = []
        if !textAccum.isEmpty {
            assistantContent.append(["type": "text", "text": textAccum])
        }
        var parsedCalls: [(call: PendingToolCall, input: [String: Any])] = []
        for call in calls {
            let json = call.inputJSON.isEmpty ? "{}" : call.inputJSON
            let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            parsedCalls.append((call, input))
            assistantContent.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
        }
        apiMessages.append(["role": "assistant", "content": assistantContent])

        var results: [[String: Any]] = []
        for (call, input) in parsedCalls {
            activity = Self.toolActivityLabel(call.name, input)
            let output = await executeTool(name: call.name, input: input)
            results.append(["type": "tool_result", "tool_use_id": call.id, "content": output])
        }
        apiMessages.append(["role": "user", "content": results])
        return true
    }

    nonisolated private static let anthropicTools: [[String: Any]] = [
        [
            "name": "list_files",
            "description": "列出工作目录中的文件和子目录",
            "input_schema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "相对路径，省略表示根目录"]],
                "required": [] as [String]
            ]
        ],
        [
            "name": "read_file",
            "description": "读取工作目录内一个文本文件的完整内容",
            "input_schema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "相对路径"]],
                "required": ["path"]
            ]
        ],
        [
            "name": "write_file",
            "description": "在工作目录内创建文本文件。目标已存在时默认自动另存为 _2、_3 等唯一名称；只有用户明确要求覆盖该文件时才可传 overwrite=true。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "相对路径"],
                    "content": ["type": "string", "description": "文件完整内容"],
                    "overwrite": ["type": "boolean", "description": "仅当用户明确要求覆盖现有文件时设为 true；默认 false"]
                ],
                "required": ["path", "content"]
            ]
        ],
        [
            "name": "move_file",
            "description": "移动或重命名工作目录内的文件/文件夹",
            "input_schema": [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "现路径（相对）"],
                    "to": ["type": "string", "description": "新路径（相对）"]
                ],
                "required": ["from", "to"]
            ]
        ],
        [
            "name": "copy_file",
            "description": "复制工作目录内的文件/文件夹",
            "input_schema": [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "源路径（相对）"],
                    "to": ["type": "string", "description": "目标路径（相对）"]
                ],
                "required": ["from", "to"]
            ]
        ],
        [
            "name": "trash_file",
            "description": "把工作目录内的文件/文件夹移到废纸篓（可从废纸篓恢复）",
            "input_schema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "相对路径"]],
                "required": ["path"]
            ]
        ],
        [
            "name": "make_directory",
            "description": "在工作目录内新建文件夹（自动创建中间目录）",
            "input_schema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "相对路径"]],
                "required": ["path"]
            ]
        ],
        [
            "name": "run_command",
            "description": "在工作目录执行一条 zsh 命令（运行脚本、git、构建等）。每条命令都会先请求用户确认，被拒绝时会返回拒绝信息。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "要执行的完整命令"],
                    "purpose": ["type": "string", "description": "一句话说明这条命令的目的（显示给用户）"]
                ],
                "required": ["command"]
            ]
        ],
        [
            "name": "edit_file",
            "description": "对已有文本文件做精确字符串替换。只有用户明确要求修改该文件时才可传 overwrite=true；否则禁止修改。old_string 必须与文件内容完全一致。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "相对路径"],
                    "old_string": ["type": "string", "description": "要被替换的原文（须精确匹配）"],
                    "new_string": ["type": "string", "description": "替换后的内容"],
                    "replace_all": ["type": "boolean", "description": "是否替换所有出现，默认 false"],
                    "overwrite": ["type": "boolean", "description": "用户明确要求修改现有文件时必须设为 true"]
                ],
                "required": ["path", "old_string", "new_string"]
            ]
        ],
        [
            "name": "search_files",
            "description": "在工作目录的文本文件内容中按正则表达式搜索，返回 文件:行号:行内容 列表",
            "input_schema": [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "正则表达式"],
                    "path": ["type": "string", "description": "限定搜索的子目录（相对路径），省略为整个工作目录"]
                ],
                "required": ["pattern"]
            ]
        ],
        [
            "name": "run_skill",
            "description": "运行一个预置技能脚本（批量重命名、PDF/Excel/图片/音视频处理、OCR、压缩包等，见系统提示中的技能目录）。默认保留原文件和全部历史产物，并使用唯一的新文件名；只有用户明确要求覆盖时才可传 --overwrite-original。比自己写命令更快更可靠，且无需用户确认。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "skill": ["type": "string", "description": "技能名（如 img-compress）"],
                    "args": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "参数列表，按技能目录中的用法逐个传（文件路径相对工作目录）"
                    ]
                ],
                "required": ["skill"]
            ]
        ],
        [
            "name": "spawn_subagent",
            "description": "派生一个独立的子代理来完成一个自包含的子任务（如'分析 src 目录的结构'或'为每个模块写单元测试'）。子代理拥有独立的对话上下文和相同的文件工具（但不能执行命令或再派生子代理），完成后只把最终结论返回给你。适合把大任务拆成互不依赖的小块，或隔离掉会产生大量中间输出的探索工作。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "交给子代理的完整任务描述，必须自包含（子代理看不到当前对话）"]
                ],
                "required": ["task"]
            ]
        ]
    ]

    // MARK: OpenAI-compatible turn (Chat Completions, streaming, tool calls)

    private func runOpenAITurn(_ apiMessages: inout [[String: Any]]) async throws -> Bool {
        var request = try endpointRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.model,
            "stream": true,
            "tools": Self.openAITools,
            "messages": apiMessages
        ] as [String: Any])

        let bytes = try await Self.openSSE(request)
        let bubbleID = startBubble()
        defer { finishBubble(bubbleID) }

        var textAccum = ""
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (object["choices"] as? [[String: Any]])?.first else { continue }

            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let text = delta["content"] as? String {
                textAccum += text
                appendToBubble(bubbleID, text)
            }
            for item in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = item["index"] as? Int ?? 0
                var entry = toolCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = item["id"] as? String { entry.id = id }
                if let function = item["function"] as? [String: Any] {
                    if let name = function["name"] as? String { entry.name += name }
                    if let args = function["arguments"] as? String { entry.arguments += args }
                }
                toolCalls[index] = entry
            }
        }

        let calls = toolCalls.sorted { $0.key < $1.key }.map(\.value)
        if calls.isEmpty {
            guard textAccum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let retryMarker = "[系统] 上一轮模型没有返回任何文字或工具调用。请继续当前任务；如果无法完成，请明确说明原因，不要返回空内容。"
            if apiMessages.contains(where: { ($0["content"] as? String) == retryMarker }) {
                throw APIError.server(status: 0, body: L("DeepSeek 连续返回空内容，请重试本条消息", "DeepSeek returned empty output twice; please retry"))
            }
            apiMessages.append(["role": "user", "content": retryMarker])
            return true
        }

        var assistantMessage: [String: Any] = [
            "role": "assistant",
            "tool_calls": calls.map {
                [
                    "id": $0.id,
                    "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments]
                ] as [String: Any]
            }
        ]
        if !textAccum.isEmpty { assistantMessage["content"] = textAccum }
        apiMessages.append(assistantMessage)

        for call in calls {
            let input = (try? JSONSerialization.jsonObject(
                with: Data((call.arguments.isEmpty ? "{}" : call.arguments).utf8)
            )) as? [String: Any] ?? [:]
            activity = Self.toolActivityLabel(call.name, input)
            let output = await executeTool(name: call.name, input: input)
            apiMessages.append(["role": "tool", "tool_call_id": call.id, "content": output])
        }
        return true
    }

    nonisolated private static let openAITools: [[String: Any]] = anthropicTools.map { tool in
        [
            "type": "function",
            "function": [
                "name": tool["name"] as? String ?? "",
                "description": tool["description"] as? String ?? "",
                "parameters": tool["input_schema"] as Any
            ]
        ]
    }

    // MARK: Tool execution (cwd = bound folder)

    nonisolated private static func toolActivityLabel(_ name: String, _ input: [String: Any]) -> String {
        let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let from = input["from"] as? String ?? "?"
        let to = input["to"] as? String ?? "?"
        switch name {
        case "list_files": return L("🔍 浏览 \(path)", "🔍 Browsing \(path)")
        case "read_file": return L("📖 读取 \(path)", "📖 Reading \(path)")
        case "write_file": return L("✏️ 写入 \(path)", "✏️ Writing \(path)")
        case "move_file": return L("📛 移动 \(from) → \(to)", "📛 Moving \(from) → \(to)")
        case "copy_file": return L("📋 复制 \(from) → \(to)", "📋 Copying \(from) → \(to)")
        case "trash_file": return L("🗑️ 废纸篓 \(path)", "🗑️ Trashing \(path)")
        case "make_directory": return L("📁 新建目录 \(path)", "📁 Creating \(path)")
        case "run_command":
            let cmd = input["command"] as? String ?? "?"
            return "💻 $ \(cmd.count > 80 ? String(cmd.prefix(80)) + "…" : cmd)"
        case "edit_file": return L("🪛 编辑 \(path)", "🪛 Editing \(path)")
        case "search_files":
            let pattern = input["pattern"] as? String ?? "?"
            return L("🔎 搜索 \(pattern)", "🔎 Searching \(pattern)")
        case "spawn_subagent":
            let task = input["task"] as? String ?? ""
            return L("🤖 子代理：", "🤖 Subagent: ") + (task.count > 60 ? String(task.prefix(60)) + "…" : task)
        case "run_skill":
            return L("🧰 技能 ", "🧰 Skill ") + (input["skill"] as? String ?? "?")
        default: return "🔧 \(name)"
        }
    }

    /// Resolves a tool-supplied relative path, refusing anything that
    /// escapes the bound folder.
    private func resolveInFolder(_ relative: String) -> URL? {
        guard let folder = taskFolder else { return nil }
        let target = folder.appendingPathComponent(relative).standardizedFileURL
        let root = folder.standardizedFileURL.path
        guard target.path == root || target.path.hasPrefix(root + "/") else { return nil }
        return target
    }

    private func executeTool(name: String, input: [String: Any]) async -> String {
        guard let folder = taskFolder else { return "错误：当前未绑定文件夹，无法使用文件工具" }
        let path = (input["path"] as? String) ?? ""

        if name == "run_command" {
            guard let command = input["command"] as? String, !command.isEmpty else {
                return "错误：缺少 command 参数"
            }
            // Claude Code-style approval modes: ask every time, auto-allow
            // read-only commands, or full auto (YOLO).
            let approved: Bool
            switch settings.approvalMode {
            case .yolo:
                approved = true
            case .safeAuto where Self.isReadOnlyCommand(command):
                approved = true
            default:
                approved = await withCheckedContinuation { continuation in
                    pendingCommand = PendingCommand(
                        command: command,
                        purpose: input["purpose"] as? String,
                        continuation: continuation
                    )
                }
            }
            guard approved else {
                return "用户拒绝执行该命令。请尊重用户决定，不要重复请求同一命令。"
            }
            activity = "执行命令中…"
            let output = await Self.runShell(command, cwd: folder)
            return output
        }

        if name == "run_skill" {
            guard let skill = input["skill"] as? String, !skill.isEmpty else {
                return "错误：缺少 skill 参数"
            }
            let skillArgs = (input["args"] as? [String]) ?? []
            return await Self.runSkill(skill: skill, args: skillArgs, cwd: folder)
        }

        if name == "spawn_subagent" {
            guard let task = input["task"] as? String, !task.isEmpty else {
                return "错误：缺少 task 参数"
            }
            do {
                return try await runSubagent(task: task)
            } catch is CancellationError {
                return "子代理被取消"
            } catch {
                return "子代理失败：\(describe(error))"
            }
        }

        switch name {
        case "list_files":
            guard let dir = resolveInFolder(path.isEmpty ? "." : path) else { return "错误：路径越界" }
            return Self.listFiles(in: dir)

        case "read_file":
            guard !path.isEmpty, let file = resolveInFolder(path) else { return "错误：路径无效或越界" }
            guard let data = FileManager.default.contents(atPath: file.path) else { return "错误：文件不存在或不可读" }
            guard data.count <= 200_000 else { return "错误：文件过大（\(data.count) 字节，上限 200KB）" }
            guard let text = String(data: data, encoding: .utf8) else { return "错误：不是 UTF-8 文本文件" }
            return text

        case "write_file":
            guard !path.isEmpty, let requested = resolveInFolder(path) else { return "错误：路径无效或越界" }
            guard let content = input["content"] as? String else { return "错误：缺少 content 参数" }
            let overwrite = (input["overwrite"] as? Bool) ?? false
            do {
                try FileManager.default.createDirectory(
                    at: requested.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = Data(content.utf8)
                if overwrite {
                    try data.write(to: requested, options: .atomic)
                    return "已写入 \(requested.lastPathComponent)（\(content.utf8.count) 字节）"
                }
                let directory = requested.deletingLastPathComponent()
                let ext = requested.pathExtension
                let stem = requested.deletingPathExtension().lastPathComponent
                let temporary = directory.appendingPathComponent(".folderis-\(UUID().uuidString).tmp")
                try data.write(to: temporary, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporary) }
                for index in 1..<10_000 {
                    let name: String
                    if index == 1 {
                        name = requested.lastPathComponent
                    } else {
                        name = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
                    }
                    let candidate = directory.appendingPathComponent(name)
                    let result = temporary.withUnsafeFileSystemRepresentation { sourcePath in
                        candidate.withUnsafeFileSystemRepresentation { destinationPath in
                            guard let sourcePath, let destinationPath else { return Int32(-1) }
                            return Darwin.link(sourcePath, destinationPath)
                        }
                    }
                    if result == 0 {
                        return "已写入 \(candidate.lastPathComponent)（\(content.utf8.count) 字节）"
                    }
                    let errorCode = errno
                    if errorCode == EEXIST { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                return "错误：无法生成不重复的文件名"
            } catch {
                return "写入失败：\(error.localizedDescription)"
            }

        case "move_file":
            guard let fromPath = input["from"] as? String, !fromPath.isEmpty,
                  let toPath = input["to"] as? String, !toPath.isEmpty,
                  let source = resolveInFolder(fromPath),
                  let destination = resolveInFolder(toPath) else { return "错误：路径无效或越界" }
            guard FileManager.default.fileExists(atPath: source.path) else { return "错误：\(fromPath) 不存在" }
            guard !FileManager.default.fileExists(atPath: destination.path) else { return "错误：\(toPath) 已存在" }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: source, to: destination)
                return "已移动 \(fromPath) → \(toPath)"
            } catch {
                return "移动失败：\(error.localizedDescription)"
            }

        case "copy_file":
            guard let fromPath = input["from"] as? String, !fromPath.isEmpty,
                  let toPath = input["to"] as? String, !toPath.isEmpty,
                  let source = resolveInFolder(fromPath),
                  let destination = resolveInFolder(toPath) else { return "错误：路径无效或越界" }
            guard FileManager.default.fileExists(atPath: source.path) else { return "错误：\(fromPath) 不存在" }
            guard !FileManager.default.fileExists(atPath: destination.path) else { return "错误：\(toPath) 已存在" }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
                return "已复制 \(fromPath) → \(toPath)"
            } catch {
                return "复制失败：\(error.localizedDescription)"
            }

        case "trash_file":
            guard !path.isEmpty, let file = resolveInFolder(path) else { return "错误：路径无效或越界" }
            guard FileManager.default.fileExists(atPath: file.path) else { return "错误：\(path) 不存在" }
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                return "已把 \(path) 移到废纸篓（可恢复）"
            } catch {
                return "移到废纸篓失败：\(error.localizedDescription)"
            }

        case "make_directory":
            guard !path.isEmpty, let dir = resolveInFolder(path) else { return "错误：路径无效或越界" }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return "已创建目录 \(path)"
            } catch {
                return "创建目录失败：\(error.localizedDescription)"
            }

        case "edit_file":
            guard !path.isEmpty, let file = resolveInFolder(path) else { return "错误：路径无效或越界" }
            guard (input["overwrite"] as? Bool) == true else {
                return "错误：修改已有文件需要用户明确授权，并传 overwrite=true"
            }
            guard let oldString = input["old_string"] as? String, !oldString.isEmpty,
                  let newString = input["new_string"] as? String else { return "错误：缺少 old_string / new_string" }
            guard let data = FileManager.default.contents(atPath: file.path),
                  let text = String(data: data, encoding: .utf8) else { return "错误：文件不存在或不是 UTF-8 文本" }

            let occurrences = text.components(separatedBy: oldString).count - 1
            if occurrences == 0 {
                return "错误：文件中找不到 old_string，请先 read_file 核对内容（注意空格和缩进必须完全一致）"
            }
            let replaceAll = input["replace_all"] as? Bool ?? false
            if occurrences > 1 && !replaceAll {
                return "错误：old_string 出现了 \(occurrences) 次。请增加上下文使其唯一，或传 replace_all: true"
            }
            let updated: String
            if replaceAll {
                updated = text.replacingOccurrences(of: oldString, with: newString)
            } else if let range = text.range(of: oldString) {
                updated = text.replacingCharacters(in: range, with: newString)
            } else {
                return "错误：替换失败"
            }
            do {
                try Data(updated.utf8).write(to: file, options: .atomic)
                return "已编辑 \(path)（替换 \(replaceAll ? occurrences : 1) 处）"
            } catch {
                return "写入失败：\(error.localizedDescription)"
            }

        case "search_files":
            guard let pattern = input["pattern"] as? String, !pattern.isEmpty else { return "错误：缺少 pattern" }
            let sub = (input["path"] as? String) ?? ""
            guard let dir = resolveInFolder(sub.isEmpty ? "." : sub) else { return "错误：路径越界" }
            return Self.searchFiles(pattern: pattern, in: dir)

        default:
            return "错误：未知工具 \(name)"
        }
    }

    // MARK: - Subagent (nested non-streaming agent loop)

    /// File tools available to subagents: everything except run_command and
    /// spawn_subagent (no shell, no recursion).
    nonisolated private static let subagentTools: [[String: Any]] = anthropicTools.filter {
        let name = $0["name"] as? String
        return name != "run_command" && name != "spawn_subagent"
    }

    nonisolated private static let subagentOpenAITools: [[String: Any]] = subagentTools.map { tool in
        [
            "type": "function",
            "function": [
                "name": tool["name"] as? String ?? "",
                "description": tool["description"] as? String ?? "",
                "parameters": tool["input_schema"] as Any
            ]
        ]
    }

    /// Runs a self-contained subtask in its own conversation, then returns its
    /// final text. Non-streaming: subagent chatter doesn't clutter the panel;
    /// only its start/finish and its own tool activity are surfaced.
    private func runSubagent(task: String) async throws -> String {
        guard let folder = taskFolder else { return "错误：未绑定文件夹" }
        let subSystem = """
        你是一个子代理，工作目录：\(folder.path)。独立完成下面这个任务，可以使用文件工具（浏览、搜索、读、精确编辑、写、移动、复制、建目录）。完成后用简洁的中文给出结论和你做过的关键操作——这段结论会返回给主代理，所以要自包含。
        """

        // Register live status; removed when the subagent finishes.
        let statusID = UUID()
        subagents.append(SubagentStatus(id: statusID, task: task, round: 0, lastAction: "启动中…"))
        defer { subagents.removeAll { $0.id == statusID } }

        func updateStatus(round: Int? = nil, action: String? = nil) {
            guard let i = subagents.firstIndex(where: { $0.id == statusID }) else { return }
            if let round { subagents[i].round = round }
            if let action { subagents[i].lastAction = action }
        }

        if settings.provider.usesOpenAIProtocol {
            var msgs: [[String: Any]] = [
                ["role": "system", "content": subSystem],
                ["role": "user", "content": task]
            ]
            for round in 0..<20 {
                try Task.checkCancellation()
                updateStatus(round: round + 1, action: "思考中…")
                var request = try endpointRequest()
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": settings.model,
                    "tools": Self.subagentOpenAITools,
                    "messages": msgs
                ] as [String: Any])
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.checkStatus(response, data: data)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let choice = (object?["choices"] as? [[String: Any]])?.first,
                      let message = choice["message"] as? [String: Any] else { return "（子代理无响应）" }

                let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
                let content = message["content"] as? String ?? ""
                if toolCalls.isEmpty { return content.isEmpty ? "（子代理未产出结论）" : content }

                msgs.append(message)
                for call in toolCalls {
                    let fn = call["function"] as? [String: Any]
                    let name = fn?["name"] as? String ?? ""
                    let args = fn?["arguments"] as? String ?? "{}"
                    let toolInput = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
                    updateStatus(action: Self.toolActivityLabel(name, toolInput))
                    let output = await executeTool(name: name, input: toolInput)
                    msgs.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": output])
                }
            }
            return "子代理达到步数上限，未得出最终结论"
        } else {
            var msgs: [[String: Any]] = [["role": "user", "content": task]]
            for round in 0..<20 {
                try Task.checkCancellation()
                updateStatus(round: round + 1, action: "思考中…")
                var request = try endpointRequest()
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": settings.model,
                    "max_tokens": 8192,
                    "system": subSystem,
                    "tools": Self.subagentTools,
                    "messages": msgs
                ] as [String: Any])
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.checkStatus(response, data: data)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let content = object?["content"] as? [[String: Any]] else { return "（子代理无响应）" }

                let stopReason = object?["stop_reason"] as? String
                let textOut = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                let toolUses = content.filter { $0["type"] as? String == "tool_use" }

                if stopReason != "tool_use" || toolUses.isEmpty {
                    return textOut.isEmpty ? "（子代理未产出结论）" : textOut
                }

                msgs.append(["role": "assistant", "content": content])
                var results: [[String: Any]] = []
                for tu in toolUses {
                    let name = tu["name"] as? String ?? ""
                    let toolInput = tu["input"] as? [String: Any] ?? [:]
                    updateStatus(action: Self.toolActivityLabel(name, toolInput))
                    let output = await executeTool(name: name, input: toolInput)
                    results.append(["type": "tool_result", "tool_use_id": tu["id"] as? String ?? "", "content": output])
                }
                msgs.append(["role": "user", "content": results])
            }
            return "子代理达到步数上限，未得出最终结论"
        }
    }

    nonisolated private static func searchFiles(pattern: String, in dir: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return "错误：正则表达式无效"
        }
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "错误：无法读取目录" }

        let skippedDirs: Set<String> = ["node_modules", ".git", ".build", "dist", "build", "__pycache__"]
        var hits: [String] = []
        var scanned = 0
        let rootPath = dir.path

        for case let url as URL in enumerator {
            if enumerator.level > 6 { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirs.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard (values?.fileSize ?? 0) <= 512_000 else { continue }
            scanned += 1
            if scanned > 2000 { hits.append("…（已扫描 2000 个文件，提前停止）"); break }

            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let rel = String(url.path.dropFirst(rootPath.count + 1))
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                let range = NSRange(location: 0, length: (lineStr as NSString).length)
                if regex.firstMatch(in: lineStr, range: range) != nil {
                    let trimmed = lineStr.count > 200 ? String(lineStr.prefix(200)) + "…" : lineStr
                    hits.append("\(rel):\(number + 1): \(trimmed.trimmingCharacters(in: .whitespaces))")
                    if hits.count >= 100 {
                        hits.append("…（结果超过 100 条，已截断）")
                        return hits.joined(separator: "\n")
                    }
                }
            }
        }
        return hits.isEmpty ? "没有匹配结果" : hits.joined(separator: "\n")
    }

    /// TCC 保护目录（桌面/文稿/下载）无权限时 enumerator 会静默返回空，
    /// 必须先用会抛错的 API 试探，把"没权限"和"真是空的"区分开。
    nonisolated private static func accessDeniedHint(for dir: URL) -> String? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return nil
        } catch {
            return L("错误：无法访问 \(dir.lastPathComponent)（\(error.localizedDescription)）。请告知用户：需要在 系统设置 → 隐私与安全性 → 文件和文件夹 中允许 Folderis 访问该文件夹（桌面/文稿/下载各自独立授权），或直接授予完全磁盘访问权限。",
                     "Error: cannot access \(dir.lastPathComponent) (\(error.localizedDescription)). Tell the user: allow Folderis to access this folder in System Settings → Privacy & Security → Files and Folders (Desktop/Documents/Downloads are granted separately), or grant Full Disk Access.")
        }
    }

    nonisolated private static func listFiles(in dir: URL) -> String {
        if let denied = accessDeniedHint(for: dir) { return denied }
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "错误：无法读取目录" }

        var lines: [String] = []
        let rootPath = dir.path
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let rel = String(url.path.dropFirst(rootPath.count + 1))
            if values?.isDirectory == true {
                lines.append("\(rel)/")
            } else {
                lines.append("\(rel) (\(values?.fileSize ?? 0) 字节)")
            }
            if lines.count >= 300 {
                lines.append("…（已截断，超过 300 项）")
                break
            }
        }
        return lines.isEmpty ? "（空目录）" : lines.joined(separator: "\n")
    }

    // MARK: Skills (pre-audited scripts; run without confirmation)

    nonisolated static let supportRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FinderSidebar", isDirectory: true)

    /// Compact skill catalog injected into the system prompt (loaded once).
    nonisolated static let skillsCatalog: String = {
        let url = supportRoot.appendingPathComponent("skills/catalog.txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// 共享产物政策的唯一来源：catalog.txt 中以「全局产物规则：」开头的整段。
    /// 按稳定标记提取而非物理行号，catalog 未来加注释/版本头也不受影响。
    nonisolated static let artifactPolicyMarker = "全局产物规则："

    nonisolated static func extractArtifactPolicy(from catalog: String) -> String? {
        guard let range = catalog.range(of: artifactPolicyMarker) else { return nil }
        let segment = catalog[range.lowerBound...].prefix(while: { $0 != "\n" })
        let policy = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
        // 语义完整性下限：防止截断/损坏的 catalog 提供半句政策。
        let required = ["原文件", "Output", "覆盖", "副本"]
        guard policy.count > 80, required.allSatisfy(policy.contains) else { return nil }
        return policy
    }

    /// nil 意味着技能运行时损坏——按约定拒绝文件处理任务而不是无政策裸跑。
    nonisolated static let sharedArtifactPolicy: String? = extractArtifactPolicy(from: skillsCatalog)

    /// 打包分发的独立 Python 优先；开发机的 venv 作为后备。
    nonisolated static var skillsPython: URL {
        let bundled = supportRoot.appendingPathComponent("python/bin/python3")
        let venv = supportRoot.appendingPathComponent("venv/bin/python3")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : venv
    }

    /// CLI 后端的技能简报（ROADMAP P1：技能目录经 --append-system-prompt 注入）。
    /// 外部代理没有内置工具循环，必须显式告知调用方式与组件安装的同意边界，
    /// 否则会徒手重写技能甚至擅自 brew install 系统软件。
    nonisolated static let cliSkillsBrief: String = {
        guard !skillsCatalog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let python = skillsPython.path
        let toolbox = supportRoot.appendingPathComponent("skills/skills.py").path
        guard FileManager.default.fileExists(atPath: python),
              FileManager.default.fileExists(atPath: toolbox) else { return "" }
        let bin = supportRoot.appendingPathComponent("bin").path
        // PATH 承诺行与实际注入（runCLIBackendTurn）同一存在性条件，不做空头承诺。
        let binLine = FileManager.default.fileExists(atPath: bin)
            ? "专用工具目录（ffmpeg/ffprobe/pngquant/pdfrender）已加入 PATH：\(bin)\n"
            : ""
        return """
        Folderis 内置技能工具箱：涉及下列技能覆盖的文件处理时必须优先调用，禁止另写脚本重复实现，也禁止未经用户明确同意安装任何系统软件（brew/pip/npm 等同样受限；可选组件一律先征求用户同意，经 install-component 安装）。
        调用方式（Bash 中执行，cwd 即任务文件夹）：
        "\(python)" "\(toolbox)" <技能名> <参数…>
        \(binLine)\(skillsCatalog)
        """
    }()

    /// local-dispatch 匹配成功后立即上报执行阶段的行前缀（与 skills.py 约定）。
    nonisolated static let localStageMarker = "__FOLDERIS_LOCAL_STAGE__"

    nonisolated private static func runSkill(
        skill: String, args: [String], cwd: URL,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        let python = skillsPython
        let toolbox = supportRoot.appendingPathComponent("skills/skills.py")
        guard FileManager.default.fileExists(atPath: python.path),
              FileManager.default.fileExists(atPath: toolbox.path) else {
            return "错误：技能运行时未安装（缺少 Python 运行时或 skills.py）"
        }
        let handle = SkillProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = python
                process.arguments = [toolbox.path, skill] + args
                process.currentDirectoryURL = cwd

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                guard handle.install(process) else {
                    continuation.resume(returning: "（已停止）")
                    return
                }
                defer { handle.clear() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "技能启动失败：\(error.localizedDescription)")
                    return
                }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)

                var data: Data
                if let onStage {
                    // 边跑边读：技能执行可能持续数分钟，stage 标记行要即时
                    // 送达界面，不能等 readDataToEndOfFile。
                    data = Data()
                    var lineBuffer = Data()
                    let markerData = Data(localStageMarker.utf8)
                    let reader = pipe.fileHandleForReading
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        data.append(chunk)
                        lineBuffer.append(chunk)
                        while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let line = lineBuffer[lineBuffer.startIndex..<newline]
                            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
                            guard line.starts(with: markerData) else { continue }
                            let stage = String(decoding: line.dropFirst(markerData.count), as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !stage.isEmpty { onStage(stage) }
                        }
                    }
                } else {
                    data = pipe.fileHandleForReading.readDataToEndOfFile()
                }
                process.waitUntilExit()
                killer.cancel()

                if data.count > 30_000 {
                    data = data.prefix(30_000) + Data("\n…（输出已截断）".utf8)
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                let status = process.terminationStatus == 0 ? "" : "（exit \(process.terminationStatus)）"
                continuation.resume(returning: text.isEmpty ? "（无输出）\(status)" : text + status)
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Conservative read-only classifier for the "只读命令自动允许" mode:
    /// single command (no chaining/redirection), first word in a whitelist;
    /// git/xcodebuild restricted to their read-only subcommands.
    nonisolated static func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Any chaining, redirection, or substitution disqualifies.
        let forbidden = [";", "&&", "||", ">", "<", "`", "$(", "|", "\n"]
        if forbidden.contains(where: { trimmed.contains($0) }) { return false }

        let words = trimmed.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }

        let simpleSafe: Set<String> = [
            "ls", "pwd", "cat", "head", "tail", "wc", "file", "stat",
            "du", "df", "which", "whoami", "date", "uname", "find",
            "grep", "rg", "tree", "basename", "dirname", "md5", "shasum"
        ]
        if simpleSafe.contains(first) {
            // find can execute or delete via flags.
            if first == "find" && (trimmed.contains("-exec") || trimmed.contains("-delete")) {
                return false
            }
            return true
        }
        if first == "git", words.count >= 2 {
            let readOnly: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "shortlog", "blame"]
            return readOnly.contains(words[1])
        }
        return false
    }

    /// Runs one zsh command with the bound folder as cwd. Combined
    /// stdout+stderr is capped at 50KB; commands are killed after 120s.
    nonisolated private static func runShell(_ command: String, cwd: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = cwd

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "命令启动失败：\(error.localizedDescription)")
                    return
                }

                var timedOut = false
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)

                // Read to EOF first (returns when the process closes its
                // output), THEN wait — avoids pipe-buffer deadlock on
                // commands with large output.
                var data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()

                if data.count > 50_000 {
                    data = data.prefix(50_000) + Data("\n…（输出已截断）".utf8)
                }
                let text = String(data: data, encoding: .utf8) ?? "（输出不是 UTF-8 文本）"
                var result = "exit \(process.terminationStatus)"
                if timedOut { result += "（超时 120 秒被终止）" }
                result += "\n" + text
                return continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Per-folder history persistence (text only; images not persisted)

    private struct PersistedHistory: Codable {
        struct Item: Codable {
            let role: String
            let text: String
            var promptContext: String?
            var taskID: String?
        }
        /// Original folder path, for human inspection of the storage dir.
        let folder: String?
        /// Exact selected paths; nil/empty means the folder binding.
        var selection: [String]?
        /// Optional so legacy single-conversation files still decode.
        var title: String?
        var updatedAt: Date?
        var backendSessions: [String: String]?
        let items: [Item]
    }

    nonisolated private static let historyDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderSidebar/histories", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private struct PersistedTask: Codable {
        let id: String
        let text: String
        let folder: String?
        let selection: [String]?
        let conversationID: String
        let createdAt: Date
    }

    nonisolated private static let taskDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderSidebar/tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let taskDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    private func nextTaskID() -> String {
        let day = Self.taskDateFormatter.string(from: Date())
        let prefix = "F-\(day)-"
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: Self.taskDir, includingPropertiesForKeys: nil)) ?? []
        var counter = existing.compactMap { file -> Int? in
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count))
        }.max() ?? 0
        while true {
            counter += 1
            let candidate = String(format: "F-%@-%03d", day, counter)
            let path = Self.taskDir.appendingPathComponent("\(candidate).json").path
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return candidate
            }
            guard errno == EEXIST else {
                // The registry is diagnostic metadata; keep task submission
                // usable even if its directory is temporarily unwritable.
                return String(format: "F-%@-%06d", day, Int.random(in: 100_000...999_999))
            }
        }
    }

    private func referencedTaskContext(in text: String) -> String? {
        let pattern = #"(?i)\bF-\d{6}-\d{3,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let requestedID = String(text[range]).uppercased()
        guard let task = findTask(requestedID) else {
            return "用户引用了任务 \(requestedID)，但本机历史中没有找到该编号。请明确告知用户编号未找到，不要猜测任务内容。"
        }
        let binding: String
        if let selection = task.selection, !selection.isEmpty {
            binding = selection.joined(separator: "\n")
        } else {
            binding = task.folder ?? "未记录"
        }
        return """
        用户引用了历史任务 \(requestedID)。
        原始需求：\(task.text)
        当时绑定：\(binding)
        请结合用户当前消息继续或排查该任务；如果当前绑定不同，不要擅自操作旧路径，先说明差异。
        """
    }

    nonisolated static func taskWorkingDirectory(boundFolder: URL?, attachments: [URL]) -> URL? {
        let parents = Set(attachments.map {
            $0.standardizedFileURL.deletingLastPathComponent().path
        })
        if parents.count == 1, let parent = parents.first {
            return URL(fileURLWithPath: parent, isDirectory: true).standardizedFileURL
        }
        return boundFolder?.standardizedFileURL
    }

    private func registerTask(_ taskID: String, text: String, folder: URL?, selection: [URL]) {
        let task = PersistedTask(
            id: taskID,
            text: text,
            folder: folder?.path,
            selection: selection.isEmpty ? nil : selection.map(\.path),
            conversationID: conversationID.uuidString,
            createdAt: Date()
        )
        guard let data = try? JSONEncoder().encode(task) else { return }
        try? data.write(to: Self.taskDir.appendingPathComponent("\(taskID).json"), options: .atomic)
    }

    private func findTask(_ taskID: String) -> (text: String, folder: String?, selection: [String]?)? {
        let taskFile = Self.taskDir.appendingPathComponent("\(taskID.uppercased()).json")
        if let data = try? Data(contentsOf: taskFile),
           let task = try? JSONDecoder().decode(PersistedTask.self, from: data) {
            return (task.text, task.folder, task.selection)
        }
        if let message = messages.first(where: {
            $0.role == .user && $0.taskID?.caseInsensitiveCompare(taskID) == .orderedSame
        }) {
            return (message.text, boundFolder?.path,
                    boundSelection.isEmpty ? nil : boundSelection.map(\.path))
        }

        guard let enumerator = FileManager.default.enumerator(
            at: Self.historyDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let file as URL in enumerator where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(PersistedHistory.self, from: data),
                  let item = payload.items.first(where: {
                      $0.role == ChatMessage.Role.user.rawValue &&
                      $0.taskID?.caseInsensitiveCompare(taskID) == .orderedSame
                  }) else { continue }
            return (item.text, payload.folder, payload.selection)
        }
        return nil
    }

    /// 文件身份 token：设备号 + inode，重命名/同卷移动后保持不变；
    /// 取不到时（如目标暂不可达的网络卷）退回绝对路径。
    nonisolated private static func bindingToken(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let device = (attrs?[.systemNumber] as? NSNumber)?.uint64Value,
           let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value {
            return "id:\(device)-\(inode)"
        }
        return url.path
    }

    /// 会话目录 key：对绑定目标逐项取 token 后哈希。token 传
    /// `bindingToken`（身份，正常路径）或 `{ $0.path }`（旧版路径 key，
    /// 仅用于存量迁移）。
    /// sortTokens: 身份 key 必须传 true——多选的 token 按自身排序后哈希，
    /// 与路径字典序解耦（重命名改变选中项排序也不换 key）。旧版路径 key
    /// 按 boundSelection 原有次序串接，legacy 迁移计算时保持 false 以复现旧算法。
    nonisolated private static func historyKey(
        folder: URL?, selection: [URL], file: URL?,
        token: (URL) -> String,
        sortTokens: Bool = false
    ) -> String {
        let basis: String
        if selection.count == 1, let file {
            basis = "file:" + token(file)
        } else if !selection.isEmpty {
            var tokens = selection.map(token)
            if sortTokens { tokens.sort() }
            basis = "selection:" + tokens.joined(separator: "\n")
        } else if let folder {
            basis = token(folder)
        } else {
            return "global"
        }
        let digest = SHA256.hash(data: Data(basis.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    /// Directory holding all conversations of the current folder.
    /// Key 在绑定建立时算好并缓存在 boundKey：目标随后被重命名也不换目录。
    private var folderDir: URL {
        Self.historyDir.appendingPathComponent(boundKey, isDirectory: true)
    }

    private func conversationFileURL(_ id: UUID) -> URL {
        folderDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Loads the folder's conversation list and opens the most recent one
    /// (or starts fresh if the folder has none).
    private func loadFolder() {
        migratePathKeyDirIfNeeded()
        try? FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        migrateLegacyHistoryIfNeeded()
        refreshConversationList()
        refreshCCSessionList()
        if let latest = conversationList.first {
            openConversation(latest.id)
        } else {
            conversationID = UUID()
            messages = []
            backendSessionIDs = [:]
        }
    }

    private func openConversation(_ id: UUID) {
        guard let data = try? Data(contentsOf: conversationFileURL(id)),
              let payload = try? JSONDecoder().decode(PersistedHistory.self, from: data) else {
            conversationID = UUID()
            messages = []
            return
        }
        conversationID = id
        backendSessionIDs = payload.backendSessions ?? [:]
        messages = payload.items.compactMap { item in
            guard let role = ChatMessage.Role(rawValue: item.role) else { return nil }
            return ChatMessage(role: role, taskID: item.taskID, text: item.text,
                               promptContext: item.promptContext)
        }
    }

    private func saveHistory() {
        persistHistory(messages: messages, key: boundKey, id: conversationID,
                       folder: boundFolder, selection: boundSelection,
                       sessions: backendSessionIDs)
    }

    /// 任务侧落盘：任务会话被切到后台时按其捕获的身份写盘，前台时同 saveHistory。
    private func saveTaskHistory() {
        if let run = detachedRun {
            persistHistory(messages: run.messages, key: run.key, id: run.conversationID,
                           folder: run.folder, selection: run.selection,
                           sessions: run.sessions)
        } else {
            saveHistory()
        }
    }

    private func persistHistory(messages: [ChatMessage], key: String, id: UUID,
                                folder: URL?, selection: [URL], sessions: [String: String]) {
        let dir = Self.historyDir.appendingPathComponent(key, isDirectory: true)
        let fileURL = dir.appendingPathComponent("\(id.uuidString).json")
        // An empty conversation isn't worth a file (also handles "清空对话").
        let meaningful = messages.contains { $0.role != .system }
        guard meaningful else {
            try? FileManager.default.removeItem(at: fileURL)
            refreshConversationList()
            return
        }
        let payload = PersistedHistory(
            folder: folder?.path,
            selection: selection.isEmpty ? nil : selection.map(\.path),
            title: Self.deriveTitle(from: messages),
            updatedAt: Date(),
            backendSessions: sessions.isEmpty ? nil : sessions,
            items: messages.map { .init(role: $0.role.rawValue, text: $0.text,
                                        promptContext: $0.promptContext, taskID: $0.taskID) }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        refreshConversationList()
    }

    private func refreshConversationList() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderDir,
            includingPropertiesForKeys: nil
        )) ?? []
        var list: [ConversationMeta] = []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(PersistedHistory.self, from: data) else { continue }
            list.append(ConversationMeta(
                id: id,
                title: payload.title ?? "对话",
                updatedAt: payload.updatedAt ?? Date.distantPast
            ))
        }
        conversationList = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    nonisolated private static func deriveTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "对话" }
        let line = first.text.split(separator: "\n").first.map(String.init) ?? first.text
        return line.count > 24 ? String(line.prefix(24)) + "…" : line
    }

    /// 身份 key 启用前目录名按绝对路径哈希；首次访问时把旧目录整个搬到
    /// 身份 key 目录下（目标还在原路径时两个 key 都能算出来）。
    private func migratePathKeyDirIfNeeded() {
        let dir = folderDir
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        let legacyKey = Self.historyKey(folder: boundFolder, selection: boundSelection,
                                        file: boundFile, token: { $0.path })
        guard legacyKey != boundKey else { return }
        let legacyDir = Self.historyDir.appendingPathComponent(legacyKey, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return }
        try? FileManager.default.moveItem(at: legacyDir, to: dir)
    }

    /// Old scheme stored one flat file per folder; fold it into the new
    /// per-conversation directory once.
    private func migrateLegacyHistoryIfNeeded() {
        let legacyKey = Self.historyKey(folder: boundFolder, selection: boundSelection,
                                        file: boundFile, token: { $0.path })
        let legacy = Self.historyDir.appendingPathComponent("\(legacyKey).json")
        guard FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy),
              let payload = try? JSONDecoder().decode(PersistedHistory.self, from: data) else { return }
        let migrated = PersistedHistory(
            folder: payload.folder,
            selection: payload.selection,
            title: payload.title ?? "早前的对话",
            updatedAt: payload.updatedAt ?? Date(),
            items: payload.items
        )
        if let out = try? JSONEncoder().encode(migrated),
           (try? out.write(to: conversationFileURL(UUID()), options: .atomic)) != nil {
            try? FileManager.default.removeItem(at: legacy)
        }
    }
}

enum APIError: Error {
    case badURL
    case server(status: Int, body: String)
    case cli(exitCode: Int?, body: String)

    var message: String {
        switch self {
        case .badURL:
            return "API 地址无效，请检查设置里的 Base URL"
        case .server(let status, let body):
            let trimmed = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "请求失败（HTTP \(status)）：\(trimmed)"
        case .cli(let exitCode, let body):
            let trimmed = body.count > 300 ? String(body.prefix(300)) + "…" : body
            if let exitCode {
                return L("命令执行失败（退出码 \(exitCode)）：\(trimmed)",
                         "Command failed (exit code \(exitCode)): \(trimmed)")
            }
            return L("命令执行失败：\(trimmed)", "Command failed: \(trimmed)")
        }
    }
}
