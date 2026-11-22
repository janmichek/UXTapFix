#!/usr/bin/env swift
// Generates the UXTapFix app icon as an .iconset directory.
// Usage: swift tools/make-icon.swift <output.iconset>
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: make-icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
let tileRect = CGRect(x: 96, y: 96, width: 832, height: 832)
let cornerRadius: CGFloat = 186

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Could not create graphics context\n", stderr)
    exit(1)
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let tilePath = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
context.saveGState()
context.addPath(tilePath)
context.clip()

// Deep indigo-to-blue background.
let background = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        color(0.23, 0.30, 0.78).cgColor,
        color(0.30, 0.47, 0.96).cgColor,
        color(0.49, 0.69, 1.00).cgColor
    ] as CFArray,
    locations: [0.0, 0.58, 1.0]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 150, y: 950),
    end: CGPoint(x: 900, y: 90),
    options: []
)

// Soft radial light in the upper-left.
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(1, 1, 1, 0.34).cgColor, color(1, 1, 1, 0).cgColor] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 300, y: 820),
    startRadius: 0,
    endCenter: CGPoint(x: 300, y: 820),
    endRadius: 620,
    options: []
)

// MARK: Main glyph — dot, short line, dot
//
// A minimal mark for the three-finger tap: two fingertips either side of a
// short press. The mark fills most of the tile, with a wide, low center bar
// so it stays legible from 16 px up.

let glyphShadow = color(0.05, 0.08, 0.28, 0.30).cgColor
let dotDiameter: CGFloat = 156
let lineSize = CGSize(width: 100, height: 188)
let lineGap: CGFloat = 84
let glyphWidth = dotDiameter * 2 + lineSize.width + lineGap * 2
let glyphCenterY: CGFloat = 512
let dotY = glyphCenterY - dotDiameter / 2
let lineY = glyphCenterY - lineSize.height / 2
let leftDotX = (canvas - glyphWidth) / 2
let lineX = leftDotX + dotDiameter + lineGap
let rightDotX = lineX + lineSize.width + lineGap

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 34, color: glyphShadow)
color(1, 1, 1, 0.97).setFill()

for dotX in [leftDotX, rightDotX] {
    NSBezierPath(ovalIn: CGRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter)).fill()
}

NSBezierPath(
    roundedRect: CGRect(x: lineX, y: lineY, width: lineSize.width, height: lineSize.height),
    xRadius: lineSize.width / 2,
    yRadius: lineSize.width / 2
).fill()

context.restoreGState()

// Inner highlight around the edge.
context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 4, dy: 4), cornerWidth: cornerRadius - 4, cornerHeight: cornerRadius - 4, transform: nil))
context.setStrokeColor(color(1, 1, 1, 0.18).cgColor)
context.setLineWidth(8)
context.strokePath()

context.restoreGState()
master.unlockFocus()

func pngData(from image: NSImage, pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixelSize) in variants {
    guard let data = pngData(from: master, pixelSize: pixelSize) else {
        fputs("Could not render \(filename)\n", stderr)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(filename))
}

print("Wrote \(variants.count) icon images to \(outputDirectory.path)")
