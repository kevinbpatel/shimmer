#!/usr/bin/swift
// Generates Assets.xcassets/ControllerBattery*.imageset - the menu-bar mark
// showing the pad AND its charge, built to Steam's Big Picture controller
// indicator.
//
// WHY THESE ARE ASSETS AND NOT TWO VIEWS. `MenuBarExtra(.menu)`'s label is
// rendered into an NSStatusItem button, which has exactly ONE image and one
// title. Probed in the real menu bar (2026-09-11): an HStack of two bare
// `Image(systemName:)`s draws only the FIRST; `Image(nsImage:)` draws nothing at
// all, with or without .renderingMode/.resizable; and attaching an `.overlay`
// to an Image makes even the Image disappear. So the pad and the battery cannot
// be composed at runtime - they have to arrive as one image, which is what this
// bakes.
//
// THE GEOMETRY IS STEAM'S, TAKEN FROM ITS OWN SOURCE. Steam's `Battery`
// component (steamui/chunk~2dcc5aaf7.js) draws, in a 0 0 48 36 viewBox:
//
//     shell  M39 6H0V30H39V22H42V14H39V6Z    hole  M36 9H3V27H36V9Z
//     fill   <svg x=6 y=12 width=27 height=12><rect width={level}% height=100%>
//     bolt   M16 20L21 11V16H26L21 25V20H16Z
//
// which is: body 39x24 with a 3-thick border, a 3x8 nub centred on the right,
// and a fill track 27x12 inset 3 inside the border. The fill is #59BF40, or
// #E01D79 at or below the 20% critical threshold. Square corners throughout -
// nothing like Apple's long, thin, rounded battery, which is why it never reads
// as a second system battery.
//
// And the layout, from the stylesheet plus the render site:
//
//     <div class=ControllerBatteryImgContainer>        position: relative
//       <ControllerType class=ControllerImg>           clip-path: inset(0 50% 0 0)
//       <Battery class=ControllerBatteryIndicator>     rotate: 270deg
//
// So the pad is clipped to its LEFT HALF and a quarter-turned battery (nub up)
// stands beside it, taller than the pad and overhanging it top and bottom.
//
// The CSS's own numbers cannot be used directly - `rotate` is a transform
// applied after layout, so `width: 20px` describes the PRE-rotation box and
// reading it literally got the proportions badly wrong. The sizes below are
// measured off a real Big Picture screenshot instead, in source pixels:
//
//     controller visible   30..51 x 24..52    22 x 29, hard vertical cut at 51
//     gap                  52..54             3 empty columns
//     battery body         55..74 x 21..53    20 x 33
//     nub                  62..67 x 19..20    6 x 2, centred
//
// The two agree: the battery body is 24 units wide by 39 tall once turned, an
// aspect of 0.615, and the screenshot measures 20 x 33 = 0.606. Body 24 units
// landing at 20px fixes the scale at 0.833 px/unit, which puts the visible pad
// at 26.4 units and the gap at 3.6 - the numbers used below.
//
// Only geometry is taken. Valve's client artwork ships under no redistribution
// grant, so every pixel here is drawn from the numbers, and the pad is Kenney's
// CC0 DualSense rather than Steam's own glyph.
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

// MARK: - Steam's units

// The battery, in its component's own units (pre-rotation, y measured up from
// the body's bottom edge).
let bodyLong: CGFloat = 39        // 0..39 in the viewBox
let bodyShort: CGFloat = 24       // y 6..30
let border: CGFloat = 3           // inner hole 3,9 -> 36,27
let nubLong: CGFloat = 3          // x 39..42
let nubShort: CGFloat = 8         // y 14..22
let fillOffsetLong: CGFloat = 6   // fill sub-svg x
let fillOffsetShort: CGFloat = 6  // fill sub-svg y 12, body top 6 -> 6 in body-local
let fillLong: CGFloat = 27
let fillShort: CGFloat = 12

