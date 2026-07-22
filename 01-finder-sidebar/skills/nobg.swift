// Background removal via Vision subject lifting (macOS 14+).
// Usage: nobg.swift <image> <out.png>
import Foundation
import Vision
import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count >= 3,
      let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let cgImage = NSBitmapImageRep(data: tiff)?.cgImage else {
    FileHandle.standardError.write(Data("无法读取图片\n".utf8))
    exit(1)
}

guard #available(macOS 14.0, *) else {
    FileHandle.standardError.write(Data("需要 macOS 14+\n".utf8))
    exit(1)
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: cgImage)
try handler.perform([request])

guard let result = request.results?.first else {
    FileHandle.standardError.write(Data("未识别到前景主体\n".utf8))
    exit(2)
}

let maskedBuffer = try result.generateMaskedImage(
    ofInstances: result.allInstances,
    from: handler,
    croppedToInstancesExtent: false
)

let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
let context = CIContext()
guard let outCG = context.createCGImage(ciImage, from: ciImage.extent) else {
    FileHandle.standardError.write(Data("输出失败\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: outCG)
try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
print("已输出透明背景 PNG")
