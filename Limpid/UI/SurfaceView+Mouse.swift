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
        // ⌥⌘+click arms a pane-drag pickup. We swallow the press from
        // libghostty entirely: a stationary click discards the anchor
        // on mouseUp, a click that moves past the threshold opens an
        // AppKit drag session in mouseDragged. The same modifier combo
        // is unbound in libghostty's default mouse pipeline (block
        // selection requires ⌃⌥), so we're not stealing a meaningful
        // gesture from the running program.
        if event.modifierFlags.contains([.option, .command]),
           paneID != nil,
           dragState != nil
        {
            armPaneDragAnchor(at: event.locationInWindow)
            return
        }
        // A click inside the pane is the user acknowledging it — clear
        // any pending unread ring/dot now. This is the trigger instead
        // of `becomeFirstResponder` because tab switches re-focus the
        // pane automatically and would otherwise dismiss the ring
        // before the user has even looked.
        onUserAcknowledge?()
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        // If this mouseUp closes out a ⌥⌘-click that never crossed the
        // drag threshold, drop the anchor and stay silent — libghostty
        // never saw the matching press, so it must not see a release.
        if isCapturingMouseForPaneDrag {
            discardPaneDragAnchor()
            return
        }
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    // We don't override `rightMouseDown`: AppKit's default implementation
    // calls `menu(for:)` for us (on both a physical right-click and a
    // trackpad two-finger tap), and that's where the right-press is sent —
    // only when there's no selection to protect. Emitting a press here too
    // would clear a mouse-reporting pane's shift-selection before the menu
    // could offer Copy.

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    /// Emit a right-mouse press to libghostty on behalf of `menu(for:)`.
    /// AppKit consumes the physical press when it shows a context menu, so
    /// without this libghostty (and any mouse-reporting program inside the
    /// pane) would never see the click. `menu(for:)` only calls this when
    /// the pane has no selection to protect — see the note there.
    func sendRightMousePressForMenu(with event: NSEvent) {
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
        updatePaneDragCursor(event)
        sendMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        // If a ⌥⌘ pickup is armed, wait for the cursor to move past the
        // threshold before opening the AppKit drag session. While armed
        // we don't forward mouse motion to libghostty — the running
        // program shouldn't see "drift" gestures that we're about to
        // turn into a tab-relocation.
        if isCapturingMouseForPaneDrag {
            if crossedPaneDragThreshold(at: event.locationInWindow) {
                beginPaneDrag(with: event)
            }
            return
        }
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
