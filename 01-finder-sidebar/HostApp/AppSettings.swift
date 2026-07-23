import Foundation
import Combine
import AppKit

enum APIProvider: String, CaseIterable, Identifiable {
    case deepSeek = "DeepSeek"

    var id: String { rawValue }

    var defaultBaseURL: String {
        "https://api.deepseek.com/chat/completions"
    }

    var defaultModel: String {
        "deepseek-v4-flash"
    }

    /// DeepSeek speaks the OpenAI wire format, so it reuses that transport.
    var usesOpenAIProtocol: Bool {
        true
    }

    /// DeepSeek's API is text-only; sending image blocks makes its gateway
    /// fail with 502.
    var supportsVision: Bool {
        false
    }
}

/// Claude Code-style permission modes for run_command.
enum ApprovalMode: String, CaseIterable, Identifiable {
    case ask = "每次询问"
    case safeAuto = "只读命令自动允许"
    case yolo = "全部自动允许"

    var id: String { rawValue }

    /// rawValue 被持久化，界面显示用这个。
    var displayName: String {
        switch self {
        case .ask: return L("每次询问", "Ask every time")
        case .safeAuto: return L("只读命令自动允许", "Auto-allow read-only")
        case .yolo: return L("全部自动允许", "Auto-allow all")
        }
    }

    var caption: String {
        switch self {
        case .ask: return L("每条命令都需要你确认（最安全）", "Every command needs your approval (safest)")
        case .safeAuto: return L("ls、cat、git status 等只读命令直接执行，其余仍需确认", "Read-only commands like ls, cat, git status run directly; everything else still asks")
        case .yolo: return L("所有命令直接执行，不再询问（自担风险）", "All commands run without asking (at your own risk)")
        }
    }
}

/// 面板的"大脑"来源：内置 API 直连，或驱动本机已登录的 CLI 代理
/// （用量走用户自己的订阅，Key 无需配置）。
enum BackendKind: String, CaseIterable, Identifiable {
    // Persisted compatibility value; user-facing copy lives in displayName.
    case builtinAPI = "内置 API"
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    /// rawValue 被持久化并用作 backendSessionIDs 的 key，界面显示用这个。
    var displayName: String {
        switch self {
        case .builtinAPI: return L("使用 API Key（目前只支持 DeepSeek）", "Use API Key (DeepSeek only for now)")
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var caption: String? {
        switch self {
        case .builtinAPI: return nil
        case .claudeCode: return L("复用你的 Claude 订阅，无需额外付费", "Reuse your Claude subscription at no additional cost")
        case .codex: return L("复用你的 Codex 订阅，无需额外付费", "Reuse your Codex subscription at no additional cost")
        }
    }

    /// 在常见安装路径 + 登录 shell PATH 中探测 CLI。
    static func detectCLIPath(_ name: String) -> String? {
        var candidates = [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/bin/\(name)"
        ]
        if name == "codex" {
            // Codex CLI currently ships inside the ChatGPT desktop app. Keep
            // the older Codex.app names as fallbacks for previous releases.
            if let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ) {
                candidates.append(appURL.appendingPathComponent("Contents/Resources/codex").path)
            }
            candidates.append("/Applications/ChatGPT.app/Contents/Resources/codex")
            candidates.append("\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex")
            candidates.append("/Applications/Codex.app/Contents/Resources/codex")
            candidates.append("\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex")
        }
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = Pipe()
        try? probe.run()
        probe.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return probe.terminationStatus == 0 && !out.isEmpty ? out : nil
    }

    /// Finder-launched apps inherit a minimal PATH that can omit the directory
    /// containing a detected CLI and its runtime (for example `node` beside
    /// `~/.local/bin/claude`). Always expose that directory to child processes.
    static func environmentForCLI(
        at cliPath: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let cliDirectory = URL(fileURLWithPath: cliPath)
            .deletingLastPathComponent()
            .standardizedFileURL.path
        var pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        if !pathEntries.contains(cliDirectory) {
            pathEntries.insert(cliDirectory, at: 0)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }
}

final class AppSettings: ObservableObject {
    private static let account = "default"

    @Published var backend: BackendKind {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "backend") }
    }
    /// 探测结果缓存（应用启动时刷新一次）。
    @Published var claudeCLIPath: String? = nil
    @Published var codexCLIPath: String? = nil
    @Published private(set) var isDetectingCLI = false

    func refreshCLIDetection() {
        guard !isDetectingCLI else { return }
        isDetectingCLI = true
        DispatchQueue.global(qos: .utility).async {
            let claude = BackendKind.detectCLIPath("claude")
            let codex = BackendKind.detectCLIPath("codex")
            DispatchQueue.main.async {
                self.claudeCLIPath = claude
                self.codexCLIPath = codex
                self.isDetectingCLI = false
            }
        }
    }

    @Published var provider: APIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            // Each provider keeps its own key; switching swaps the loaded one.
            apiKey = KeychainHelper.load(account: provider.rawValue) ?? ""
        }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    /// The key for the CURRENT provider (stored per provider in the Keychain).
    @Published var apiKey: String {
        didSet { KeychainHelper.save(apiKey, account: provider.rawValue) }
    }
    @Published var approvalMode: ApprovalMode {
        didSet { UserDefaults.standard.set(approvalMode.rawValue, forKey: "approvalMode") }
    }

    init() {
        // Full 与 Lite 的 API 路径都只支持 DeepSeek；Full 额外支持 CLI 后端。
        let savedProvider = APIProvider.deepSeek
        self.provider = savedProvider
        self.baseURL = savedProvider.defaultBaseURL
        self.model = savedProvider.defaultModel

        // Migrate the legacy shared key ("default") to the current provider's
        // slot once, then retire it.
        if let legacy = KeychainHelper.load(account: Self.account) {
            if KeychainHelper.load(account: savedProvider.rawValue) == nil {
                KeychainHelper.save(legacy, account: savedProvider.rawValue)
            }
            KeychainHelper.delete(account: Self.account)
        }
        self.apiKey = KeychainHelper.load(account: savedProvider.rawValue) ?? ""
        let savedMode = UserDefaults.standard.string(forKey: "approvalMode") ?? ""
        self.approvalMode = ApprovalMode(rawValue: savedMode) ?? .ask
        #if MVP_DEEPSEEK
        self.backend = .builtinAPI
        #else
        let savedBackend = UserDefaults.standard.string(forKey: "backend") ?? ""
        self.backend = BackendKind(rawValue: savedBackend) ?? .builtinAPI
        #endif
        refreshCLIDetection()
    }

    func resetURLAndModelToProviderDefaults() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
    }
}
