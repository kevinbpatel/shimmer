#!/usr/bin/swift
// Generates Assets.xcassets/ControllerBattery*.imageset - the menu-bar mark
// showing the pad AND its charge, in the style Steam's Big Picture bar uses.
//
// WHY THESE ARE ASSETS AND NOT TWO VIEWS. `MenuBarExtra(.menu)`'s label is
// rendered into an NSStatusItem button, which has exactly ONE image and one
// title. Probed in the real menu bar (2026-09-11): an HStack of two bare
// `Image(systemName:)`s draws only the FIRST; `Image(nsImage:)` draws nothing at
// all, with or without .renderingMode/.resizable; and attaching an `.overlay`
// to an Image makes even the Image disappear. So a pad beside a battery cannot
// be composed at runtime - it has to arrive as a single image, which is what
// this bakes. The upside is that the fill can be continuous rather than
// quantised to the five levels SF Symbols ships.
//
// THE BATTERY IS STEAM'S, NOT APPLE'S, AND THAT IS THE POINT. An Apple-shaped
// battery sitting a few points from the Mac's OWN menu-bar battery reads as a
// second system battery - the two are the same object at a glance. Steam's is a
// different drawing entirely: short and fat where Apple's is long and thin
// (body 22.29 x 16, aspect 1.39, against Apple's 2.18), a thick border, and
// every corner SQUARE where Apple's is heavily rounded.
//
// Measured off Steam's own icon on a Linux install
// (~/.local/share/Steam/steamui, chunk~2dcc5aaf7.js, viewBox 0 0 24 24):
//     body   0,4      -> 22.2857,20     inner 1.714,6 -> 20.571,18
//     nub    22.2857,9.333 -> 24,14.667
//     fill   3.43,8   -> 18.86,16
// Only the PROPORTIONS are taken - the drawing here is ours. Valve's client art
// ships under no redistribution grant, and a rectangle with a nub is a universal
// idiom rather than anyone's authorship.
//
// TURNED VERTICAL. Steam draws this horizontally; upright is the one change,
// and it is what makes the mark unmistakable next to the system battery while
// keeping everything that makes it look like Steam's. It is also narrower,
// which is worth real estate on a notched display.
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

// Layout, in points.
let markHeight: CGFloat = 14
let padWidth: CGFloat = 20
let gap: CGFloat = 3
/// The battery body's SHORT side (its width, upright). Everything else is
/// derived from Steam's ratios below, so this is the only size knob.
let batteryShortSide: CGFloat = 9

// Steam's ratios, normalised to the body's short side.
let bodyLongRatio: CGFloat = 22.2857 / 16.0
let borderRatio: CGFloat = 1.85 / 16.0
let fillInsetRatio: CGFloat = 1.85 / 16.0
let nubLongRatio: CGFloat = 1.7143 / 16.0
let nubShortRatio: CGFloat = 5.3333 / 16.0

/// macOS asset catalogs use 1x and 2x; 3x is an iOS scale and would be dead
/// weight across 22 imagesets.
let scales = [1, 2]

let bodyLength = batteryShortSide * bodyLongRatio
let nubLength = batteryShortSide * nubLongRatio
let batteryWidth = batteryShortSide
let batteryHeight = bodyLength + nubLength
let markWidth = padWidth + gap + batteryWidth

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

/// Tight box around the non-transparent pixels (origin bottom-left). The Kenney
/// SVG is 64x64 with no viewBox and the art fills only the middle, so this is
/// measured rather than assumed - an asset update re-trims itself.
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

// MARK: - The battery

/// A lightning bolt in `rect`, the usual six-point zigzag.
func boltPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
    }
    path.move(to: point(0.60, 1.0))
    path.addLine(to: point(0.05, 0.44))
    path.addLine(to: point(0.42, 0.44))
    path.addLine(to: point(0.36, 0.0))
    path.addLine(to: point(0.95, 0.58))
    path.addLine(to: point(0.58, 0.58))
    path.closeSubpath()
    return path
}

func drawBattery(in ctx: CGContext, at origin: CGPoint, level: Double, charging: Bool) {
    let border = batteryShortSide * borderRatio
    let inset = batteryShortSide * fillInsetRatio
    let body = CGRect(x: origin.x, y: origin.y, width: batteryShortSide, height: bodyLength)

    // Square corners throughout - this is the whole reason it doesn't read as
    // the system battery. Border drawn as filled-outer minus cleared-inner.
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(body)
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.fill(body.insetBy(dx: border, dy: border))
    ctx.restoreGState()

    // Terminal, on top.
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: body.midX - batteryShortSide * nubShortRatio / 2, y: body.maxY,
                    width: batteryShortSide * nubShortRatio, height: nubLength))

    // The charge, rising from the bottom. Empty means EMPTY - a flat pad shows
    // bare shell, like every other battery. Above zero the bar has a floor so
    // 10% still shows, kept small so 10% and 20% stay distinguishable; that is
    // exactly the end of the range that has to be readable.
    let track = body.insetBy(dx: border + inset, dy: border + inset)
    if level > 0 {
        let height = max(track.height * CGFloat(level), track.width * 0.22)
        ctx.fill(CGRect(x: track.minX, y: track.minY, width: track.width, height: height))
    }

    guard charging else { return }
    // A bolt knocked out of the bar alone vanishes wherever the bar isn't and
    // reads as damage at a low level. Punch an oversized bolt-shaped hole, then
    // set a solid bolt inside it: it then reads over fill, over empty, and
    // across the boundary between them.
    let boltBox = CGRect(x: body.midX - body.width * 0.21, y: body.midY - bodyLength * 0.26,
                         width: body.width * 0.42, height: bodyLength * 0.52)
    let bolt = boltPath(in: boltBox)
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.addPath(bolt.copy(strokingWithWidth: border * 1.25, lineCap: .round,
                          lineJoin: .round, miterLimit: 10))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(bolt)
    ctx.fillPath()
}

func render(level: Double, charging: Bool, scale: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: Int((markWidth * CGFloat(scale)).rounded()),
        height: Int((markHeight * CGFloat(scale)).rounded()),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    // Pad on the left, vertically centred, from the trimmed SVG art.
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

    drawBattery(in: ctx,
                at: CGPoint(x: padWidth + gap, y: (markHeight - batteryHeight) / 2),
                level: level, charging: charging)
    return ctx.makeImage()
}

// MARK: - Emit

var written = 0
for level in levels {
    for charging in [false, true] {
        let name = "ControllerBattery\(level)\(charging ? "Charging" : "")"
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
print("wrote \(levels.count * 2) imagesets (\(written) PNGs) at "
      + String(format: "%.0fx%.0fpt", markWidth, markHeight))
