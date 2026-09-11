#!/usr/bin/swift
// Generates Assets.xcassets/ControllerBattery*.imageset - the menu-bar mark
// showing the pad AND its charge, the way Steam's Big Picture bar does.
//
// WHY THESE ARE ASSETS AND NOT TWO VIEWS. `MenuBarExtra(.menu)`'s label is
// rendered into an NSStatusItem button, which has exactly ONE image and one
// title. Probed in the real menu bar (2026-09-11): an HStack of two bare
// `Image(systemName:)`s draws only the FIRST; `Image(nsImage:)` draws nothing at
// all, with or without .renderingMode/.resizable; and attaching an `.overlay`
// to an Image makes even the Image disappear. So a pad beside a battery cannot
// be composed at runtime - it has to arrive as a single image, which is what
// this bakes.
//
// The battery is drawn here rather than taken from SF Symbols for two reasons:
// the `battery.*` family is five fixed levels and we want the eleven the pad
// actually reports, and rasterising an Apple symbol into a shipped asset to
// draw inside it is a modification of SF Symbols art that its license does not
// invite. A battery outline is a rounded rectangle with a nub - a universal
// idiom, not Apple's drawing - so it's ours. The PROPORTIONS are matched to
// Apple's, measured by diffing `battery.0` against `battery.100` at 256pt: the
// fill occupies x 0.1517, y 0.2524, w 0.6000, h 0.4903 of the symbol's box.
//
// Usage: swift scripts/generate-controller-battery.swift

import AppKit
import CoreGraphics
import Foundation

let padSource = URL(fileURLWithPath: "scripts/assets/kenney-controller_playstation5.svg")
let assetRoot = URL(fileURLWithPath: "Glimmer/Assets.xcassets")

/// The eleven levels a DualSense actually reports - its HID status byte carries
/// a 0...10 level, so finer steps would be invented precision and coarser ones
/// would throw away something real.
let levels = Array(stride(from: 0, through: 100, by: 10))

// Layout, in points. The whole mark is 44 x 14: pad, a gap, then the battery.
let markHeight: CGFloat = 14
let padWidth: CGFloat = 20
let gap: CGFloat = 4
let batteryWidth: CGFloat = 20
let markWidth = padWidth + gap + batteryWidth

// Battery geometry as fractions of its own box, from Apple's (see header).
let bodyWidthFraction: CGFloat = 0.86      // body, before the nub
let strokeFraction: CGFloat = 0.085        // of the battery box height
let fillInsetFraction: CGFloat = 0.175     // of the box height, inside the body
let nubHeightFraction: CGFloat = 0.34

/// macOS asset catalogs use 1x and 2x; 3x is an iOS scale and would be dead weight
/// across 22 imagesets.
let scales = [1, 2]

// MARK: - Pad artwork

func renderSVG(_ image: NSImage, size: CGSize, _ transform: (CGContext) -> Void) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    ctx.saveGState()
    transform(ctx)
    image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

/// Tight box around the non-transparent pixels, in the image's own coordinates
/// (origin bottom-left). The Kenney SVG is 64x64 with no viewBox and the art
/// fills only the middle, so this is measured rather than assumed.
func alphaBoundingBox(_ image: CGImage) -> CGRect? {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY),
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

guard let padSVG = NSImage(contentsOf: padSource) else {
    FileHandle.standardError.write(Data("cannot read \(padSource.path)\n".utf8)); exit(1)
}
let measureDimension = 1024
let measureScale = CGFloat(measureDimension) / 64.0
guard let measured = renderSVG(padSVG, size: CGSize(width: measureDimension, height: measureDimension), {
        $0.scaleBy(x: measureScale, y: measureScale) }),
      let box = alphaBoundingBox(measured) else {
    FileHandle.standardError.write(Data("pad measure pass failed\n".utf8)); exit(1)
}
let padArt = CGRect(x: box.minX / measureScale, y: box.minY / measureScale,
                    width: box.width / measureScale, height: box.height / measureScale)
print(String(format: "pad art: x %.2f-%.2f y %.2f-%.2f of the 64x64 source",
             padArt.minX, padArt.maxX, padArt.minY, padArt.maxY))

// MARK: - The mark

