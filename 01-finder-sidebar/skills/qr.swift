// 二维码工具：生成（CoreImage）与识别（Vision），零第三方依赖。
// 用法:
//   qr make <text> <out.png> [size]
//   qr read <img> [img...]        输出: 每码一行 JSON {"path":…,"payload":…} 或 {"path":…,"error":…}
//                                 （payload 内的换行由 JSON 转义承载，多行内容不丢失）
import Foundation
import CoreImage
import Vision
import AppKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { fail("用法: qr make <text> <out.png> [size] | qr read <img...>") }

switch mode {
case "make":
    guard args.count >= 3 else { fail("用法: qr make <text> <out.png> [size]") }
    let text = args[1]
    let outPath = args[2]
    let size = args.count >= 4 ? (Int(args[3]) ?? 512) : 512

    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { fail("二维码生成器不可用") }
    filter.setValue(text.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ci = filter.outputImage else { fail("生成失败（内容可能过长，二维码上限约 2900 字节）") }

    // 最近邻放大，保持像素边缘锐利
    let scale = CGFloat(size) / ci.extent.width
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { fail("渲染失败") }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG 编码失败") }
    do {
        try png.write(to: URL(fileURLWithPath: outPath))
        print("已生成 \(outPath)（\(size)×\(size)）")
    } catch { fail("写入失败: \(error.localizedDescription)") }

case "read":
    guard args.count >= 2 else { fail("用法: qr read <img...>") }
    var found = 0
    // 每码一条单行 JSON：payload 里的换行/制表符走 JSON 转义，
    // 多行内容（vCard/MECARD/MEBKM 等）不会被行协议截断。
    func emit(_ record: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }
    for path in args.dropFirst() {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            emit(["path": path, "error": "无法读取图片"])
            continue
        }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do {
            try handler.perform([request])
            let codes = (request.results ?? []).compactMap { $0.payloadStringValue }
            if codes.isEmpty {
                emit(["path": path, "error": "未识别到二维码/条形码"])
            } else {
                for c in codes { emit(["path": path, "payload": c]); found += 1 }
            }
        } catch {
            emit(["path": path, "error": "识别失败: \(error.localizedDescription)"])
        }
    }
    if found == 0 { exit(2) }

default:
    fail("未知模式 \(mode)，支持 make / read")
}
