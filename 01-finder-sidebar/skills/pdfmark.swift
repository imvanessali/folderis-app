// PDF 水印与盖章（PDFKit + CoreGraphics），零第三方依赖。
// 用法:
//   pdfmark watermark <in.pdf> <out.pdf> <text> [opacity 0-1] [fontsize]
//   pdfmark stamp <in.pdf> <out.pdf> <image> <page|all|last> <pos> <width>
//     pos: br|bl|tr|tl|center（右下/左下/右上/左上/居中）
import Foundation
import PDFKit
import AppKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    fail("用法: pdfmark watermark <in> <out> <text> [opacity] [fontsize] | pdfmark stamp <in> <out> <img> <page> <pos> <width>")
}
let mode = args[0]
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
guard let doc = PDFDocument(url: inURL) else { fail("无法打开 \(args[1])") }
if doc.isLocked { fail("PDF 已加密，请先用 pdf-crypt decrypt 解锁") }

guard let firstPage = doc.page(at: 0) else { fail("PDF 无页面") }
var mediaBox = firstPage.bounds(for: .mediaBox)
guard let ctx = CGContext(outURL as CFURL, mediaBox: &mediaBox, nil) else { fail("无法创建输出 PDF") }

func drawPage(_ page: PDFPage, in ctx: CGContext) {
    var box = page.bounds(for: .mediaBox)
    ctx.beginPage(mediaBox: &box)
    ctx.saveGState()
    page.draw(with: .mediaBox, to: ctx)
    ctx.restoreGState()
}

switch mode {
case "watermark":
    let text = args[3]
    let opacity = args.count >= 5 ? (Double(args[4]) ?? 0.15) : 0.15
    let fontSize = args.count >= 6 ? (CGFloat(Double(args[5]) ?? 42)) : 42

    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        drawPage(page, in: ctx)
        let box = page.bounds(for: .mediaBox)

        ctx.saveGState()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.gray.withAlphaComponent(opacity)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        // 斜向平铺：以 45° 旋转坐标系，按间距铺满整页
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: .pi / 4)
        let stepX = size.width + 120
        let stepY = size.height + 110
        let span = max(box.width, box.height) * 1.5
        var y = -span
        while y < span {
            var x = -span
            while x < span {
                str.draw(at: NSPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
        }
        NSGraphicsContext.current = nil
        ctx.restoreGState()
        ctx.endPage()
    }
    ctx.closePDF()
    print("已加水印 → \(outURL.lastPathComponent)（\(doc.pageCount) 页）")

case "stamp":
    guard args.count >= 7 else { fail("用法: pdfmark stamp <in> <out> <img> <page|all|last> <pos> <width>") }
    let imgURL = URL(fileURLWithPath: args[3])
    guard let nsimg = NSImage(contentsOf: imgURL),
          let cgimg = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("无法读取图片 \(args[3])")
    }
    let pageSpec = args[4]
    let pos = args[5]
    let width = CGFloat(Double(args[6]) ?? 150)
    let height = width * CGFloat(cgimg.height) / CGFloat(cgimg.width)

    let targets: Set<Int>
    switch pageSpec {
    case "all": targets = Set(0..<doc.pageCount)
    case "last": targets = [doc.pageCount - 1]
    default:
        guard let n = Int(pageSpec), n >= 1, n <= doc.pageCount else {
            fail("页码无效：\(pageSpec)（共 \(doc.pageCount) 页，可用 all / last / 页码）")
        }
        targets = [n - 1]
    }

    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        drawPage(page, in: ctx)
        if targets.contains(i) {
            let box = page.bounds(for: .mediaBox)
            let m: CGFloat = 36
            let origin: CGPoint
            switch pos {
            case "bl": origin = CGPoint(x: box.minX + m, y: box.minY + m)
            case "tr": origin = CGPoint(x: box.maxX - width - m, y: box.maxY - height - m)
            case "tl": origin = CGPoint(x: box.minX + m, y: box.maxY - height - m)
            case "center": origin = CGPoint(x: box.midX - width / 2, y: box.midY - height / 2)
            default: origin = CGPoint(x: box.maxX - width - m, y: box.minY + m) // br
            }
            ctx.saveGState()
            ctx.draw(cgimg, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
            ctx.restoreGState()
        }
        ctx.endPage()
    }
    ctx.closePDF()
    print("已盖章 → \(outURL.lastPathComponent)（\(targets.count) 页）")

default:
    fail("未知模式 \(mode)，支持 watermark / stamp")
}
