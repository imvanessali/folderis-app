// OCR via Apple Vision. Usage: ocr.swift <image> <out.txt>
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count >= 3,
      let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let cgImage = NSBitmapImageRep(data: tiff)?.cgImage else {
    FileHandle.standardError.write(Data("无法读取图片\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage)
try handler.perform([request])

let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let text = lines.joined(separator: "\n")
try text.write(toFile: args[2], atomically: true, encoding: .utf8)
print("识别 \(lines.count) 行文本")
