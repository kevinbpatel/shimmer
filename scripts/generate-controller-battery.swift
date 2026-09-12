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
// THE LAYOUT IS NOT GUESSED EITHER - IT IS STEAM'S OWN, RUN THROUGH A BROWSER.
// The CSS cannot be read literally: `rotate` is a transform applied AFTER
// layout, so `width: 20px` describes the PRE-rotation box, and the battery's
// own component wraps its svg in a div (`<div class={cn(className, BatteryIcon,
// LegacySizing)}>`), so the positioning classes land on the wrapper, not the
// art. Measuring a screenshot with a ruler instead got the proportions close but
// wrong, twice.
//
// So the real construction was rebuilt as a page - Steam's DOM, Steam's four CSS
// rules, Steam's two SVGs - and handed to Chrome, which does the flex sizing,
// the `preserveAspectRatio` fit, the clip and the post-layout rotation itself.
// Magnified 40x (transform: scale, so layout stays at 1x and the vectors stay
// sharp) and measured, that gives, in container pixels:
//
//     pad, clipped to its left half    x  0.0..11.0   y 4.125..18.75
//     gap                              x 11.0..13.0
//     battery incl. nub                x 13.0..23.0   y 0.500..18.00
//
// which is 23 x 18.25 overall. Dividing through by the battery (its 42 units of
// long axis measure 17.5px, so 1 unit = 0.41667px) gives the numbers below:
// pad 26.4 wide by 35.1 tall, gap 4.8, and - the one that kept reading as the
// pad floating - the pad hangs 1.8 units BELOW the battery rather than sitting
// inside it.
//
// The battery is drawn from the numbers above rather than lifted. The PAD is
// Steam's own DualSense glyph, taken verbatim from the same bundle (viewBox
// 0 0 36 36, six paths, fill currentColor) - an explicit, informed call by the
// repo's owner to match Big Picture exactly; Valve's client artwork carries no
// redistribution grant, and CREDITS.md says so plainly. The CC0 alternative it
// replaced (Kenney's) is still in scripts/assets/, so swapping back is one line.
//
// Usage: swift scripts/generate-controller-battery.swift

import AppKit
import CoreGraphics
import Foundation

let padSource = URL(fileURLWithPath: "scripts/assets/steam-controller_dualsense.svg")
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

// Layout, same units (see the header for where these came from).
let padVisibleUnits: CGFloat = 26.4
/// Only a check: the pad's height follows from its own aspect once its width is
/// fixed, and for Steam's glyph that lands here. If a swapped-in pad drifts far
/// from this, the source's proportions differ from Steam's.
let padHeightUnits: CGFloat = 35.1
let gapUnits: CGFloat = 4.8
/// How far the pad hangs BELOW the battery. The pad is not centred against it
/// and does not sit inside it: Steam's battery starts 1.8 units up from the
/// bottom of the mark, and the pad's bottom edge is the lowest thing in it.
/// Centring the pad instead puts it a whole point too high at menu-bar size,
/// which reads as the pad floating.
let padDropUnits: CGFloat = 1.8

// Turned a quarter: the battery's long axis runs vertically, nub on top. The
// mark is as tall as the battery plus the pad's overhang beneath it.
let markHeightUnits = bodyLong + nubLong + padDropUnits  // 43.8
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

/// Tight box around the non-transparent pixels (origin bottom-left). Measured
/// rather than assumed, so the pad art can be swapped without retuning anything:
/// the source is drawn into a fixed 64x64 canvas whatever its own viewBox says
/// (Steam's is 36x36, Kenney's 64x64 with the art floating in the middle), and
/// everything downstream works off this box.
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

// The pad's height is not set here - it follows from its own aspect once the
// visible width is fixed. Check it against what Steam's glyph measured to in the
// browser, so swapping the source in can't silently change the mark's shape.
let padActualHeightUnits = padVisibleUnits * 2 * (padArt.height / padArt.width)
if abs(padActualHeightUnits - padHeightUnits) > 0.5 {
    let note = "warning: pad art is \(String(format: "%.2f", padActualHeightUnits)) units tall, "
        + "Steam's is \(padHeightUnits) - the source's proportions differ\n"
    FileHandle.standardError.write(Data(note.utf8))
}

// MARK: - Drawing

/// The battery's geometry for one output scale, resolved to WHOLE DEVICE PIXELS.
///
/// This is the difference between a battery and a smudge. Its border is 3 of the
/// body's 39 units, which at menu-bar size is 2.33 device pixels at 2x and 1.16
/// at 1x - fractional at every scale there is, so every edge anti-aliases to a
/// soft grey band and the nub, the smallest feature and the one at the top,
/// dissolves entirely. Steam has the same problem and lives with it; we don't
/// have to, because the shape is nothing but axis-aligned rectangles.
///
/// So each edge is snapped independently to the pixel grid rather than a
/// thickness being chosen and applied. Snapping edges keeps the border's
/// proportion (it lands on 2 or 3 pixels depending on where the edge falls,
/// which is what Steam's own raster does) instead of forcing one number that is
/// uniformly too thin or too heavy.
struct BatteryPixels {
    let outer: CGRect, hole: CGRect, nub: CGRect, fillTrack: CGRect
    /// Long-axis origin of the body, kept so the bolt can be placed in the same
    /// frame without re-deriving it.
    let bodyLeft: CGFloat, bodyBottom: CGFloat, right: CGFloat, unitPx: CGFloat

