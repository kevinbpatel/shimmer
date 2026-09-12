//
//  StreamWindowGeometry.swift
//
//  Pure sizing math for the stream window: the Window-mode pixel-mapped
//  opening size, the fit-to-screen clamp, the aspect conformance applied to a
//  restored autosaved frame, and the Picture in Picture mirror-source size. No
//  AppKit types beyond CGSize so the rules are unit-tested without a window or
//  a screen; StreamWindow+Windowed.swift and +PictureInPicture.swift feed them
//  the live scale factor, visible frame, and PiP panel size.
//

import CoreGraphics

enum StreamWindowGeometry {
    /// The narrowest a stream window may be dragged, in points. 640 wide (so
    /// 360 tall at 16:9) keeps the picture legible and the title bar's traffic
    /// lights from overlapping the title; anything smaller is a thumbnail.
    static let minimumContentWidth: CGFloat = 640

    /// Content size in points that shows `pixelWidth` x `pixelHeight` stream
    /// pixels 1:1 on a display with `backingScaleFactor` - a 1080p stream on a
    /// 2x Retina panel opens at 960 x 540 points. A non-positive scale (a
    /// screen mid-reconfigure) is treated as 1x rather than producing an
    /// infinite size.
    static func pixelMappedContentSize(
        pixelWidth: Int, pixelHeight: Int, backingScaleFactor: CGFloat
    ) -> CGSize {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        return CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }

    /// Scale `size` DOWN (never up) to fit inside `available`, preserving its
    /// aspect. The opening size for a 4K request on a 1080p-class panel: the
    /// pixel-mapped window would spill off the screen, so it opens as large as
    /// the visible area allows at the stream's aspect instead.
    static func fitted(_ size: CGSize, within available: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else {
            return size
        }
        let scale = min(available.width / size.width, available.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Conform a restored autosaved content size to this stream's aspect: keep
    /// the width the user last chose, derive the height, then fit to the
    /// screen. A frame saved from a 16:10 session opened for a 16:9 stream
    /// would otherwise letterbox on the first frame - the exact bars the
    /// aspect lock exists to prevent - because `setFrame` restores the saved
    /// rectangle verbatim (the aspect ratio only constrains interactive
    /// resizing).
    static func conformed(_ size: CGSize, toAspect aspect: CGSize, within available: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0, size.width > 0 else { return size }
        let conformed = CGSize(width: size.width, height: size.width * aspect.height / aspect.width)
        return fitted(conformed, within: available)
    }

    /// The minimum content size at this aspect: `minimumContentWidth` wide,
    /// the matching height, so the floor sits ON the aspect line and the
    /// resize constraint never fights the minimum.
    static func minimumContentSize(aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else {
            return CGSize(width: minimumContentWidth, height: minimumContentWidth * 9 / 16)
        }
        return CGSize(width: minimumContentWidth, height: minimumContentWidth * aspect.height / aspect.width)
    }

    /// The Picture in Picture mirror-source size: the smallest rect at the
    /// stream's EXACT aspect that covers `panel` (the PiP window's content).
    ///
    /// macOS PiP mirrors the source layer 1:1, and the PiP window is sized in
    /// whole pixels - so it is almost never exactly on the stream's aspect
    /// line (577x324 for a 16:9 stream, where 16:9 wants 324.56). A source
    /// layer sized to the panel would have `.resizeAspect` leave a sub-pixel
    /// pillarbox, which the mirror paints as a full white hairline down one
    /// edge (measured: any slack ≳ 0.5pt on an axis). Keeping the layer on the
    /// aspect line means the video fills it edge to edge; the < 1pt of excess
    /// is a fractional size on one axis, and hangs off the panel's top/right
    /// where the mirror clips it. (`.resizeAspectFill` is NOT an alternative:
    /// AVKit locks the panel's aspect to the visible video rect, which under
    /// fill is the panel's own rounded size - it then drifts on every resize.)
    /// A degenerate aspect or panel returns `panel` unchanged.
    static func pipSourceSize(covering panel: CGSize, aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0, panel.width > 0, panel.height > 0 else { return panel }
        if panel.width * aspect.height >= panel.height * aspect.width {
            // Wider than the stream: keep the width, take the aspect's height.
            return CGSize(width: panel.width, height: panel.width * aspect.height / aspect.width)
        }
        // Taller than the stream: keep the height, take the aspect's width.
        return CGSize(width: panel.height * aspect.width / aspect.height, height: panel.height)
    }
}
