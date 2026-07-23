import SwiftUI
import ApplicationServices

/// 首次启动引导：选择 AI 来源（优先 Claude Code / Codex，没有则配 DeepSeek）→ 授权。
/// 完成标记存 UserDefaults，之后不再弹出。
@MainActor
enum Onboarding {
    static let completedKey = "onboardingCompleted.v1"

    static var needed: Bool {
        !UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, brain, deepSeekKey, permissions, done
    }

    @State private var step: Step = Self.initialStep
    /// 大脑选择（nil = 尚未选）。
    @State private var brainChoice: BackendKind? = Self.initialStep.rawValue >= Step.deepSeekKey.rawValue ? .builtinAPI : nil

    /// 调试用：FOLDERIS_ONB_STEP=welcome|brain|key|perms|done 直接跳到某页。
    private static var initialStep: Step {
        switch ProcessInfo.processInfo.environment["FOLDERIS_ONB_STEP"] {
        case "brain": return .brain
        case "key": return .deepSeekKey
        case "perms": return .permissions
        case "done": return .done
        default: return .welcome
        }
    }
    @State private var deepSeekKey: String = ""

    // 权限状态，进入授权页后轮询刷新。
    @State private var axGranted = AXIsProcessTrusted()
    @State private var automationGranted: Bool? = nil
    @State private var automationProbeInFlight = false
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 40)
                .padding(.top, 44)

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 520, height: 560)
        .textSelection(.enabled)
        // windowBackgroundColor 在 macOS 26 会被壁纸染色（顶部泛渐变），
        // 引导窗悬在桌面上很明显，改用纯色的 textBackgroundColor。
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .onReceive(pollTimer) { _ in
            guard step == .permissions else { return }
            axGranted = AXIsProcessTrusted()
            probeAutomation(prompting: false)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomePage
        case .brain: brainPage
        case .deepSeekKey: deepSeekPage
        case .permissions: permissionsPage
        case .done: donePage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 0) {
            BrandLogoView(size: 150)
                .padding(.top, 16)

            // 标题：唯一的黑色粗体，视觉锚点。
            Text(L("欢迎使用 Folderis", "Welcome to Folderis"))
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 24)

            // 导语：深色中等字重，与下方灰色正文拉开层次。
            Text(L("在访达窗口旁边放一个 AI 助手：选中文件，直接说你想做什么。",
                   "An AI assistant sits beside your Finder window. Select files and say what you want."))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 8)

            // 正文：常规灰色说明。
            Text(L("支持60+种常见办公操作，压缩、转换、比较、整理、批量操作等等，如果没有命中内置的技能，AI可以当场写代码完成任务。",
                   "Folderis supports 60+ common office tasks, including compression, conversion, comparison, organization, and batch operations. If no built-in skill matches, AI can write code on the spot."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.horizontal, 12)

            // 脚注：最浅、最小，仅作提醒。
            Text(L("不建议做逻辑特别复杂，人工难以验证的任务，Folderis主打轻量和便捷。",
                   "Avoid highly complex tasks that are difficult to verify manually. Folderis is designed for lightweight, convenient work."))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 28)
        }
    }

    private var brainPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                Text(L("选择 AI 来源", "Choose your AI source"))
                    .font(.system(size: 21, weight: .bold))
            }

            VStack(spacing: 8) {
                brainOption(.claudeCode,
                            detected: settings.claudeCLIPath != nil,
                            detail: L("复用你的 Claude 订阅，无需额外付费",
                                      "Reuse your Claude subscription at no additional cost"))
                brainOption(.codex,
                            detected: settings.codexCLIPath != nil,
                            detail: L("复用你的 Codex 订阅，无需额外付费",
                                      "Reuse your Codex subscription at no additional cost"))
                brainOption(.builtinAPI,
                            detected: true,
                            detail: L("在下一步配置 Deepseek API key",
                                      "Configure the DeepSeek API key in the next step"))
            }
        }
        .onAppear { settings.refreshCLIDetection() }
    }

    private func brainOption(_ kind: BackendKind, detected: Bool, detail: String) -> some View {
        let title: String
        switch kind {
        case .claudeCode:
            title = detected ? "Claude Code ✓" : L("Claude Code（未检测到）", "Claude Code (not found)")
        case .codex:
            title = detected ? "Codex ✓" : L("Codex（未检测到）", "Codex (not found)")
        case .builtinAPI:
            title = L("使用 API Key（目前只支持 DeepSeek）", "Use API Key (DeepSeek only for now)")
        }
        let selected = brainChoice == kind
        return HStack(spacing: 8) {
            Button {
                brainChoice = kind
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .medium))
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!detected)
            .opacity(detected ? 1 : 0.55)

            if !detected && kind != .builtinAPI {
                Button {
                    settings.refreshCLIDetection()
                } label: {
                    Label(L("重新检测", "Detect again"), systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(settings.isDetectingCLI)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: selected ? 1.5 : 1)
        )
    }

    private var deepSeekPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(icon: "key.fill",
                       title: L("配置 DeepSeek", "Set up DeepSeek"),
                       subtitle: L("一分钟搞定：注册 DeepSeek 开放平台，创建一个 API Key 粘贴到下面。",
                                   "Takes a minute: sign up at the DeepSeek platform, create an API key, and paste it below."))

            VStack(alignment: .leading, spacing: 0) {
                keyStepRow("1.") {
                    Link(L("打开 platform.deepseek.com → API Keys", "Open platform.deepseek.com → API Keys"),
                         destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                }
                keyStepRow("2.") {
                    Text(L("创建 Key 并复制", "Create a key and copy it"))
                }
                keyStepRow("3.") {
                    SecureField(L("粘贴你的 API Key（⌘V）", "Paste your API key (⌘V)"), text: $deepSeekKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11))
                Text(L("Key 保存在 macOS 钥匙串，不会明文写入磁盘。",
                       "Stored in the macOS Keychain, never written to disk in plain text."))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
    }

    private func keyStepRow<Content: View>(
        _ number: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .frame(width: 18, alignment: .trailing)
            content()
        }
        .font(.system(size: 13))
        .frame(height: 34)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(icon: "checkmark.shield.fill",
                       title: L("授权两个系统权限", "Grant two system permissions"),
                       subtitle: L("面板需要它们才能贴靠访达窗口、读取当前文件夹和选中的文件。",
                                   "The panel needs these to dock to Finder windows and read the current folder and selection."))

            permissionRow(
                granted: axGranted,
                title: L("辅助功能", "Accessibility"),
                detail: L("让面板贴靠并跟随访达窗口", "Lets the panel dock to and follow Finder windows"),
                buttonTitle: L("去授权", "Grant"),
                action: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(opts)
                }
            )
            permissionRow(
                granted: automationGranted ?? false,
                title: L("自动化（控制访达）", "Automation (control Finder)"),
                detail: L("读取当前文件夹和选中的文件", "Reads the current folder and selected files"),
                buttonTitle: L("去授权", "Grant"),
                action: { probeAutomation(prompting: true) }
            )

            Text(L("弹出系统对话框时请点\u{201C}允许\u{201D}；如果没弹窗，可在 系统设置 → 隐私与安全性 里手动打开。",
                   "Click \u{201C}Allow\u{201D} when the system dialog appears; if none shows up, enable it manually in System Settings → Privacy & Security."))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            axGranted = AXIsProcessTrusted()
            probeAutomation(prompting: false)
        }
    }

    private func permissionRow(granted: Bool, title: String, detail: String,
                               buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(buttonTitle, action: action)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var donePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.green)
                .padding(.top, 30)
            Text(L("设置完成", "All set"))
                .font(.system(size: 26, weight: .bold))
            Text(L("打开任意文件夹，面板就会出现在访达窗口右侧。选中几个文件，说说你想做什么。",
                   "Open any folder and the panel appears beside the Finder window. Select some files and say what you want done."))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("示例：\u{201C}将这批PNG无损压缩一下\u{201D}", "Try: \u{201C}Compress these PNGs losslessly\u{201D}"))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    private func pageHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 21, weight: .bold))
            }
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer（步骤点 + 上一步/下一步）

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button(L("上一步", "Back")) { goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(visibleSteps, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(nextTitle) { goNext() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(nextDisabled)
        }
    }

    /// DeepSeek 步骤只在选了内置 API 时出现在进度点里。
    private var visibleSteps: [Step] {
        #if MVP_DEEPSEEK
        Step.allCases.filter { $0 != .brain }
        #else
        Step.allCases.filter { $0 != .deepSeekKey || brainChoice == .builtinAPI }
        #endif
    }

    private var nextTitle: String {
        switch step {
        case .welcome: return L("开始", "Get Started")
        case .done: return L("完成", "Finish")
        default: return L("下一步", "Next")
        }
    }

    private var nextDisabled: Bool {
        switch step {
        case .brain: return brainChoice == nil
        case .deepSeekKey: return deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    private func goNext() {
        switch step {
        case .welcome:
            #if MVP_DEEPSEEK
            brainChoice = .builtinAPI
            applyBrainChoice()
            step = .deepSeekKey
            #else
            step = .brain
            #endif
        case .brain:
            applyBrainChoice()
            step = brainChoice == .builtinAPI ? .deepSeekKey : .permissions
        case .deepSeekKey:
            settings.apiKey = deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines)
            step = .permissions
        case .permissions:
            step = .done
        case .done:
            Onboarding.markCompleted()
            onFinish()
        }
    }

    private func goBack() {
        switch step {
        case .brain: step = .welcome
        #if MVP_DEEPSEEK
        case .deepSeekKey: step = .welcome
        case .permissions: step = .deepSeekKey
        #else
        case .deepSeekKey: step = .brain
        case .permissions: step = brainChoice == .builtinAPI ? .deepSeekKey : .brain
        #endif
        default: break
        }
    }

    private func applyBrainChoice() {
        guard let choice = brainChoice else { return }
        settings.backend = choice
        if choice == .builtinAPI {
            settings.provider = .deepSeek
            settings.resetURLAndModelToProviderDefaults()
            // 预填已存的 Key（重跑引导时不清空）。
            if deepSeekKey.isEmpty { deepSeekKey = settings.apiKey }
        }
    }

    /// 探测自动化权限；prompting 为 true 时的首次调用会触发系统授权弹窗。
    private func probeAutomation(prompting: Bool) {
        guard !automationProbeInFlight else { return }
        automationProbeInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: "tell application \"Finder\" to count windows")
            var error: NSDictionary?
            _ = script?.executeAndReturnError(&error)
            let ok = (error == nil)
            DispatchQueue.main.async {
                automationProbeInFlight = false
                // 非请求式轮询里，拿不到结果就保持未知，不把已授权改回未授权。
                if ok { automationGranted = true }
                else if prompting { automationGranted = false }
            }
        }
    }
}

private struct BrandLogoView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "OrbLogoTransparent", withExtension: "png"),
               let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: size, height: size)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: size, height: size)
    }
}
