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

    private func range(fps: Double, panel: Double) -> CAFrameRateRange {
        FramePacer.preferredRange(forStreamIntervalSeconds: 1.0 / fps, panelMaxHz: panel)
    }

    // MARK: The floor (unchanged behaviour, guarded)

    @Test func floorIsTheStreamRateWhenThePanelCanReachIt() {
        let r = range(fps: 60, panel: 120)
        #expect(r.minimum == 60)
    }

    /// A 60Hz panel physically cannot honour a 120Hz floor, so asking for one
    /// would be ignored or mis-honoured.
    @Test func floorNeverExceedsThePanel() {
        let r = range(fps: 120, panel: 60)
        #expect(r.minimum == 60)
        #expect(r.maximum == 60)
    }

    // MARK: `preferred` is always the panel max

    /// Content matching was tried and reverted - CAFrameRateRange schedules our
    /// callbacks, it does not move the panel (see preferredRange's comment for
    /// the two probes that show the panel holding 120.04Hz throughout). So
    /// `preferred` asks for the full grid on every panel, variable or not, and
    /// these guard against quietly reintroducing the stream rate there.
    @Test func preferredIsAlwaysTheFullGrid() {
        #expect(range(fps: 60, panel: 120).preferred == 120)
        #expect(range(fps: 30, panel: 120).preferred == 120)
        #expect(range(fps: 144, panel: 240).preferred == 240)
    }

    @Test func theFloorStillTracksTheStreamUnderneathIt() {
        let r = range(fps: 30, panel: 120)
        #expect(r.minimum == 30)
        #expect(r.maximum == 120)
    }

    // MARK: Degenerate inputs

    @Test func nonsenseIntervalsFallBackTo60() {
        #expect(FramePacer.preferredRange(
            forStreamIntervalSeconds: 0, panelMaxHz: 120).minimum == 60)
        #expect(FramePacer.preferredRange(
            forStreamIntervalSeconds: .nan, panelMaxHz: 120).minimum == 60)
    }

    @Test func nonsensePanelFallsBackTo60() {
        let r = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1.0 / 60, panelMaxHz: 0)
        #expect(r.maximum == 60)
    }
}