// Layout, same units (see the header for how the scale was fixed).
let padVisibleUnits: CGFloat = 26.4
let padHeightUnits: CGFloat = 34.8
let gapUnits: CGFloat = 3.6

// Turned a quarter: the battery's long axis runs vertically, nub on top.
let markHeightUnits = bodyLong + nubLong                 // 42
let markWidthUnits = padVisibleUnits + gapUnits + bodyShort

/// Height of the finished mark in points, which sets the scale for everything.
let markHeight: CGFloat = 17
let unit = markHeight / markHeightUnits
let markWidth = markWidthUnits * unit

/// macOS asset catalogs use 1x and 2x; 3x is an iOS scale and would be dead
/// weight across 22 imagesets.
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

// MARK: - Drawing

/// Steam's bolt, `M16 20L21 11V16H26L21 25V20H16Z`, in the 48x36 viewBox. Given
/// back in the battery's own (y-up, body-local) frame.
func boltPath() -> CGPath {
    let path = CGMutablePath()
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: 30 - y)     // viewBox y-down, body top at y=30
    }
    path.move(to: point(16, 20)); path.addLine(to: point(21, 11))
    path.addLine(to: point(21, 16)); path.addLine(to: point(26, 16))
    path.addLine(to: point(21, 25)); path.addLine(to: point(21, 20))
    path.closeSubpath()
    return path
}

/// Draws the battery at `origin`, turned a quarter so the nub points up.
func drawBattery(in ctx: CGContext, origin: CGPoint, level: Double, charging: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: unit, y: unit)
    // +90 degrees puts the nub (at +x) on top; then slide the rotated art back
    // into the positive quadrant.
    ctx.rotate(by: .pi / 2)
    ctx.translateBy(x: 0, y: -bodyShort)

    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: bodyLong, height: bodyShort))
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.fill(CGRect(x: border, y: border,
                    width: bodyLong - border * 2, height: bodyShort - border * 2))
    ctx.restoreGState()

    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: bodyLong, y: (bodyShort - nubShort) / 2, width: nubLong, height: nubShort))

    // The charge. Empty draws a bare shell, as Steam's does at level 0.
    if level > 0 {
        ctx.fill(CGRect(x: fillOffsetLong, y: fillOffsetShort,
                        width: fillLong * CGFloat(level), height: fillShort))
    }

    if charging {
        // Steam draws the bolt straight over the fill in `currentColor`. In a
        // one-colour template that would vanish into it, so the bolt gets a
        // punched-out gap first and is then set solid inside it - the same mark,
        // legible whether it lands on fill or on bare shell.
        let bolt = boltPath()
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(bolt.copy(strokingWithWidth: 2.6, lineCap: .round,
                              lineJoin: .round, miterLimit: 10))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(bolt)
        ctx.fillPath()
    }
    ctx.restoreGState()
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

    // The pad, drawn at DOUBLE its visible width and clipped to the left half -
    // Steam's `clip-path: inset(0 50% 0 0)` - and centred against the battery,
    // which overhangs it above and below.
    let padVisible = padVisibleUnits * unit
    let padFull = padVisible * 2
    let padHeight = padHeightUnits * unit
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: padVisible, height: markHeight))
    let padFit = padFull / padArt.width
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    ctx.saveGState()
    ctx.translateBy(x: 0, y: (markHeight - padHeight) / 2)
    ctx.scaleBy(x: padFit, y: padFit)
    ctx.translateBy(x: -padArt.minX, y: -padArt.minY)
    padSVG.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    // The pad art is white-on-transparent; a template wants black-on-alpha.
    ctx.saveGState()
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: markWidth, height: markHeight))
    ctx.restoreGState()

    drawBattery(in: ctx, origin: CGPoint(x: (padVisibleUnits + gapUnits) * unit, y: 0),
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
      + String(format: "%.1fx%.1fpt", markWidth, markHeight))
