#!/usr/bin/env swift
import AppKit
import Foundation

// Original vector artwork. All icon sizes are rendered directly, without web assets.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make-icon.swift /path/to/AppIcon.icns\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard output.pathExtension == "icns" else {
    fputs("The output must be an .icns file.\n", stderr)
    exit(2)
}
let files = FileManager.default
let scratch = files.temporaryDirectory.appendingPathComponent("NahtV0Mixer-icon-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: scratch) }

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let body = NSBezierPath(roundedRect: NSRect(x: 98, y: 98, width: 828, height: 828),
                            xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    shadow.set()
    NSColor(calibratedRed: 0.09, green: 0.17, blue: 0.25, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.33, blue: 0.41, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.23, alpha: 1)
    ])!
    gradient.draw(in: body, angle: -65)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    body.lineWidth = 3
    body.stroke()

    for (x, y) in [(CGFloat(316), CGFloat(560)), (CGFloat(512), CGFloat(398)), (CGFloat(708), CGFloat(656))] {
        let track = NSBezierPath(roundedRect: NSRect(x: x - 12, y: 280, width: 24, height: 464),
                                xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.32).setFill()
        track.fill()
        let level = NSBezierPath(roundedRect: NSRect(x: x - 8, y: 284, width: 16, height: y - 284),
                                xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.23, green: 0.89, blue: 0.78, alpha: 1).setFill()
        level.fill()
        NSGraphicsContext.saveGraphicsState()
        let knobShadow = NSShadow()
        knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        knobShadow.shadowBlurRadius = 16
        knobShadow.shadowOffset = NSSize(width: 0, height: -7)
        knobShadow.set()
        let knob = NSBezierPath(roundedRect: NSRect(x: x - 57, y: y - 39, width: 114, height: 78),
                               xRadius: 24, yRadius: 24)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
        let grip = NSBezierPath(roundedRect: NSRect(x: x - 25, y: y - 4, width: 50, height: 8),
                               xRadius: 4, yRadius: 4)
        NSColor(calibratedRed: 0.13, green: 0.32, blue: 0.39, alpha: 0.65).setFill()
        grip.fill()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Icon: \(output.path)")
