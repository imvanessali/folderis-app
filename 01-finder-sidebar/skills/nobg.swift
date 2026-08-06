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

let maskedImage = CIImage(cvPixelBuffer: maskedBuffer)
let extent = maskedImage.extent

// Vision's raw subject mask intentionally keeps a soft transition. Product photos
// with a bright or saturated backdrop can therefore retain a one-pixel colour halo.
// Rebuild the cutout from the original pixels with a slightly contracted, gently
// feathered alpha mask. This removes background colour contamination without changing
// the image dimensions or turning the edge into a hard staircase.
let alphaMask = maskedImage.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
])
.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 0.75])
.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.35])
.cropped(to: extent)

let sourceImage = CIImage(cgImage: cgImage).cropped(to: extent)
let transparent = CIImage(color: .clear).cropped(to: extent)
let ciImage = sourceImage.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: transparent,
    kCIInputMaskImageKey: alphaMask,
]).cropped(to: extent)

let context = CIContext(options: [.cacheIntermediates: false])
guard let outCG = context.createCGImage(ciImage, from: extent) else {
    FileHandle.standardError.write(Data("输出失败\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: outCG)
try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
print("已输出透明背景 PNG")
