//
//  PictureInPictureTests.swift
//
//  Hardware-free coverage for the Picture in Picture decision logic: the
//  present-suppression truth table StreamWindow feeds the decoder, and the
//  default chord's non-collision with the other client-side chords.
//

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

    // MARK: - Default chord

    @Test func defaultPiPChordDoesNotCollideWithOtherClientChords() {
        let chords: [HotkeyChord] = [.defaultQuit, .defaultStats, .defaultBookmark, .defaultPiP]
        for (i, a) in chords.enumerated() {
            for b in chords[(i + 1)...] {
                #expect(a != b)
            }
        }
    }

    @Test func defaultPiPChordCarriesNoCommandModifier() {
        // No Cmd, so it is intercepted before the sys-keys gate and fires
        // regardless of the "use ⌘ shortcuts inside the game" toggle.
        #expect(HotkeyChord.defaultPiP.cmd == false)
        #expect(HotkeyChord.defaultPiP.displayString == "⌃⌥P")
    }
}
