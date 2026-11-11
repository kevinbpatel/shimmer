//
//  PictureInPictureTests.swift
//
//  Hardware-free coverage for the Picture in Picture decision logic: the
//  present-suppression truth table StreamWindow feeds the decoder, the
//  mirror-source sizing that keeps the 1:1 PiP mirror free of hairline gaps,
//  the default chord's non-collision with the other client-side chords, and
//  the keep-alive that redraws the PiP panel (see `PiPKeepAlive`).
//

import AppKit
import CoreGraphics
import Testing
@testable import Glimmer

struct PictureInPictureTests {

    // MARK: - Present suppression truth table

    private func suppressed(
        backgrounded: Bool, pipActive: Bool = false, pipPending: Bool = false, pipPaused: Bool = false
    ) -> Bool {
        StreamWindow.presentSuppressedState(
            backgrounded: backgrounded, pipActive: pipActive, pipPending: pipPending, pipPaused: pipPaused)
    }

    @Test func visibleWindowIsNeverSuppressed() {
        #expect(suppressed(backgrounded: false) == false)
        #expect(suppressed(backgrounded: false, pipActive: true) == false)
        #expect(suppressed(backgrounded: false, pipPending: true) == false)
    }

    @Test func hiddenWindowWithoutPiPIsSuppressed() {
        // The pre-PiP behaviour: Cmd-Tab away → drain to newest, decode gates.
        #expect(suppressed(backgrounded: true) == true)
    }

    @Test func hiddenWindowShowingInPiPIsNotSuppressed() {
        #expect(suppressed(backgrounded: true, pipActive: true) == false)
    }

    @Test func hiddenWindowWhilePiPIsStartingIsNotSuppressed() {
        // Entering PiP must not cost a drain + IDR resync for the ~100ms AVKit
        // takes to bring the window up.
        #expect(suppressed(backgrounded: true, pipPending: true) == false)
    }

    @Test func pauseFromPiPControlsSuppressesRegardless() {
        #expect(suppressed(backgrounded: true, pipActive: true, pipPaused: true) == true)
        #expect(suppressed(backgrounded: false, pipActive: true, pipPaused: true) == true)
    }

    // MARK: - Mirror-source sizing

    private let sixteenNine = CGSize(width: 1920, height: 1080)

    @Test func sourceOnTheAspectLineIsThePanelSize() {
        #expect(StreamWindowGeometry.pipSourceSize(covering: CGSize(width: 480, height: 270), aspect: sixteenNine)
            == CGSize(width: 480, height: 270))
    }

    @Test func panelWiderThanTheStreamKeepsWidthAndGrowsHeight() {
        // 577x324 is 0.56pt wider than 16:9 - the case that painted a white
        // column: the source keeps the panel's width and takes the exact 16:9
        // height, so the video fills the layer edge to edge.
        #expect(StreamWindowGeometry.pipSourceSize(covering: CGSize(width: 577, height: 324), aspect: sixteenNine)
            == CGSize(width: 577, height: 324.5625))
    }

    @Test func panelTallerThanTheStreamKeepsHeightAndGrowsWidth() {
        let size = StreamWindowGeometry.pipSourceSize(covering: CGSize(width: 504, height: 284), aspect: sixteenNine)
        #expect(size.height == 284)
        #expect(abs(size.width - 284 * 16 / 9) < 1e-9)
    }

    @Test func sourceAlwaysCoversThePanelAndSitsExactlyOnTheAspect() {
        // Every integer panel size AVKit produced in the sweep, plus a 16:10
        // stream in AVKit's 16:9 default box.
        let panels = [(540, 303), (577, 324), (497, 279), (466, 262), (600, 338), (445, 250), (1, 1)]
        for aspect in [sixteenNine, CGSize(width: 2560, height: 1600), CGSize(width: 3440, height: 1440)] {
            for (w, h) in panels {
                let panel = CGSize(width: w, height: h)
                let size = StreamWindowGeometry.pipSourceSize(covering: panel, aspect: aspect)
                let covers = size.width >= panel.width && size.height >= panel.height
                let underAPointOver = size.width < panel.width + 1 || size.height < panel.height + 1
                let ratioError = abs(size.width / size.height - aspect.width / aspect.height)
                #expect(covers)
                #expect(underAPointOver)
                #expect(ratioError < 1e-9)
            }
        }
    }

    @Test func degenerateAspectLeavesThePanelSizeAlone() {
        let panel = CGSize(width: 577, height: 324)
        #expect(StreamWindowGeometry.pipSourceSize(covering: panel, aspect: CGSize.zero) == panel)
        #expect(StreamWindowGeometry.pipSourceSize(covering: CGSize.zero, aspect: sixteenNine) == CGSize.zero)
    }

    // MARK: - Default chord

    @Test func defaultPiPChordDoesNotCollideWithOtherClientChords() {
        let chords: [HotkeyChord] = [.defaultQuit, .defaultStats, .defaultBookmark, .defaultPiP]
        for (i, a) in chords.enumerated() {
            for b in chords[(i + 1)...] {
                #expect(a != b)
            }
        }
    }

    // MARK: - Recording keep-alive

    /// What matters is that every nudge is a real change in the panel's own
    /// layer tree - a no-op assignment commits nothing, and nothing committed
    /// leaves the picture frozen.
    @MainActor @Test func keepAliveNudgesALayerInsideThePanelAndCleansUp() throws {
        let panelContent = NSView(frame: NSRect(x: 0, y: 0, width: 584, height: 329))
        let keepAlive = PiPKeepAlive(in: panelContent)
        let host = try #require(panelContent.subviews.first)
        #expect(panelContent.subviews.count == 1)
        let dot = try #require(host.layer?.sublayers?.first)
        #expect(dot.bounds.size == CGSize(width: 1, height: 1))

        let start = dot.position
        keepAlive.nudge()
        let moved = dot.position
        #expect(moved != start)
        keepAlive.nudge()
        #expect(dot.position != moved)

        // It sits over the picture's corner: clicks there must still reach PiP.
        #expect(panelContent.hitTest(NSPoint(x: 0.5, y: 0.5)) === panelContent)

        keepAlive.stop()
        #expect(panelContent.subviews.isEmpty)
    }

    @MainActor @Test func keepAliveBoundsTheFreezeToAFrameOrThree() {
        // 60 fps frames are 16.7 ms apart; staying stuck for more than a few
        // of them after the animation is a visible hitch.
        #expect(PiPKeepAlive.interval <= 0.05)
    }

    @Test func defaultPiPChordCarriesNoCommandModifier() {
        // No Cmd, so it is intercepted before the sys-keys gate and fires
        // regardless of the "use ⌘ shortcuts inside the game" toggle.
        #expect(HotkeyChord.defaultPiP.cmd == false)
        #expect(HotkeyChord.defaultPiP.displayString == "⌃⌥P")
    }
}
