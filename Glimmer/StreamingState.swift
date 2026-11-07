//
//  StreamingState.swift
//
//  Typed phase enums used by `AppModel` to drive UI affordances
//  during pairing and streaming. Pre-refactor the same information was
//  carried by stringly-typed `String?` published properties; the UI then
//  string-matched for "✓" / "Streaming" to recover the phase. The enums
//  here name those states directly so the UI can switch on them.
//

import Foundation

// MARK: - PairingPhase

/// Lifecycle of an in-flight pairing handshake with a Sunshine/GFE host.
/// Drives the PairSheet's spinner, PIN field, and result banner.
///
/// Each non-`idle` case carries the localized status text we display while
/// in that phase - old call sites read this through the `pairingMessage`
/// computed shim on `AppModel` (kept for back-compat during the
/// gradual UI migration). New call sites should switch on the phase
/// directly.
enum PairingPhase: Equatable {
    case idle
    case awaitingPin(String)
    case verifying(String)
    case success(String)
    case failure(String)
}

/// Actionable pairing failures which do not disclose PIN or signature checks.
enum PairingAttemptFailure: Error, Equatable {
    case timedOut, busy, disconnected

    var message: String {
        switch self {
        case .timedOut: "The code wasn't entered in time. Try again to get a new code."
        case .busy: "Sunshine has another pairing request open. Close it on the PC, then try again."
        case .disconnected: "The connection to Sunshine was lost. Check that Sunshine is running, then try again."
        }
    }
}

/// Explain only what the failed pre-pairing probe actually established.
/// PIN and signature failures continue to share their existing generic message.
enum PairingConnectionMessage {
    static func message(for error: Error) -> String {
        if let error = error as? StreamError {
            switch error {
            case .hostUnreachable(let detail):
                if detail.hasPrefix("address not found:") {
                    return "Address not found. Check the IP address or hostname."
                }
                if detail.hasPrefix("name lookup failed:") {
                    return "Couldn’t look up this address. Check your network connection and try again."
                }
                if detail.hasPrefix("malformed HTTP") || detail.hasPrefix("unparseable HTTP") || detail == "empty HTTP response" {
                    return "This address didn’t return a streaming server. Check the address and Sunshine."
                }
            case .launchFailed:
                return "This PC returned an unexpected response. Check that Sunshine is running."
            case .crypto:
                return "Couldn’t prepare a secure connection. Restart Shimmer and try again."
            default: break
            }
        }
        return "Couldn’t reach this PC. Make sure it’s on and Sunshine is running."
    }
}

// MARK: - StreamPhase

/// Lifecycle of a live stream session. Backed by connection events from the
/// native backend (`stageStarting`, `connectionEstablished`,
/// `connectionTerminated`, ...) plus our own intent transitions (the user
/// pressed Stream → `connecting`, the user is exiting → `disconnecting`).
///
/// `connecting(stage:)` carries the engineering-jargon stage string from
/// the backend callback verbatim ("Starting RTSP handshake", "Initializing the
/// connection") so the UI can show progress without forcing every stage
/// into a closed enum case. The connect-banner translates that into a
/// user-friendly "Connecting to <host>..." itself.
enum StreamPhase: Equatable {
    case idle
    case connecting(stage: String)
    case streaming
    case disconnecting
    case error(String)
}
