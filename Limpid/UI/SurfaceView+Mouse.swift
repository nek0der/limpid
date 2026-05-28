// SurfaceView+Mouse.swift
// Limpid — mouse and trackpad event routing to libghostty.

import AppKit
import GhosttyKit

extension SurfaceView {

    // MARK: - Tracking areas

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: - Button events

    override func mouseDown(with event: NSEvent) {
        // A click inside the pane is the user acknowledging it — clear
        // any pending unread ring/dot now. This is the trigger instead
        // of `becomeFirstResponder` because tab switches re-focus the
        // pane automatically and would otherwise dismiss the ring
        // before the user has even looked.
        onUserAcknowledge?()
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !didSendMenuPress {
            sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
        }
        didSendMenuPress = false
        // super triggers `menu(for:)` for trackpad two-finger taps where
        // AppKit doesn't call it before entering rightMouseDown.
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    /// Called from `menu(for:)` which fires BEFORE `rightMouseDown` on a
    /// physical right-click. Sets `didSendMenuPress` so `rightMouseDown`
    /// doesn't double-send the press to libghostty.
    func sendRightMousePressForMenu(with event: NSEvent) {
        didSendMenuPress = true
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    // Right-click context menu lives in `SurfaceView+ContextMenu.swift`.

    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    // MARK: - Motion events

    override func mouseMoved(with event: NSEvent) {
        sendMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 << 0 }
        switch event.momentumPhase {
        case .began: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue) << 1
        case .stationary: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue) << 1
        case .changed: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1
        case .ended: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 1
        case .cancelled: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue) << 1
        case .mayBegin: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue) << 1
        default: break
        }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods
        )
    }

    // MARK: - Internal helpers

    func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.translateMods(event.modifierFlags))
    }

    func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Pass POINTS (not pixels): libghostty handles the content-scale
        // conversion internally. AppKit's origin is bottom-left, libghostty
        // expects top-left.
        let x = Double(p.x)
        let y = Double(bounds.height - p.y)
        ghostty_surface_mouse_pos(surface, x, y, Self.translateMods(event.modifierFlags))
    }
}
