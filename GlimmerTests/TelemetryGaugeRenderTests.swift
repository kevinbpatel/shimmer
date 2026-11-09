//
//  TelemetryGaugeRenderTests.swift
//
//  Telemetry rendering of 64-bit gauges.
//

import Foundation
import Testing
@testable import Glimmer

struct TelemetryGaugeRenderTests {

    /// `UInt64?.map(Double.init)` resolves to `Double(bitPattern:)` and renders ~0.
    @Test func uint64GaugesRenderTheirCounts() {
        var snap = TelemetrySnapshot()
        snap.presentOnTimeCount = 4_321
        snap.presentLateCount = 1_234
        snap.awdlReSuppressTotal = 77
        snap.resource = ResourceSnapshot(physFootprintBytes: 987_654_321)
        let lines = TelemetryRenderer.prometheus(snap, extras: TelemetrySnapshot.Extras())
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        func value(_ name: String) -> String? {
            lines.first { $0.hasPrefix(name + "{") || $0.hasPrefix(name + " ") }?
                .split(separator: " ").last.map(String.init)
        }
        #expect(value("glimmer_present_on_time_frames") == "4321")
        #expect(value("glimmer_present_late_frames") == "1234")
        #expect(value("glimmer_awdl_resuppress_total") == "77")
        #expect(value("glimmer_process_phys_footprint_bytes") == "987654321")
    }
}
