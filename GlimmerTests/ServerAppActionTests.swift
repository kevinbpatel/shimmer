import Testing
@testable import Glimmer

struct ServerAppActionTests {
    @Test func idleAppsLaunchEvenIfAnOldStageOrAppIsStillCached() {
        #expect(ServerAppAction(isStreaming: false, isCurrentApp: false,
                                connectingStage: "Connecting…", hasVideo: true) == .stream)
    }

    @Test func onlyTheCurrentAppCanControlALiveSession() {
        for stage in [nil, "Connecting…"] as [String?] {
            #expect(ServerAppAction(isStreaming: true, isCurrentApp: false,
                                    connectingStage: stage, hasVideo: true) == .unavailable)
        }
    }

    @Test func aPendingHandshakeOffersCancelInsteadOfStartingAgain() {
        #expect(ServerAppAction(isStreaming: true, isCurrentApp: true,
                                connectingStage: "Negotiating video…", hasVideo: false)
                == .cancelConnection("Negotiating video…"))
    }

    @Test func aReconnectOffersCancelEvenAfterVideoWasPreviouslyReceived() {
        #expect(ServerAppAction(isStreaming: true, isCurrentApp: true,
                                connectingStage: "Reconnecting…", hasVideo: true)
                == .cancelConnection("Reconnecting…"))
    }

    @Test func onlyAVerifiedLiveStreamOffersTheWayBack() {
        #expect(ServerAppAction(isStreaming: true, isCurrentApp: true,
                                connectingStage: nil, hasVideo: true) == .showStream)
        #expect(ServerAppAction(isStreaming: true, isCurrentApp: true,
                                connectingStage: nil, hasVideo: false) == .unavailable)
    }
}
