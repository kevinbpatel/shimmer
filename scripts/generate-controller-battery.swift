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
// THE CONSTRUCTION IS STEAM'S, MEASURED FROM STEAM'S OWN CSS. Not guessed from
// a screenshot - read out of ~/.local/share/Steam/steamui on the Linux host.
// The markup is:
//
//     <div class=ControllerBatteryImgContainer>      width: 22px
//       <ControllerType class=ControllerImg>         clip-path: inset(0 50% 0 0)
//       <Battery class=ControllerBatteryIndicator>   rotate: 270deg
//     </div>                                         left: 7.5px; bottom: 2px
//                                                    (LowBatteryGauge) width: 20px
//
// So the mark is NOT a pad beside a battery. The pad is clipped to its LEFT
// HALF, and a horizontal battery rotated a quarter turn (nub up) is laid over
// the top of it, overlapping. The battery is taller than the pad and pokes out
// above it. That is what "a battery covering the controller" meant.
//
// The battery's own shape comes from Steam's battery icon in the same bundle
// (viewBox 0 0 24 24): body 0,4 -> 22.2857,20, inner 1.714,6 -> 20.571,18, nub
// 22.2857,9.333 -> 24,14.667, fill 3.43,8 -> 18.86,16. Short and fat with SQUARE
// corners - nothing like Apple's long, thin, rounded one, which is exactly why
// it doesn't read as a second system battery.
//
// Only geometry is taken. Valve's client art ships under no redistribution
// grant, so every pixel here is drawn from the numbers, and the pad is Kenney's
// CC0 DualSense rather than Steam's own.
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

// Steam's own numbers, in its 22px container ("units" below). Everything is
// expressed against them so the whole mark scales as one piece.
let containerUnits: CGFloat = 22          // container width
let padClipFraction: CGFloat = 0.5        // clip-path: inset(0 50% 0 0)
let batteryLongUnits: CGFloat = 20        // width: 20px, pre-rotation
let batteryLeftUnits: CGFloat = 7.5       // left: 7.5px
let batteryBottomUnits: CGFloat = 2       // bottom: 2px

// Steam's battery art, in its own 24x16 box (a 0 0 24 24 viewBox, art y 4..20).
let batteryArtLong: CGFloat = 24, batteryArtShort: CGFloat = 16
let bodyLongRatio: CGFloat = 22.2857 / 16.0
let borderRatio: CGFloat = 1.85 / 16.0
let fillInsetRatio: CGFloat = 1.85 / 16.0
let nubLongRatio: CGFloat = 1.7143 / 16.0
let nubShortRatio: CGFloat = 5.3333 / 16.0

/// Height of the finished mark in points. The bounding box is `batteryBottom +
/// batteryLong` units tall (the battery overhangs the pad), so this fixes scale.
let markHeight: CGFloat = 16
let unit = markHeight / (batteryBottomUnits + batteryLongUnits)

/// macOS asset catalogs use 1x and 2x; 3x is an iOS scale and would be dead
/// weight across 22 imagesets.
let scales = [1, 2]

// Derived, in points.
let padDrawWidth = containerUnits * unit                 // pad drawn at container width
let padVisibleWidth = padDrawWidth * padClipFraction     // ...then clipped to its left half
let batteryLong = batteryLongUnits * unit                // the battery's long axis (vertical)
let batteryShort = batteryLong * (batteryArtShort / batteryArtLong)
let batteryLeft = batteryLeftUnits * unit
let batteryBottom = batteryBottomUnits * unit
let markWidth = max(padVisibleWidth, batteryLeft + batteryShort)

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
//
// Drawn directly upright (Steam gets there with `rotate: 270deg` on a horizontal
// icon; the result is identical and this avoids a transform). Nub on top, fill
// rising from the bottom.

/// A lightning bolt in `rect`, the usual six-point zigzag.
func boltPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
    }
    path.move(to: point(0.60, 1.0)); path.addLine(to: point(0.05, 0.44))
    path.addLine(to: point(0.42, 0.44)); path.addLine(to: point(0.36, 0.0))
    path.addLine(to: point(0.95, 0.58)); path.addLine(to: point(0.58, 0.58))
    path.closeSubpath()
    return path
}

func drawBattery(in ctx: CGContext, level: Double, charging: Bool) {
    // `batteryShort` is the body's width; its length runs up the y axis, with
    // the nub above the body (so body + nub = batteryLong).
    let nub = batteryShort * nubLongRatio
    let bodyLength = batteryLong - nub
    let border = batteryShort * borderRatio
    let inset = batteryShort * fillInsetRatio
    let body = CGRect(x: batteryLeft, y: batteryBottom, width: batteryShort, height: bodyLength)

    // Square corners throughout - the reason it doesn't read as the system
    // battery. Border is filled-outer minus cleared-inner.
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(body)
    ctx.saveGState(); ctx.setBlendMode(.clear)
    ctx.fill(body.insetBy(dx: border, dy: border))
    ctx.restoreGState()

    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: body.midX - batteryShort * nubShortRatio / 2, y: body.maxY,
                    width: batteryShort * nubShortRatio, height: nub))

    // The charge. Empty means EMPTY; above zero the bar has a small floor so 10%
    // still shows without swallowing 20% into the same sliver.
    let track = body.insetBy(dx: border + inset, dy: border + inset)
    if level > 0 {
        ctx.fill(CGRect(x: track.minX, y: track.minY, width: track.width,
                        height: max(track.height * CGFloat(level), track.width * 0.22)))
    }

    guard charging else { return }
    // A plain knocked-out bolt vanishes wherever the bar isn't and reads as
    // damage at a low level. Punch an oversized bolt-shaped hole, then set a
    // solid bolt inside it.
    let bolt = boltPath(in: CGRect(x: body.midX - body.width * 0.21,
                                   y: body.midY - bodyLength * 0.26,
                                   width: body.width * 0.42, height: bodyLength * 0.52))
    ctx.saveGState(); ctx.setBlendMode(.clear)
    ctx.addPath(bolt.copy(strokingWithWidth: border * 1.25, lineCap: .round,
                          lineJoin: .round, miterLimit: 10))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(bolt); ctx.fillPath()
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

    // The pad, drawn at the FULL container width and clipped to its left half -
    // Steam's `clip-path: inset(0 50% 0 0)`. It sits on the baseline; the
    // battery overhangs it above.
    let padHeight = padDrawWidth * (padArt.height / padArt.width)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: padVisibleWidth, height: markHeight))
    let padFit = padDrawWidth / padArt.width
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 0)
    ctx.scaleBy(x: padFit, y: padFit)
    ctx.translateBy(x: -padArt.minX, y: -padArt.minY)
    padSVG.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
    _ = padHeight

    // The pad art is white-on-transparent; a template wants black-on-alpha.
    ctx.saveGState()
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: markWidth, height: markHeight))
    ctx.restoreGState()

    drawBattery(in: ctx, level: level, charging: charging)
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
