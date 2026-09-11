//
//  FrameRateRangeTests.swift
//
//  The CAFrameRateRange the pacer pins on the CADisplayLink. The floor is the
//  anti-throttle guarantee and must never exceed what the panel can do;
//  `preferred` is where content matching lives, and is deliberately different
//  on a panel that can vary from one that cannot.
//

import Testing
import QuartzCore
@testable import Glimmer

struct FrameRateRangeTests {

    private func range(fps: Double, panel: Double, vrr: Bool) -> CAFrameRateRange {
        FramePacer.preferredRange(
            forStreamIntervalSeconds: 1.0 / fps, panelMaxHz: panel, variableRefresh: vrr)
    }

    // MARK: The floor (unchanged behaviour, guarded)

    @Test func floorIsTheStreamRateWhenThePanelCanReachIt() {
        let r = range(fps: 60, panel: 120, vrr: false)
        #expect(r.minimum == 60)
    }

    /// A 60Hz panel physically cannot honour a 120Hz floor, so asking for one
    /// would be ignored or mis-honoured.
    @Test func floorNeverExceedsThePanel() {
        let r = range(fps: 120, panel: 60, vrr: false)
        #expect(r.minimum == 60)
        #expect(r.maximum == 60)
    }

    // MARK: Content matching

    /// A fixed-refresh panel gains nothing from being asked for the content
    /// rate, and the 4K240 measurement says asking costs pacing headroom - so
    /// it keeps asking for the full grid.
    @Test func fixedPanelAsksForTheFullGrid() {
        let r = range(fps: 60, panel: 120, vrr: false)
        #expect(r.preferred == 120)
        #expect(r.maximum == 120)
    }

    /// A panel macOS will actually vary is asked for the CONTENT rate, which is
    /// what lets the display drop to the stream's cadence instead of running
    /// flat out. The floor and ceiling are untouched, so the anti-throttle
    /// guarantee and the top of the range both survive.
    @Test func variablePanelAsksForTheContentRate() {
        let r = range(fps: 60, panel: 120, vrr: true)
        #expect(r.preferred == 60)
        #expect(r.minimum == 60)
        #expect(r.maximum == 120)
    }

    @Test func variablePanelStillClampsAnImpossibleRequest() {
        let r = range(fps: 240, panel: 120, vrr: true)
        #expect(r.preferred == 120)
        #expect(r.minimum == 120)
    }

    // MARK: Degenerate inputs

    @Test func nonsenseIntervalsFallBackTo60() {
        #expect(FramePacer.preferredRange(
            forStreamIntervalSeconds: 0, panelMaxHz: 120, variableRefresh: true).preferred == 60)
        #expect(FramePacer.preferredRange(
            forStreamIntervalSeconds: .nan, panelMaxHz: 120, variableRefresh: true).preferred == 60)
    }

    @Test func nonsensePanelFallsBackTo60() {
        let r = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1.0 / 60, panelMaxHz: 0, variableRefresh: false)
        #expect(r.maximum == 60)
    }
}
