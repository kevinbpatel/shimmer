//
//  KeepAwakePolicyTests.swift
//
//  The "keep the Mac awake while streaming" choice: its default, how a
//  persisted value resolves, and which combinations of policy and window
//  state hold the sleep assertion. Pure - no session or ProcessInfo involved.
//

import Testing
@testable import Glimmer

struct KeepAwakePolicyTests {

    @Test func freshInstallAlwaysKeepsAwake() {
        // The behaviour every build before this one had.
        #expect(KeepAwakePolicy.defaultPolicy == .always)
        #expect(KeepAwakePolicy.persisted(rawValue: nil) == .always)
    }

    @Test func rawValuesResolveAndUnknownLandsOnTheDefault() {
        #expect(KeepAwakePolicy.persisted(rawValue: "never") == .never)
        #expect(KeepAwakePolicy.persisted(rawValue: "whileShowing") == .whileShowing)
        #expect(KeepAwakePolicy.persisted(rawValue: "sometimes") == .always)
    }

    @Test func alwaysHoldsRegardlessOfTheWindow() {
        #expect(KeepAwakePolicy.always.holdsSleepAssertion(windowShowing: true))
        #expect(KeepAwakePolicy.always.holdsSleepAssertion(windowShowing: false))
    }

    @Test func neverHoldsNothing() {
        #expect(!KeepAwakePolicy.never.holdsSleepAssertion(windowShowing: true))
        #expect(!KeepAwakePolicy.never.holdsSleepAssertion(windowShowing: false))
    }

    @Test func whileShowingFollowsTheWindow() {
        // Up and being played → awake; hidden or parked in Picture in Picture
        // (the window is backgrounded either way) → the Mac's own rules.
        #expect(KeepAwakePolicy.whileShowing.holdsSleepAssertion(windowShowing: true))
        #expect(!KeepAwakePolicy.whileShowing.holdsSleepAssertion(windowShowing: false))
    }

    @Test func everyPolicyHasAName() {
        for policy in KeepAwakePolicy.allCases {
            #expect(!policy.displayName.isEmpty)
        }
    }
}