    /// - Parameter scale: 1 or 2; everything here is in that scale's device pixels.
    init(scale: Int) {
        let u = unit * CGFloat(scale)
        let x0 = (padVisibleUnits + gapUnits) * u    // battery's left edge
        let y0 = padDropUnits * u                    // the body's bottom, above the pad's overhang
        // Turned a quarter: the body's LONG axis runs up the image, its short
        // axis across it, so units along the long axis snap in y and across in x.
        func sx(_ across: CGFloat) -> CGFloat { (x0 + across * u).rounded() }
        func sy(_ along: CGFloat) -> CGFloat { (y0 + along * u).rounded() }
        func rect(_ a0: CGFloat, _ a1: CGFloat, _ l0: CGFloat, _ l1: CGFloat) -> CGRect {
            CGRect(x: sx(a0), y: sy(l0), width: max(1, sx(a1) - sx(a0)),
                   height: max(1, sy(l1) - sy(l0)))
        }
        outer = rect(0, bodyShort, 0, bodyLong)              // M39 6H0V30H39...
        // The border is inset from the SNAPPED outer rect by one rounded
        // thickness, not snapped edge by edge. Snapping its edges independently
        // is a touch truer in total area but lands 3 pixels on one side and 2 on
        // the other, and at this size that reads as a crooked battery.
        let wall = max(1, (border * u).rounded())
        hole = outer.insetBy(dx: wall, dy: wall)             // M36 9H3V27H36V9Z
        nub = rect((bodyShort - nubShort) / 2, (bodyShort + nubShort) / 2,   // x 39..42, y 14..22
                   bodyLong, bodyLong + nubLong)
        fillTrack = rect(fillOffsetShort, fillOffsetShort + fillShort,       // x=6 w=27, y=12 h=12
                         fillOffsetLong, fillOffsetLong + fillLong)
        bodyLeft = x0; bodyBottom = y0; right = sx(bodyShort); unitPx = u
    }

    /// Shell and hole as ONE even-odd path. It has to be one path: filling the
    /// outer rect and then CLEARING the inner one lays two anti-aliased edges
    /// over each other and leaves a grey rim, worst where the nub meets the body.
    /// A single even-odd fill gives each edge one coverage value.
    var shell: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: outer.minX, y: outer.minY))
        for pt in [(outer.maxX, outer.minY), (outer.maxX, outer.maxY), (nub.maxX, outer.maxY),
                   (nub.maxX, nub.maxY), (nub.minX, nub.maxY), (nub.minX, outer.maxY),
                   (outer.minX, outer.maxY)] {
            p.addLine(to: CGPoint(x: pt.0, y: pt.1))
        }
        p.closeSubpath()
        p.addRect(hole)
        return p
    }

    /// The charge, `<rect x=6 y=12 width={level}% of 27 height=12>`, growing up
    /// from the body's bottom. Its length is FLOORED, never rounded: a mark that
    /// reads fuller than the pad actually is, is the one error that matters.
    func fill(level: Double) -> CGRect? {
        guard level > 0 else { return nil }   // level 0 draws a bare shell, as Steam's does
        let length = (fillLong * CGFloat(level) * unitPx).rounded(.down)
        guard length >= 1 else { return nil }
        return CGRect(x: fillTrack.minX, y: fillTrack.minY, width: fillTrack.width, height: length)
    }

    /// Steam's bolt, `M16 20L21 11V16H26L21 25V20H16Z` in the 48x36 viewBox,
    /// turned with the rest of the battery. Left un-snapped: it is all diagonals,
    /// so there is no grid for it to land on.
    var bolt: CGPath {
        let p = CGMutablePath()
        // viewBox -> body-local (long from the body's left, across from its
        // bottom edge at y=30) -> the turned frame, where long runs up and
        // across runs in from the right.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: right - (30 - y) * unitPx, y: bodyBottom + x * unitPx)
        }
        p.move(to: point(16, 20)); p.addLine(to: point(21, 11))
        p.addLine(to: point(21, 16)); p.addLine(to: point(26, 16))
        p.addLine(to: point(21, 25)); p.addLine(to: point(21, 20))
        p.closeSubpath()
        return p
    }
}

func render(level: Double, charging: Bool, scale: Int) -> CGImage? {
    let s = CGFloat(scale)
    let width = Int((markWidth * s).rounded()), height = Int((markHeight * s).rounded())
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // Deliberately NOT scaled: the battery below is computed in device pixels so
    // it can be snapped to them, and a scaled CTM would put it back on halves.

    // The pad, drawn at DOUBLE its visible width and clipped to the left half -
    // Steam's `clip-path: inset(0 50% 0 0)` - and hanging below the battery.
    let padVisible = padVisibleUnits * unit * s
    let padFull = padVisible * 2
    ctx.saveGState()
    // The clip is a hard vertical cut in Steam too, so land it on a whole device
    // pixel rather than leaving a half-inked column down the pad's open side.
    ctx.clip(to: CGRect(x: 0, y: 0, width: padVisible.rounded(), height: CGFloat(height)))
    let padFit = padFull / padArt.width
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    ctx.saveGState()
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
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    ctx.restoreGState()

    let battery = BatteryPixels(scale: scale)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(battery.shell)
    ctx.fillPath(using: .evenOdd)
    if let charge = battery.fill(level: level) { ctx.fill(charge) }

    if charging {
        // Steam sets the bolt straight over the fill in `currentColor`. In a
        // one-colour template that would vanish into it, so the bolt gets a
        // punched-out gap first and is then set solid inside it - the same mark,
        // legible whether it lands on fill or on bare shell.
        let bolt = battery.bolt
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(bolt.copy(strokingWithWidth: 2.6 * battery.unitPx, lineCap: .round,
                              lineJoin: .round, miterLimit: 10))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(bolt)
        ctx.fillPath()
    }
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
