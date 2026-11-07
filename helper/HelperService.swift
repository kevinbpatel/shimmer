import Foundation
import os.log

/// The XPC front of the root helper. Each connection gets its own exported
/// `HelperPeer`, so a release on disconnect is attributed to the connection that
/// claimed awdl0. `@unchecked Sendable`: `lease` and the suppression transition
/// change together under `leaseLock`.
final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let suppressor: AWDLSuppressor
    private let clientRequirement: () -> String?
    private let leaseLock = NSLock()
    private var lease = HelperLease()
    private let log = OSLog(subsystem: "io.ugfugl.glimmer.helper", category: "XPC")

    /// - clientRequirement: the code-signing requirement for a new connection, or
    ///   nil to refuse it (see HelperClientRequirement).
    init(suppressor: AWDLSuppressor, clientRequirement: @escaping () -> String?) {
        self.suppressor = suppressor
        self.clientRequirement = clientRequirement
        super.init()
    }

    // MARK: Listener

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The OS checks the requirement against the peer's audit token before any
        // message reaches HelperPeer, and invalidates the connection on a mismatch.
        // See HelperClientRequirement for what it pins on Developer ID vs ad hoc.
        guard let requirement = clientRequirement() else {
            os_log("Rejecting XPC peer pid=%d: no client requirement could be derived",
                   log: log, type: .error, newConnection.processIdentifier)
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)
        let token = UUID()
        newConnection.exportedInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
        newConnection.exportedObject = HelperPeer(service: self, token: token)
        // Fail-safe: if the connection holding awdl0 down vanishes (quit, crash,
        // lost connection) without releasing, restore it.
        newConnection.invalidationHandler = { [weak self] in self?.peerInvalidated(token) }
        newConnection.resume()
        return true
    }

    // MARK: Requests (via HelperPeer)

    func setAWDLDown(_ down: Bool, reason: String, peer: UUID, reply: @escaping (Bool) -> Void) {
        // Bound the reason string so even a verified peer can't fill the log.
        let bounded = String(reason.prefix(128)).replacingOccurrences(of: "\n", with: " ")
        leaseLock.lock()
        lease.set(down: down, by: peer)
        suppressor.setSuppressing(down, reason: bounded)
        leaseLock.unlock()
        // Park: report verified state so the app's `suppressing` flag can't
        // claim a still-up radio (the heartbeat reconfirms as the async down
        // lands). Release just acks - restore success isn't the signal.
        reply(down ? !suppressor.isInterfaceUp() : true)
    }

    func peerInvalidated(_ peer: UUID) {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        guard lease.peerInvalidated(peer) else { return }
        suppressor.setSuppressing(false, reason: "app-disconnected")
    }

    func currentStatus(reply: @escaping (Bool, Date?) -> Void) {
        reply(suppressor.suppressing, suppressor.suppressionSince)
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("glimmer-helper-ok")
    }

    func reSuppressCount(reply: @escaping (UInt64) -> Void) {
        reply(suppressor.reSuppressCount)
    }
}

/// One connection's view of the helper: the protocol's four requests, tagged
/// with that connection's lease token.
private final class HelperPeer: NSObject, GlimmerHelperProtocol {
    private let service: HelperService
    private let token: UUID

    init(service: HelperService, token: UUID) {
        self.service = service
        self.token = token
    }

    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping (Bool) -> Void) {
        service.setAWDLDown(down, reason: reason, peer: token, reply: reply)
    }

    func currentStatus(reply: @escaping (Bool, Date?) -> Void) { service.currentStatus(reply: reply) }
    func ping(reply: @escaping (String) -> Void) { service.ping(reply: reply) }
    func reSuppressCount(reply: @escaping (UInt64) -> Void) { service.reSuppressCount(reply: reply) }
}
