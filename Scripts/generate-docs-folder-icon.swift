#!/usr/bin/swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first
    ?? "Configuration/DocsFolderIcon.icns"
let visualScale: CGFloat = 0.62
let sourceIcon = URL(fileURLWithPath:
    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
    + "DocumentsFolderIcon.icns"
)
let fileManager = FileManager.default
let temporaryRoot = fileManager.temporaryDirectory
    .appendingPathComponent("halopin-docs-icon-\(UUID().uuidString)")
let sourceIconset = temporaryRoot.appendingPathComponent("source.iconset")
var paddedImages: [CGImage] = []

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "HaloPinIconGenerator",
            code: Int(process.terminationStatus)
        )
    }
}

try fileManager.createDirectory(
    at: temporaryRoot,
    withIntermediateDirectories: true
)

try run("/usr/bin/iconutil", [
    "-c", "iconset",
    sourceIcon.path,
    "-o", sourceIconset.path
])

for sourceURL in try fileManager.contentsOfDirectory(
    at: sourceIconset,
    includingPropertiesForKeys: nil
) where sourceURL.pathExtension == "png" {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        fatalError("Unable to process \(sourceURL.lastPathComponent)")
    }

    context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.interpolationQuality = .high
    let targetWidth = CGFloat(image.width) * visualScale
    let targetHeight = CGFloat(image.height) * visualScale
    let targetRect = CGRect(
        x: (CGFloat(image.width) - targetWidth) / 2,
        y: (CGFloat(image.height) - targetHeight) / 2,
        width: targetWidth,
        height: targetHeight
    )
    context.draw(image, in: targetRect)

    guard let paddedImage = context.makeImage() else {
        fatalError("Unable to render \(sourceURL.lastPathComponent)")
    }
    paddedImages.append(paddedImage)
}

guard let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL,
    UTType.icns.identifier as CFString,
    paddedImages.count,
    nil
) else {
    fatalError("Unable to create the ICNS destination")
}
for image in paddedImages {
    CGImageDestinationAddImage(destination, image, nil)
}
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to finish the ICNS file")
}
try? fileManager.removeItem(at: temporaryRoot)
