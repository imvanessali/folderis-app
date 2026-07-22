#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 4 else {
    fputs("usage: make_dmg_background.swift PRODUCT OUTPUT_1X OUTPUT_2X\n", stderr)
    exit(2)
}

let product = CommandLine.arguments[1]
let output1x = URL(fileURLWithPath: CommandLine.arguments[2])
let output2x = URL(fileURLWithPath: CommandLine.arguments[3])

func render(scale: CGFloat, output: URL) throws {
    let width = Int(700 * scale)
    let height = Int(420 * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "FolderisDMGBackground", code: 1)
    }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "FolderisDMGBackground", code: 2)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(calibratedRed: 0.988, green: 0.984, blue: 0.992, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

    func drawCentered(
        _ text: String,
        y: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * scale, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let rect = NSRect(
            x: 24 * scale,
            y: y * scale,
            width: CGFloat(width) - 48 * scale,
            height: (size + 8) * scale
        )
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    let primary = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1)
    let secondary = NSColor(calibratedRed: 0.40, green: 0.42, blue: 0.47, alpha: 1)
    drawCentered("安装：将 \(product) 拖入“应用程序”", y: 354, size: 17, weight: .semibold, color: primary)
    drawCentered("Install: drag \(product) to Applications", y: 326, size: 14, weight: .medium, color: secondary)
    drawCentered("拖完后，到“应用程序”中双击打开 \(product)", y: 49, size: 13, weight: .medium, color: primary)
    drawCentered("Then open Applications and double-click \(product)", y: 25, size: 11.5, weight: .regular, color: secondary)

    let arrowColors = [
        NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.88, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 0.60, blue: 0.65, alpha: 1),
        primary,
    ]
    for (index, color) in arrowColors.enumerated() {
        let centerX = CGFloat(323 + index * 27) * scale
        let centerY = 210 * scale
        let path = NSBezierPath()
        path.lineWidth = 7 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: centerX - 8 * scale, y: centerY + 16 * scale))
        path.line(to: NSPoint(x: centerX + 8 * scale, y: centerY))
        path.line(to: NSPoint(x: centerX - 8 * scale, y: centerY - 16 * scale))
        color.setStroke()
        path.stroke()
    }

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FolderisDMGBackground", code: 3)
    }
    try data.write(to: output)
}

try render(scale: 1, output: output1x)
try render(scale: 2, output: output2x)
