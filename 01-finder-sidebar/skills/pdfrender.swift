// Renders PDF pages to PNG/JPG.
// Usage: pdfrender.swift <pdf> <outdir> <png|jpg> <dpi> [pages: 5 or 1-3,7]
import Foundation
import PDFKit
import AppKit

let args = CommandLine.arguments
guard args.count >= 5,
      let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("用法错误或无法打开 PDF\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let format = args[3]
let dpi = Double(args[4]) ?? 150
let scale = dpi / 72.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func pageIndexes(_ spec: String?, pageCount: Int) -> [Int] {
    guard let spec, !spec.isEmpty else { return Array(0..<pageCount) }
    var result: [Int] = []
    for rawPart in spec.split(separator: ",") {
        let part = rawPart.trimmingCharacters(in: .whitespaces)
        let pages: [Int]
        if part.contains("-") {
            let bounds = part.split(separator: "-", maxSplits: 1)
            guard bounds.count == 2,
                  let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                  let end = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
                  start <= end else { fail("无效页码范围：\(spec)") }
            pages = Array(start...end)
        } else {
            guard let page = Int(part) else { fail("无效页码范围：\(spec)") }
            pages = [page]
        }
        for page in pages {
            guard page >= 1, page <= pageCount else {
                fail("页码 \(page) 超出范围（PDF 共 \(pageCount) 页）")
            }
            let index = page - 1
            if !result.contains(index) { result.append(index) }
        }
    }
    guard !result.isEmpty else { fail("没有指定任何页面") }
    return result
}

let indexes = pageIndexes(args.count >= 6 ? args[5] : nil, pageCount: doc.pageCount)

for i in indexes {
    guard let page = doc.page(at: i) else { continue }
    let bounds = page.bounds(for: .mediaBox)
    let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { continue }
    let data: Data?
    if format == "jpg" {
        data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    } else {
        data = rep.representation(using: .png, properties: [:])
    }
    let name = String(format: "page_%03d.%@", i + 1, format)
    try? data?.write(to: outDir.appendingPathComponent(name))
}
print("rendered \(indexes.count) pages")
