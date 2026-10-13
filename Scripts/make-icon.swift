#!/bin/swift
// Draws the app icon and writes it as an .icns.
//
// The icon is the product: the app is a coloured dot, so the icon is a dot. It
// is generated rather than committed as opaque binary art so the colour and the
// proportions can be reviewed as code.
//
//   swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
// iconutil only accepts a directory named *.iconset, whatever it holds.
let work = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CIStatus-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

/// Fixed sRGB rather than system colours: an icon is artwork, and the semantic
/// colours would otherwise depend on the Mac that happened to draw it.
let tileTop = CGColor(red: 0.137, green: 0.161, blue: 0.212, alpha: 1)
let tileBottom = CGColor(red: 0.078, green: 0.098, blue: 0.133, alpha: 1)
let dotGreen = CGColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)

func render(pixels: Int) -> CGImage? {
    let s = CGFloat(pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // The tile is inset so its rounded corners are inside the canvas rather than
    // clipped by it, which is what makes an icon look like it lost its padding.
    let inset = s * 0.08
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237 // Apple's corner proportion

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: space, colors: [tileTop, tileBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: tile.midX, y: tile.maxY),
                               end: CGPoint(x: tile.midX, y: tile.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Generous, because the dot is the whole idea.
    let radiusOfDot = s * 0.26
    ctx.setFillColor(dotGreen)
    ctx.fillEllipse(in: CGRect(x: s / 2 - radiusOfDot, y: s / 2 - radiusOfDot,
                               width: radiusOfDot * 2, height: radiusOfDot * 2))
    return ctx.makeImage()
}

/// The names `iconutil` expects, and the pixel size each one holds.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = render(pixels: variant.pixels),
          let dest = CGImageDestinationCreateWithURL(
              work.appendingPathComponent("\(variant.name).png") as CFURL,
              UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("could not write \(variant.name).png\n".utf8))
        exit(1)
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", work.path, "-o", output.path]
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output.path)")
