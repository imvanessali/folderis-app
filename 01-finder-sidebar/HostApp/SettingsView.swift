import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var logoError: String?
    /// When embedded inline (floating panel), the host supplies the way back;
    /// falls back to SwiftUI dismiss when presented as a sheet/window.
    var onDone: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                section(title: L("选择 AI 来源", "Choose AI Source")) {
                    VStack(spacing: 8) {
                        ForEach([BackendKind.claudeCode, .codex, .cursor, .builtinAPI]) { kind in
                            backendRow(kind)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if settings.backend == .builtinAPI {
                        Divider()
                        apiKeyControls()
                    } else if let caption = settings.backend.caption {
                        Text(caption)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }


                section(title: L("命令审批", "Command Approval")) {
                    Picker("", selection: $settings.approvalMode) {
                        ForEach(ApprovalMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(settings.backend == .builtinAPI
                         ? settings.approvalMode.caption
                         : L("CLI 后端映射：全自动 → 跳过其权限询问；其余 → 自动接受编辑、命令仍受其安全策略约束", "CLI backend mapping: Auto-allow all skips its permission prompts; other modes auto-accept edits while commands still follow its safety policy"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                section(title: L("面板图标", "Panel Icon")) {
                    VStack(spacing: 8) {
                        ForEach(LogoChoice.allCases) { choice in
                            logoRow(choice)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(L("建议使用正方形图片；非正方形会自动居中裁剪，过大的图片会自动压缩。",
                           "Square images work best; non-square images are center-cropped and oversized ones compressed automatically."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let logoError {
                        Text(logoError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }

                // 退出入口：菜单栏图标不好找，设置页兜底。
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text(L("退出 Folderis", "Quit Folderis"))
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Text("\(Self.edition) · v\(Self.version) (\(Self.buildNumber))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L("构建于 \(Self.buildDate)", "Build \(Self.buildDate)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(16)
            .onAppear { settings.refreshCLIDetection() }
        }
        .textSelection(.enabled)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private static let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    private static let edition: String = {
        return "Folderis Full"
    }()

    /// The executable's modification date — effectively the build time.
    private static let buildDate: String = {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return L("未知", "unknown") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }()

    private func labelFor(_ kind: BackendKind) -> String {
        switch kind {
        case .builtinAPI:
            return kind.displayName
        case .claudeCode:
            return settings.claudeCLIPath != nil ? "Claude Code ✓" : L("Claude Code（未检测到）", "Claude Code (not found)")
        case .codex:
            return settings.codexCLIPath != nil ? "Codex ✓" : L("Codex（未检测到）", "Codex (not found)")
        case .cursor:
            return settings.cursorCLIPath != nil ? "Cursor ✓" : L("Cursor Agent（未检测到）", "Cursor Agent (not found)")
        }
    }

    private func isDetected(_ kind: BackendKind) -> Bool {
        switch kind {
        case .builtinAPI: return true
        case .claudeCode: return settings.claudeCLIPath != nil
        case .codex: return settings.codexCLIPath != nil
        case .cursor: return settings.cursorCLIPath != nil
        }
    }

    private func backendRow(_ kind: BackendKind) -> some View {
        let detected = isDetected(kind)
        let selected = settings.backend == kind
        return HStack(spacing: 8) {
            Button {
                settings.backend = kind
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(labelFor(kind))
                        .font(.system(size: 14))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
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
        .frame(maxWidth: .infinity)
    }

    private func logoRow(_ choice: LogoChoice) -> some View {
        let selected = settings.logoChoice == choice
        let hasCustomFile = FileManager.default.fileExists(atPath: BrandLogo.customLogoURL.path)
        let selectable = choice != .custom || hasCustomFile
        return HStack(spacing: 8) {
            Button {
                settings.logoChoice = choice
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    logoThumbnail(choice)
                    Text(choice.displayName)
                        .font(.system(size: 14))
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .opacity(selectable ? 1 : 0.55)

            if choice == .custom {
                Button {
                    pickCustomImage()
                } label: {
                    Label(L("选择图片…", "Choose image…"), systemImage: "photo")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func logoThumbnail(_ choice: LogoChoice) -> some View {
        if let image = BrandLogo.image(choice: choice) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: choice == .custom ? "photo" : "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private func pickCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("选择一张正方形图片作为面板图标", "Choose a square image for the panel icon")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BrandLogo.importCustomImage(from: url)
            logoError = nil
            // 即使已是 .custom，重新赋值也会触发 didSet 广播刷新。
            settings.logoChoice = .custom
        } catch {
            logoError = error.localizedDescription
        }
    }

    private func apiKeyControls(showTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if showTitle {
                    Text("DeepSeek API Key")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(L("获取 API Key →", "Get API Key →"),
                     destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    .font(.system(size: 12))
            }

            SecureField(L("粘贴你的 API Key（⌘V）", "Paste your API key (⌘V)"), text: $settings.apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text(L("API Key 保存在 macOS 钥匙串，不会明文写入磁盘。", "Your API key is stored in the macOS Keychain, never written to disk in plain text."))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Native-style building blocks

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
    }

}
