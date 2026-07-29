#!/usr/bin/swift

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first
    ?? "Configuration/DMGBackground.png"
let width = 700
let height = 420
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Unable to create DMG background context")
}

let bounds = CGRect(x: 0, y: 0, width: width, height: height)
let backgroundColors = [
    CGColor(red: 0.018, green: 0.075, blue: 0.22, alpha: 1),
    CGColor(red: 0.015, green: 0.25, blue: 0.72, alpha: 1)
] as CFArray
let backgroundGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: backgroundColors,
    locations: [0, 1]
)!
context.drawLinearGradient(
    backgroundGradient,
    start: CGPoint(x: 0, y: height),
    end: CGPoint(x: width, y: 0),
    options: []
)

let glowColors = [
    CGColor(red: 0.10, green: 0.62, blue: 1, alpha: 0.34),
    CGColor(red: 0.10, green: 0.62, blue: 1, alpha: 0)
] as CFArray
let glowGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: glowColors,
    locations: [0, 1]
)!
context.drawRadialGradient(
    glowGradient,
    startCenter: CGPoint(x: 350, y: 215),
    startRadius: 0,
    endCenter: CGPoint(x: 350, y: 215),
    endRadius: 330,
    options: []
)

func drawCentered(
    _ text: String,
    y: CGFloat,
    size: CGFloat,
    weight: String,
    alpha: CGFloat
) {
    let font = CTFontCreateWithName(
        "SFPro-\(weight)" as CFString,
        size,
        nil
    )
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName:
            CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
    ]
    let attributed = CFAttributedStringCreate(
        nil,
        text as CFString,
        attributes as CFDictionary
    )!
    let line = CTLineCreateWithAttributedString(attributed)
    let lineWidth = CGFloat(CTLineGetTypographicBounds(
        line,
        nil,
        nil,
        nil
    ))
    context.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: y)
    CTLineDraw(line, context)
}

drawCentered(
    "Install HaloPin",
    y: 337,
    size: 30,
    weight: "Bold",
    alpha: 1
)
drawCentered(
    "Drag HaloPin to the Applications folder",
    y: 305,
    size: 15,
    weight: "Medium",
    alpha: 0.82
)

context.setStrokeColor(CGColor(
    red: 1,
    green: 1,
    blue: 1,
    alpha: 0.86
))
context.setLineWidth(5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 282, y: 192))
context.addLine(to: CGPoint(x: 420, y: 192))
context.move(to: CGPoint(x: 402, y: 210))
context.addLine(to: CGPoint(x: 420, y: 192))
context.addLine(to: CGPoint(x: 402, y: 174))
context.strokePath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outputPath) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    fatalError("Unable to create DMG background image")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to encode DMG background")
}