func drawBattery(in ctx: CGContext, box: CGRect, level: Double, charging: Bool) {
    let stroke = box.height * strokeFraction
    let nubWidth = box.width * 0.06
    let body = CGRect(x: box.minX + stroke / 2, y: box.minY + stroke / 2,
                      width: box.width * bodyWidthFraction - stroke,
                      height: box.height - stroke)
    let radius = body.height * 0.32
    ctx.setLineWidth(stroke)
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()

    // The positive terminal.
    let nub = CGRect(x: body.maxX + stroke * 0.9, y: box.midY - box.height * nubHeightFraction / 2,
                     width: nubWidth, height: box.height * nubHeightFraction)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(CGPath(roundedRect: nub, cornerWidth: nubWidth * 0.45,
                       cornerHeight: nubWidth * 0.45, transform: nil))
    ctx.fillPath()

    // The fill. Empty means EMPTY - a flat pad shows bare shell, the way every
    // other battery on the system does. Above zero the bar has a floor so 10%
    // still shows something, but the floor is kept small: at half the track
    // height it swallowed 10% and 20% into the same sliver, which is exactly the
    // end of the range where the steps have to be readable.
    let inset = box.height * fillInsetFraction
    let track = body.insetBy(dx: inset, dy: inset)
    if level > 0 {
        let barWidth = max(track.width * CGFloat(level), track.height * 0.25)
        let bar = CGRect(x: track.minX, y: track.minY, width: barWidth, height: track.height)
        let barRadius = bar.height * 0.3
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barRadius,
                           cornerHeight: barRadius, transform: nil))
        ctx.fillPath()
    }

    guard charging else { return }
    // A bolt knocked out of the bar alone vanishes wherever the bar isn't, so
    // punch an oversized bolt-shaped hole and set a solid bolt inside it. That
    // gives the bolt its own gap and it reads over fill, over empty, and across
    // the boundary between them.
    let bolt = boltPath(centredIn: CGRect(x: track.midX - track.height * 0.42,
                                          y: track.midY - track.height * 0.62,
                                          width: track.height * 0.84, height: track.height * 1.24))
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.addPath(bolt.copy(strokingWithWidth: stroke * 1.6, lineCap: .round,
                          lineJoin: .round, miterLimit: 10))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(bolt)
    ctx.fillPath()
}

/// A lightning bolt in `rect`, as the usual six-point zigzag.
func boltPath(centredIn rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
    }
    path.move(to: point(0.62, 1.0))
    path.addLine(to: point(0.08, 0.46))
    path.addLine(to: point(0.44, 0.46))
    path.addLine(to: point(0.34, 0.0))
    path.addLine(to: point(0.92, 0.56))
    path.addLine(to: point(0.56, 0.56))
    path.closeSubpath()
    return path
}

func render(level: Double, charging: Bool, scale: Int) -> CGImage? {
    let px = CGSize(width: markWidth * CGFloat(scale), height: markHeight * CGFloat(scale))
    guard let ctx = CGContext(
        data: nil, width: Int(px.width.rounded()), height: Int(px.height.rounded()),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    // Pad on the left, vertically centred, drawn from the trimmed SVG art.
    let padFit = min(padWidth / padArt.width, markHeight / padArt.height)
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    ctx.saveGState()
    ctx.translateBy(x: (padWidth - padArt.width * padFit) / 2,
                    y: (markHeight - padArt.height * padFit) / 2)
    ctx.scaleBy(x: padFit, y: padFit)
    ctx.translateBy(x: -padArt.minX, y: -padArt.minY)
    padSVG.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    // The pad art is white-on-transparent; a template wants black-on-alpha.
    ctx.saveGState()
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: markWidth, height: markHeight))
    ctx.restoreGState()

    // Battery on the right, slightly shorter than the pad so it reads as a
    // companion rather than a second icon.
    let batteryHeight = markHeight * 0.66
    drawBattery(in: ctx,
                box: CGRect(x: padWidth + gap, y: (markHeight - batteryHeight) / 2,
                            width: batteryWidth, height: batteryHeight),
                level: level, charging: charging)
    return ctx.makeImage()
}

// MARK: - Emit

func assetName(level: Int, charging: Bool) -> String {
    "ControllerBattery\(level)\(charging ? "Charging" : "")"
}

var written = 0
for level in levels {
    for charging in [false, true] {
        let name = assetName(level: level, charging: charging)
        let dir = assetRoot.appendingPathComponent("\(name).imageset")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var entries: [String] = []
        for scale in scales {
            guard let image = render(level: Double(level) / 100, charging: charging, scale: scale) else {
                FileHandle.standardError.write(Data("render failed for \(name)@\(scale)x\n".utf8))
                exit(1)
            }
            let file = scale == 1 ? "battery.png" : "battery@\(scale)x.png"
            try! NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:])!
                .write(to: dir.appendingPathComponent(file))
            entries.append("""
            {
              "filename" : "\(file)",
              "idiom" : "mac",
              "scale" : "\(scale)x"
            }
            """.replacingOccurrences(of: "\n", with: "\n      "))
            written += 1
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
        try! contents.write(to: dir.appendingPathComponent("Contents.json"),
                            atomically: true, encoding: .utf8)
    }
}
print("wrote \(levels.count * 2) imagesets (\(written) PNGs) at \(Int(markWidth))x\(Int(markHeight))pt")
