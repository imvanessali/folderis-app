import AppKit
import ImageIO

/// 面板/菜单栏 logo 的来源：内置默认 orb、内置 Clippy，或用户自定义图片。
enum LogoChoice: String, CaseIterable, Identifiable {
    case orb
    case clippy
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .orb: return L("默认", "Default")
        case .clippy: return "Clippy"
        case .custom: return L("自定义图片", "Custom image")
        }
    }
}

/// 统一的 logo 解析与自定义图片导入。导入时居中裁成正方形，
/// 超过 maxPixelSize 等比压缩，统一落盘为 PNG——避免面板反复解码大图。
enum BrandLogo {
    static let changedNotification = Notification.Name("brandLogoDidChange")

    /// 处理后图片的最大边长（像素）。
    static let maxPixelSize = 512

    /// 与会话/日志同目录：~/Library/Application Support/FinderSidebar/。
    static var customLogoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderSidebar", isDirectory: true)
            .appendingPathComponent("CustomLogo.png")
    }

    /// UserDefaults 里保存的选择（AppSettings 不可达的场景用，如引导页、菜单栏）。
    static var savedChoice: LogoChoice {
        LogoChoice(rawValue: UserDefaults.standard.string(forKey: "logoChoice") ?? "") ?? .orb
    }

    /// 当前选择对应的图片。preferTransparent 只影响默认 orb（空状态/引导页
    /// 用透明版）；自定义文件缺失时退回默认。
    static func image(choice: LogoChoice, preferTransparent: Bool = false) -> NSImage? {
        switch choice {
        case .orb:
            return bundleImage(preferTransparent ? "OrbLogoTransparent" : "OrbLogo")
        case .clippy:
            return bundleImage("ClippyLogo")
        case .custom:
            if let custom = NSImage(contentsOf: customLogoURL) { return custom }
            return bundleImage(preferTransparent ? "OrbLogoTransparent" : "OrbLogo")
        }
    }

    private static func bundleImage(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
    }

    /// 导入用户图片：居中裁方 + 压缩 + 存 PNG。抛错时保持原有自定义图不变。
    static func importCustomImage(from url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "BrandLogo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("无法读取图片文件", "Could not read the image file")
            ])
        }

        let side = min(cgImage.width, cgImage.height)
        let cropRect = CGRect(
            x: (cgImage.width - side) / 2,
            y: (cgImage.height - side) / 2,
            width: side,
            height: side
        )
        let square = cgImage.cropping(to: cropRect) ?? cgImage

        let target = min(side, maxPixelSize)
        guard let context = CGContext(
            data: nil, width: target, height: target,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "BrandLogo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L("图片处理失败", "Image processing failed")
            ])
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let output = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: output)
                  .representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BrandLogo", code: 3, userInfo: [
                NSLocalizedDescriptionKey: L("图片处理失败", "Image processing failed")
            ])
        }
        try FileManager.default.createDirectory(
            at: customLogoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: customLogoURL)
    }
}
