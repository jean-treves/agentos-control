#!/usr/bin/env swift
// Draws the AgentOS app icon (spec §16.2): the SF Symbol shield.lefthalf.filled on a blue gradient,
// on the macOS icon grid (824 pt rounded square on a 1024 canvas). Nothing is downloaded.
// Usage: swift Scripts/make_icon.swift [AgentOSControl/Assets.xcassets/AppIcon.appiconset]
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
              ?? "AgentOSControl/Assets.xcassets/AppIcon.appiconset")
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                          (256, 1), (256, 2), (512, 1), (512, 2)]

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let unit = CGFloat(pixels) / 1024
    let square = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let tile = NSBezierPath(roundedRect: square, xRadius: 185 * unit, yRadius: 185 * unit)
    NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.20, blue: 0.42, alpha: 1),
               ending: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.86, alpha: 1))!
        .draw(in: tile, angle: 90)
    let config = NSImage.SymbolConfiguration(pointSize: 440 * unit, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(points * scale).write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
let catalog = out.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog)
}
print("icône écrite : \(out.path)")
