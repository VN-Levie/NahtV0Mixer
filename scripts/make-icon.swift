#!/usr/bin/env swift
import AppKit
import Foundation

// Package the approved artwork without redesigning it. Drawing here is only
// deterministic scaling/alpha bounding for the macOS ICNS and template sizes.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make-icon.swift /path/to/AppIcon.icns\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let sourceURL = root.appendingPathComponent("Resources/NahtV0Mixer.icon/Assets/NahtV0Mixer.png")
let menuURL = root.appendingPathComponent("Resources/Brand/MenuBarSource.png")
guard let appImage = NSImage(contentsOf: sourceURL), let menuImage = NSImage(contentsOf: menuURL) else {
    fputs("Approved icon sources are missing.\n", stderr); exit(2)
}
let files = FileManager.default
let scratch = files.temporaryDirectory.appendingPathComponent("NahtV0Mixer-icon-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: scratch) }
func render(_ image: NSImage, width: Int, height: Int, source: CGRect = .zero) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.coderInvalidValue) }
    memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: source, operation: .copy, fraction: 1)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(appImage, width: points * scale, height: points * scale)
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

// Template artwork is transparent and monochrome. Keep its natural aspect ratio
// and use a tight alpha box so it remains legible in a 24×18-point status item.
let rep = NSBitmapImageRep(data: try Data(contentsOf: menuURL))!
var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { fputs("Menu icon has no visible pixels.\n", stderr); exit(2) }
let natural = CGSize(width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
let scale = min(24 / natural.width, 18 / natural.height)
let width = max(1, Int((natural.width * scale).rounded())), height = max(1, Int((natural.height * scale).rounded()))
menuImage.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
let box = CGRect(x: minX, y: rep.pixelsHigh - maxY - 1, width: Int(natural.width), height: Int(natural.height))
let menuData = try render(menuImage, width: width * 2, height: height * 2, source: box)
try menuData.write(to: output.deletingLastPathComponent().appendingPathComponent("MenuBarIcon.png"))
print("Icon packaged; menu template \(width)×\(height) pt (2×).")
