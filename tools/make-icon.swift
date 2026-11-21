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
let tileRect = CGRect(x: 64, y: 64, width: 896, height: 896)
let cornerRadius: CGFloat = 208

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawSymbol(named name: String, in rect: CGRect, color tint: NSColor, pointSize: CGFloat, weight: NSFont.Weight = .semibold) {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return }

    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    tint.set()
    NSRect(origin: .zero, size: symbol.size).fill()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size), from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
    let drawSize = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let drawRect = CGRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
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

// A soft shadow beneath the main glyph.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 42, color: color(0.05, 0.08, 0.28, 0.30).cgColor)
drawSymbol(
    named: "cursorarrow.click.2",
    in: CGRect(x: 210, y: 250, width: 600, height: 600),
    color: color(1, 1, 1, 0.98),
    pointSize: 470,
    weight: .medium
)
context.restoreGState()

// Power badge: a white disc with a gradient power glyph.
let badgeRect = CGRect(x: 652, y: 168, width: 238, height: 238)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0.03, 0.06, 0.22, 0.26).cgColor)
color(1, 1, 1, 0.97).setFill()
NSBezierPath(ovalIn: badgeRect).fill()
context.restoreGState()

let badgeInset = badgeRect.insetBy(dx: 48, dy: 48)
drawSymbol(
    named: "power",
    in: badgeInset,
    color: color(0.23, 0.35, 0.86),
    pointSize: 150,
    weight: .bold
)

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
