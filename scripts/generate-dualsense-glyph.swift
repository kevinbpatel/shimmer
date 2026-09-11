#!/usr/bin/swift
// Generates Assets.xcassets/DualSenseGlyph.imageset - the menu-bar controller
// mark - from Kenney's CC0 `controller_playstation5.svg`, kept unmodified at
// scripts/assets/kenney-controller_playstation5.svg. See CREDITS.md.
//
// Two things this does that a plain export wouldn't:
//   * TRIMS. The source is a 64x64 SVG with no viewBox and the art only fills
//     the middle of it, so exporting as-is gives a glyph floating at about half
//     the height of its box. The alpha bounding box is measured from a large
//     render rather than hard-coded, so a future asset update re-trims itself.
//   * TEMPLATES. The source is #FFFFFF on transparent. AppKit template images
//     want the shape in BLACK with the alpha carrying the silhouette; the OS
//     then tints it (and inverts for dark menu bars) on its own.
//
// Usage: swift scripts/generate-dualsense-glyph.swift

import AppKit
import CoreGraphics
import Foundation

let source = URL(fileURLWithPath: "scripts/assets/kenney-controller_playstation5.svg")
let outputDir = URL(fileURLWithPath: "Glimmer/Assets.xcassets/DualSenseGlyph.imageset")

/// Point size of the glyph in the menu bar. A DualSense is about 1.5:1, and 20pt
/// wide sits it at the same optical weight as the SF Symbols beside it without
/// out-growing the 22pt bar.
let pointSize = CGSize(width: 20, height: 14)
/// Supersample factor for the measure-and-trim pass. Big enough that the alpha
/// bounding box is exact to well under a source unit.
let measureDimension = 1024

func renderSVG(_ image: NSImage, into size: CGSize, transform: (CGContext) -> Void) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    ctx.saveGState()
    transform(ctx)
    image.draw(in: NSRect(origin: .zero, size: NSSize(width: 64, height: 64)))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

/// The tight box around everything non-transparent, in the rendered image's
/// pixel coordinates (origin bottom-left, matching CoreGraphics).
func alphaBoundingBox(of image: CGImage) -> CGRect? {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    // The buffer's row 0 is the TOP of the CGImage, so flip y back.
    return CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY),
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

/// Repaint an alpha silhouette solid black, which is what a template image is.
func blackened(_ image: CGImage) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.draw(image, in: rect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(rect)
    return ctx.makeImage()
}

guard let svg = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("cannot read \(source.path)\n".utf8)); exit(1)
}

// Pass 1: render big and measure where the art actually is.
let measureScale = CGFloat(measureDimension) / 64.0
guard let measured = renderSVG(svg, into: CGSize(width: measureDimension, height: measureDimension), transform: {
    $0.scaleBy(x: measureScale, y: measureScale)
}), let box = alphaBoundingBox(of: measured) else {
    FileHandle.standardError.write(Data("measure pass failed\n".utf8)); exit(1)
}
let artRect = CGRect(x: box.minX / measureScale, y: box.minY / measureScale,
                     width: box.width / measureScale, height: box.height / measureScale)
print(String(format: "art occupies x %.2f-%.2f, y %.2f-%.2f of the 64x64 source",
             artRect.minX, artRect.maxX, artRect.minY, artRect.maxY))

// Pass 2: render each scale with the art mapped onto the full output box.
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
var entries: [String] = []
for scale in 1...3 {
    let size = CGSize(width: pointSize.width * CGFloat(scale),
                      height: pointSize.height * CGFloat(scale))
    let fit = min(size.width / artRect.width, size.height / artRect.height)
    guard let rendered = renderSVG(svg, into: size, transform: { ctx in
        // Centre the trimmed art in the output box, then scale the whole 64x64
        // canvas about it so the draw lands where we want.
        ctx.translateBy(x: (size.width - artRect.width * fit) / 2,
                        y: (size.height - artRect.height * fit) / 2)
        ctx.scaleBy(x: fit, y: fit)
        ctx.translateBy(x: -artRect.minX, y: -artRect.minY)
    }), let template = blackened(rendered) else {
        FileHandle.standardError.write(Data("render at \(scale)x failed\n".utf8)); exit(1)
    }
    let name = scale == 1 ? "dualsense.png" : "dualsense@\(scale)x.png"
    let rep = NSBitmapImageRep(cgImage: template)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outputDir.appendingPathComponent(name))
    entries.append("""
        {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x"
            }
    """.trimmingCharacters(in: .whitespaces))
    print("wrote \(name) (\(Int(size.width))x\(Int(size.height)))")
}

let contents = """
{
  "images" : [
    \(entries.joined(separator: ",\n    "))
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}

"""
try! contents.write(to: outputDir.appendingPathComponent("Contents.json"),
                    atomically: true, encoding: .utf8)
print("wrote Contents.json")
