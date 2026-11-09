//
//  ControllerArrivalOrderTests.swift
//
//  Sunshine creates a virtual pad from the FIRST packet it sees for a slot. If
//  that is a state packet rather than the arrival (type + capabilities), Auto
//  mode falls back to an Xbox 360 pad and a DualSense loses its touchpad
//  (Se7enbrc/glimmer#217, fixed upstream in 1693c84e). These pin the order
//  through InputForwarder against a recording backend: cold attach, hot attach,
//  a refused arrival, a reconnect onto a fresh backend, and removal.
//

import Foundation
import GameController
import os
import Testing
@testable import Glimmer

@MainActor
struct ControllerArrivalOrderTests {

    private func rig() -> (InputForwarder, ArrivalRecordingBackend) {
        let forwarder = InputForwarder(observeGamepads: false)
        let backend = ArrivalRecordingBackend()
        forwarder.setBackend(backend)
        return (forwarder, backend)
    }

    private func slot(of pad: GCController, in forwarder: InputForwarder) throws -> UInt8 {
        try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]).slot
    }

    @Test(.bug("https://github.com/Se7enbrc/glimmer/issues/217"))
    func padAttachedBeforeTheStreamIsAnnouncedBeforeAnyState() throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try slot(of: pad, in: forwarder)
        let ex = try #require(pad.extendedGamepad)

        // Input before the connection is up goes nowhere.
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        #expect(backend.events.isEmpty)

        forwarder.setReady(true)
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        let sent = backend.events.filter { $0.slot == slot }
        #expect(sent.first == .arrival(slot))
        #expect(sent.filter { $0 == .arrival(slot) }.count == 1)
        #expect(sent.dropFirst().allSatisfy { $0 == .state(slot) })
        #expect(sent.count >= 2)
    }

    @Test func padAttachedMidStreamIsAnnouncedBeforeAnyState() throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.setReady(true)
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try slot(of: pad, in: forwarder)
        forwarder.sendGamepadUpdate(pad: try #require(pad.extendedGamepad), slot: slot)
        #expect(backend.events.filter { $0.slot == slot } == [.arrival(slot), .state(slot)])
    }

    /// A refused arrival must hold state back, then be retried ahead of the next state.
    @Test func refusedArrivalHoldsStateUntilTheHostKnowsThePad() throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try slot(of: pad, in: forwarder)
        let ex = try #require(pad.extendedGamepad)

        backend.arrivalResult.withLock { $0 = -2 }
        forwarder.setReady(true)
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        forwarder.resyncControllers()
        #expect(backend.events.isEmpty)
        #expect(!forwarder.announcedControllerSlots.contains(slot))

        backend.arrivalResult.withLock { $0 = 0 }
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        #expect(backend.events == [.arrival(slot), .state(slot)])
    }

    /// A reconnect swaps in a backend that has seen nothing: it must get the arrival first again.
    @Test func reconnectReannouncesBeforeState() throws {
        let (forwarder, first) = rig()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try slot(of: pad, in: forwarder)
        let ex = try #require(pad.extendedGamepad)
        forwarder.setReady(true)
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        #expect(first.events.first == .arrival(slot))

        forwarder.setReady(false)
        let fresh = ArrivalRecordingBackend()
        forwarder.setBackend(fresh)
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        #expect(fresh.events.isEmpty)
        forwarder.setReady(true)
        forwarder.sendGamepadUpdate(pad: ex, slot: slot)
        let sent = fresh.events.filter { $0.slot == slot }
        #expect(sent.first == .arrival(slot))
        #expect(sent.dropFirst().allSatisfy { $0 == .state(slot) })
    }

    /// Removal is only sent for a pad the host was told about; an unannounced slot has nothing to remove.
    @Test(arguments: [false, true])
    func removalFollowsOnlyAnAcceptedArrival(arrivalAccepted: Bool) throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        backend.arrivalResult.withLock { $0 = arrivalAccepted ? 0 : -2 }
        forwarder.setReady(true)
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try slot(of: pad, in: forwarder)
        forwarder.detach(gamepad: pad)
        #expect(backend.events == (arrivalAccepted ? [.arrival(slot), .removal(slot)] : []))
        #expect(forwarder.announcedControllerSlots.isEmpty)
    }

    /// Upstream 2026.11.0 crashed starting a stream with a PlayStation controller: GameController ran
    /// the handler on a dedicated capture queue, and the touchpad-sampling closures inherited
    /// MainActor isolation from where the handler was installed (fixed in 1693c84e). Shimmer leaves
    /// GameController on its main-queue default, so the handler runs on main. This pins that, and
    /// drives synthetic DualSense and DualShock profiles, touchpad read included, through it.
    @Test(arguments: [false, true])
    func playStationProfilesRunThroughTheInstalledHandlerOnMain(dualSense: Bool) throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        let controller = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: controller)
        #expect(controller.handlerQueue === DispatchQueue.main)
        let slot = try slot(of: controller, in: forwarder)
        forwarder.setReady(true)
        let handler = try #require(controller.extendedGamepad?.valueChangedHandler)
        let pad: GCExtendedGamepad = dualSense ? GCDualSenseGamepad() : GCDualShockGamepad()
        #expect(forwarder.touchpadElements(of: pad) != nil)
        handler(pad, pad.buttonA)
        #expect(backend.events.filter { $0.slot == slot }.contains(.state(slot)))
    }
}


/// Records the controller packets the backend ACCEPTED, in order. Everything else is inert.
final class ArrivalRecordingBackend: StreamingBackend {
    enum Event: Equatable {
        case arrival(UInt8)
        case state(UInt8)
        case removal(UInt8)

        var slot: UInt8 {
            switch self {
            case .arrival(let slot), .state(let slot), .removal(let slot): slot
            }
        }
    }

    private let recorded = OSAllocatedUnfairLock(initialState: [Event]())
    let arrivalResult = OSAllocatedUnfairLock(initialState: Int32(0))
    var events: [Event] { recorded.withLock { $0 } }

    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        let slot = UInt8(num)
        let present = (UInt16(bitPattern: mask) >> slot) & 1 == 1
        recorded.withLock { $0.append(present ? .state(slot) : .removal(slot)) }
        return 0
    }

    func sendControllerArrival(num: UInt8, mask: UInt16, type: UInt8,
                               supportedButtons: UInt32, caps: UInt16) -> Int32 {
        let result = arrivalResult.withLock { $0 }
        guard result == 0 else { return result }
        recorded.withLock { $0.append(.arrival(num)) }
        return 0
    }

    func startConnection(server: BackendServerInfo, config: BackendStreamConfig) throws {
        Issue.record("Controller ordering tests must never open a network connection")
    }
    func startConnectionAsync(server: BackendServerInfo, config: BackendStreamConfig) async throws {
        Issue.record("Controller ordering tests must never open a network connection")
    }
    func stopConnection() {}
    func interruptConnection() {}
    func attachVideoSink(_ sink: VideoSink) {}
    func attachAudioSink(_ sink: NativeAudioSink) {}
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? { nil }
    func requestIdrFrame() {}
    func hdrMetadata() -> HdrMetadata? { nil }
    func launchUrlQueryParameters() -> String { "" }
    func stageName(for stage: Int32) -> String { "" }
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 { 0 }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
    func sendControllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
                             pointerId: UInt32, x: Float, y: Float, pressure: Float) -> Int32 { 0 }
    func sendControllerMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 { 0 }
}
