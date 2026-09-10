//
//  InputForwarder+PiPPointer.swift
//
//  The Mac pointer over the Picture in Picture window drives the host's
//  pointer, 1:1. While PiP is up the stream window is an invisible mirror
//  source and keyboard/mouse forwarding is suspended (`pipSuspended`) - the
//  pointer belongs to whatever app is frontmost. But the PiP panel itself IS
//  the picture, and a pointer resting on it can only mean one thing, so its
//  position is mirrored onto the host as an absolute point the same way
//  window mode's free pointer is (PointerMapping): the host cursor sits under
//  the Mac cursor wherever it is on the picture, and stays put once the
//  pointer leaves the panel.
//
//  Motion is POLLED rather than event-driven. The panel is AVKit's (a private
//  `PIPPanel` in our process); we own no view in it, it hands out mouseMoved
//  only for its own hover controls, and a global monitor never sees events
//  destined for our own process. Reading `NSEvent.mouseLocation` at 120 Hz is
//  a few hundred nanoseconds per tick and needs no permission.
//
//  Clicks are forwarded deliberately conservatively: a mouse-down on the
//  panel is also how the user DRAGS the panel to another corner and how the
//  hover controls (close, return, pause) are pressed. So a down is held; the
//  up sends a press+release only if the pointer barely moved, the panel
//  didn't, and nothing of AVKit's took the click. Scroll goes through with the
//  stream view's own unit handling.
//

import AppKit

extension InputForwarder {

    /// Start (panel) or stop (nil) mirroring the pointer from the PiP panel.
    /// Called by StreamWindow when it locates the panel on PiP didStart, and
    /// with nil whenever PiP ends by any route. Idempotent.
    func setPiPPointerPanel(_ panel: NSWindow?) {
        guard let panel else { stopPiPPointerMirror(); return }
        guard pipPointerEnabledProvider() else { return }
        guard panel !== pipPointerPanel else { return }
        stopPiPPointerMirror()
        pipPointerPanel = panel
        pipLastPointer = nil
        pipPendingClick = nil
        // Poll in `.common` so a menu or a drag elsewhere doesn't freeze the
        // mirror mid-motion.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPiPPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pipPointerTimer = timer
        pipPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePiPPanelEvent(event) }
            return event
        }
        log.info("PiP pointer mirror on: the Mac pointer over the Picture in Picture window moves the host pointer")
    }

    func stopPiPPointerMirror() {
        guard pipPointerPanel != nil || pipPointerTimer != nil else { return }
        pipPointerTimer?.invalidate()
        pipPointerTimer = nil
        if let monitor = pipPointerMonitor {
            NSEvent.removeMonitor(monitor)
            pipPointerMonitor = nil
        }
        pipPointerPanel = nil
        pipLastPointer = nil
        pipPendingClick = nil
        log.info("PiP pointer mirror off")
    }

    /// The stream pixel under the pointer if it is over the PiP picture, else
    /// nil. `PointerMapping` also absorbs any letterbox inside the panel.
    private func pipStreamPoint(atScreen location: NSPoint) -> PointerMapping.StreamPoint? {
        guard let panel = pipPointerPanel, let content = panel.contentView else { return nil }
        guard panel.frame.contains(location) else { return nil }
        let viewPoint = content.convert(panel.convertPoint(fromScreen: location), from: nil)
        guard content.bounds.contains(viewPoint) else { return nil }
        return PointerMapping.streamPoint(
            viewPoint: viewPoint, viewSize: content.bounds.size, streamPixelSize: streamPixelSize)
    }

    private func pollPiPPointer() {
        guard isReady, pipPointerPanel != nil else { return }
        guard let point = pipStreamPoint(atScreen: NSEvent.mouseLocation) else { return }
        guard point != pipLastPointer else { return }
        if pipLastPointer == nil {
            log.info("PiP pointer mirror: first position \(point.x, privacy: .public),\(point.y, privacy: .public) of \(point.refW, privacy: .public)x\(point.refH, privacy: .public)")
        }
        pipLastPointer = point
        let rc = backend?.sendMousePosition(
            x: point.x, y: point.y, refW: point.refW, refH: point.refH) ?? -2
        record("LiSendMousePositionEvent(pip)", rc)
    }

    private func handlePiPPanelEvent(_ event: NSEvent) {
        guard isReady, let panel = pipPointerPanel, event.window === panel else { return }
        let location = NSEvent.mouseLocation
        switch event.type {
        case .scrollWheel:
            guard pipStreamPoint(atScreen: location) != nil else { return }
            forwardScroll(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pipPendingClick = nil
            // AVKit's hover controls (close, return, pause) take their own
            // clicks; only the bare picture is the host's.
            guard pipStreamPoint(atScreen: location) != nil,
                  let content = panel.contentView,
                  !pipHitIsControl(content.hitTest(content.convert(event.locationInWindow, from: nil)))
            else { return }
            pipPendingClick = PiPPendingClick(
                button: pipButton(for: event), screenLocation: location, panelFrame: panel.frame)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let pending = pipPendingClick else { return }
            pipPendingClick = nil
            guard pending.button == pipButton(for: event) else { return }
            // A drag moved the panel (or the pointer): not a click on the game.
            let moved = hypot(location.x - pending.screenLocation.x, location.y - pending.screenLocation.y)
            guard moved < 4, panel.frame == pending.panelFrame,
                  let point = pipStreamPoint(atScreen: location) else { return }
            // Position first so the host cursor is under the click even if
            // the poll hasn't caught up, then a whole press+release: the
            // host never holds a button from a window it can't see released.
            pipLastPointer = point
            let posRC = backend?.sendMousePosition(
                x: point.x, y: point.y, refW: point.refW, refH: point.refH) ?? -2
            record("LiSendMousePositionEvent(pip-click)", posRC)
            let pressRC = backend?.sendMouseButton(
                action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: pending.button) ?? -2
            record("LiSendMouseButtonEvent(pip-press)", pressRC)
            let releaseRC = backend?.sendMouseButton(
                action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: pending.button) ?? -2
            record("LiSendMouseButtonEvent(pip-release)", releaseRC)
        default:
            break
        }
    }

    /// AVKit's panel is private, so its controls are recognised by kind: any
    /// NSControl, or a view whose class name says button. The bare picture
    /// hit-tests to a plain content/host view.
    private func pipHitIsControl(_ view: NSView?) -> Bool {
        var v = view
        while let current = v {
            if current is NSControl { return true }
            if String(describing: type(of: current)).localizedCaseInsensitiveContains("button") { return true }
            v = current.superview
            if v === pipPointerPanel?.contentView { break }
        }
        return false
    }

    private func pipButton(for event: NSEvent) -> Int32 {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return StreamProtocol.BUTTON_LEFT
        case .rightMouseDown, .rightMouseUp: return StreamProtocol.BUTTON_RIGHT
        default:
            switch event.buttonNumber {
            case 3: return StreamProtocol.BUTTON_X1
            case 4: return StreamProtocol.BUTTON_X2
            default: return StreamProtocol.BUTTON_MIDDLE
            }
        }
    }
}
