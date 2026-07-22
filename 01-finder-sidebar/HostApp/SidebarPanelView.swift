import SwiftUI

struct SidebarPanelView: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var finderContext: FinderContext
    @ObservedObject var tracker: FinderWindowTracker
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(chat: chat, onCollapse: onCollapse)

            if !tracker.accessibilityGranted {
                PermissionHint(text: L("需要在 系统设置 → 隐私与安全性 → 辅助功能 中授权本 App，聊天面板才能贴靠并跟随 Finder 窗口。", "Grant access in System Settings → Privacy & Security → Accessibility so the panel can dock to Finder windows."))
                Divider()
            }
            if finderContext.automationDenied {
                PermissionHint(text: L("需要在 系统设置 → 隐私与安全性 → 自动化 中允许本 App 控制 Finder，才能读取当前文件夹和选中文件。", "Allow this app to control Finder in System Settings → Privacy & Security → Automation to read the current folder and selection."))
                Divider()
            }

            // 上下文行：任何显式选择都绑定完整选择集合；未选择时才绑定文件夹。
            if !chat.boundSelection.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: chat.boundSelection.count == 1 ? "doc.text" : "doc.on.doc")
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.boundSelection.count == 1
                             ? chat.boundSelection[0].lastPathComponent
                             : L("已绑定 \(chat.boundSelection.count) 项", "\(chat.boundSelection.count) items bound"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(bindingTypeLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            } else if let folder = finderContext.currentFolder {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            if !chat.attachedFiles.isEmpty {
                if attachmentsNeedScrolling {
                    ScrollView(.vertical, showsIndicators: true) {
                        attachmentRows
                    }
                    .frame(height: 132)
                } else {
                    attachmentRows
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }

            ChatView(chat: chat)
        }
        .frame(minWidth: 280, idealWidth: 320)
        .textSelection(.enabled)
        // 窗口本体是透明无边框的：面板实体（底色、圆角）在这里绘制，
        // 系统阴影会跟随这个形状。圆角对齐 macOS 26 窗口的大圆角。
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        // 原生窗口的亮色发丝内描边：把边缘从阴影里提出来，不显得发深。
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        // Finder 选中变化时自动同步为附件，无需手动点按钮；
        // 同时驱动会话绑定：选择集合中的每一项都参与绑定身份。
        .onReceive(finderContext.$selectedFiles) { urls in
            chat.syncSelection(urls)
            chat.switchTarget(folder: finderContext.currentFolder, selection: urls)
        }
        // 切换文件夹 → 切换到该文件夹或当前精确选择集合的会话。
        .onReceive(finderContext.$currentFolder) { folder in
            chat.switchTarget(folder: folder, selection: finderContext.selectedFiles)
        }
    }

    private var estimatedAttachmentHeight: CGFloat {
        let rowHeights = chat.attachedFiles.reduce(CGFloat.zero) { total, url in
            let estimatedLines = max(1, Int(ceil(Double(url.lastPathComponent.count) / 30.0)))
            return total + CGFloat(estimatedLines * 16 + 12)
        }
        let interRowSpacing = CGFloat(max(0, chat.attachedFiles.count - 1) * 6)
        return min(rowHeights + interRowSpacing + 12, 132)
    }

    private var attachmentsNeedScrolling: Bool {
        estimatedAttachmentHeight >= 132
    }

    private var attachmentRows: some View {
        VStack(spacing: 6) {
            ForEach(chat.attachedFiles, id: \.self) { url in
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.caption2)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        chat.removeAttachment(url)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var bindingTypeLabel: String {
        if chat.boundSelection.count > 1 {
            return L("已绑定多个项目", "Multiple items bound")
        }
        guard let selected = chat.boundSelection.first else { return "" }
        let isDirectory = (try? selected.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return isDirectory
            ? L("已绑定文件夹", "Folder bound")
            : L("已绑定文件", "File bound")
    }
}

/// Finder-style header: window title on the left, floating circular buttons
/// on the right — drawn by us so they keep the "active" look even though the
/// panel never steals focus from Finder.
private struct HeaderBar: View {
    @ObservedObject var chat: ChatViewModel
    let onCollapse: () -> Void

    private var title: String {
        if chat.showSettings { return L("设置", "Settings") }
        if chat.showHistory { return L("历史对话", "History") }
        return "Folderis"
    }

    var body: some View {
        HStack(spacing: 10) {
            // 标题固定在左侧，切页不移位。
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if chat.showSettings || chat.showHistory {
                // 子页面：右侧一个"完成"退出，标题不动。
                CapsuleTextButton(text: L("完成", "Done")) {
                    chat.showSettings = false
                    chat.showHistory = false
                }
            } else {
                CircleIconButton(icon: "minus", help: L("收起为悬浮球", "Collapse to floating orb"), action: onCollapse)
                // 新建对话 + 历史 合并成一个原生风格的胶囊按钮组。
                PillIconGroup(items: [
                    .init(icon: "square.and.pencil", help: L("新建对话", "New chat")) {
                        chat.newConversation()
                    },
                    .init(icon: "clock", help: L("历史对话", "History")) {
                        chat.showHistory = true
                    }
                ])
                CircleIconButton(icon: "gearshape", help: L("设置", "Settings")) {
                    chat.showSettings = true
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}

/// Mimics the floating circular toolbar buttons Finder shows on macOS 26:
/// a raised light circle with a soft diffuse shadow and a dark template icon.
private struct CircleIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    static let size: CGFloat = 40

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: Self.size, height: Self.size)
                .background(
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(hovering ? 0.10 : 0.07), radius: 9, y: 2.5)
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A native-style grouped pill: several icon segments sharing one floating
/// capsule (like Finder's grouped toolbar controls).
private struct PillIconGroup: View {
    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let help: String
        let action: () -> Void

        init(icon: String, help: String, action: @escaping () -> Void) {
            self.icon = icon
            self.help = help
            self.action = action
        }
    }

    let items: [Item]
    @State private var hoveringID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button(action: item.action) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(width: CircleIconButton.size + 4, height: CircleIconButton.size)
                        .background(
                            // 悬停时只高亮所在分段。
                            Capsule()
                                .fill(hoveringID == item.id ? Color.primary.opacity(0.06) : .clear)
                                .padding(3)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hoveringID = $0 ? item.id : nil }
                .help(item.help)
            }
        }
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.07), radius: 9, y: 2.5)
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

/// Floating capsule with a short text label ("完成"), same chrome as the
/// circular buttons.
private struct CapsuleTextButton: View {
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(height: CircleIconButton.size)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(hovering ? 0.10 : 0.07), radius: 9, y: 2.5)
                )
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct PermissionHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(8)
    }
}
