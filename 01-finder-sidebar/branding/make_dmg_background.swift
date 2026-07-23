#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make_dmg_background.swift OUTPUT_1X OUTPUT_2X\n", stderr)
    exit(2)
}

// DMG 背景是静态图，无法在用户打开时检测系统语言，
// 所以完全不放文字：App 图标 → 箭头 → Applications，手势全球通用。
let output1x = URL(fileURLWithPath: CommandLine.arguments[1])
let output2x = URL(fileURLWithPath: CommandLine.arguments[2])

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

    let arrowColors = [
        NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.88, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 0.60, blue: 0.65, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
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
