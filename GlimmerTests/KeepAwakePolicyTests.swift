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
        // The retired three-way middle value migrates to "on".
        #expect(KeepAwakePolicy.persisted(rawValue: "whileShowing") == .always)
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

    @Test func toggleMapsOnToAlwaysAndOffToNever() {
        #expect(KeepAwakePolicy(isOn: true) == .always)
        #expect(KeepAwakePolicy(isOn: false) == .never)
        #expect(KeepAwakePolicy.always.isOn)
        #expect(!KeepAwakePolicy.never.isOn)
    }

    @Test func everyPolicyHasAName() {
        for policy in KeepAwakePolicy.allCases {
            #expect(!policy.displayName.isEmpty)
        }
    }
}
