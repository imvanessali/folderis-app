// Converts docx/rtf/html/txt to paginated PDF via AppKit + Core Text.
// Usage: doc2pdf.swift <input> <output.pdf>
import Foundation
import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("用法：doc2pdf <input> <out.pdf>\n".utf8))
    exit(1)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

let typeMap: [String: NSAttributedString.DocumentType] = [
    "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf,
    "html": .html, "htm": .html, "txt": .plain, "md": .plain
]
guard let docType = typeMap[inputURL.pathExtension.lowercased()] else {
    FileHandle.standardError.write(Data("不支持的输入格式 .\(inputURL.pathExtension)\n".utf8))
    exit(1)
}

var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: docType]
if docType == .plain {
    options[.characterEncoding] = String.Encoding.utf8.rawValue
}
guard let attributed = try? NSAttributedString(
    url: inputURL, options: options, documentAttributes: nil
) else {
    FileHandle.standardError.write(Data("无法读取文档\n".utf8))
    exit(1)
}

// A4 with 1-inch margins.
let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
let contentRect = pageRect.insetBy(dx: 72, dy: 72)

guard let context = CGContext(outputURL as CFURL, mediaBox: [pageRect].withUnsafeBufferPointer({ UnsafePointer($0.baseAddress!) }), nil) else {
    FileHandle.standardError.write(Data("无法创建 PDF 上下文\n".utf8))
    exit(1)
}

let framesetter = CTFramesetterCreateWithAttributedString(attributed)
var location = 0
var pages = 0
let total = attributed.length

repeat {
    var mediaBox = pageRect
    context.beginPage(mediaBox: &mediaBox)
    let path = CGPath(rect: contentRect, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
    CTFrameDraw(frame, context)
    context.endPage()
    let visible = CTFrameGetVisibleStringRange(frame)
    if visible.length == 0 { break }  // 防止零进度死循环
    location += visible.length
    pages += 1
} while location < total && pages < 5000

context.closePDF()
print("已生成 \(pages) 页 PDF")
