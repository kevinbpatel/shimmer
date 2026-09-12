//
//  LaunchPlanTests.swift
//
//  Which host endpoint a Stream click uses, from what the host reports is
//  running: /launch on an idle host, /resume when it is our own app on a
//  host that honours the new mode on resume (Sunshine), and /cancel+/launch
//  otherwise. Pure - no network.
//

import Testing
@testable import Glimmer

struct LaunchPlanTests {

    @Test func idleHostLaunches() {
        #expect(StreamSession.launchPlan(hintCurrentGame: 0, appID: 42, allowResume: true) == .launch)
        #expect(StreamSession.launchPlan(hintCurrentGame: 0, appID: 42, allowResume: false) == .launch)
    }

    @Test func ourOwnAppResumesOnSunshine() {
        // The app we disconnected from is still running: pick it back up
        // where it was, at the mode we ask for now.
        #expect(StreamSession.launchPlan(hintCurrentGame: 42, appID: 42, allowResume: true) == .resume)
    }

    @Test func ourOwnAppOnGameStreamRenegotiates() {
        // NVIDIA's host reuses the old stream configuration on /resume, so a
        // different device's mode would be ignored - keep cancel + launch there.
        #expect(StreamSession.launchPlan(hintCurrentGame: 42, appID: 42, allowResume: false) == .cancelThenLaunch)
    }

    @Test func anotherAppRunningIsATakeover() {
        #expect(StreamSession.launchPlan(hintCurrentGame: 7, appID: 42, allowResume: true) == .cancelThenLaunch)
        #expect(StreamSession.launchPlan(hintCurrentGame: 7, appID: 42, allowResume: false) == .cancelThenLaunch)
    }
}
