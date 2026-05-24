// WindowFrameSync.swift
// Limpid — captures the user's `NSWindow` frame into `WindowSession`
// whenever it moves or resizes, and applies a previously-persisted
// frame when the window first attaches.
//
// `WindowSession.windowFrame` is the source of truth; the SessionStore
// auto-save observation tracks it and writes the new value to disk on a
// short debounce.

import AppKit
import Foundation

@MainActor
final class WindowFrameSync: NSObject {
    private weak var session: WindowSession?
    private weak var window: NSWindow?

    init(session: WindowSession, window: NSWindow) {
        self.session = session
        self.window = window
        super.init()

        // Apply the persisted frame first (if any). We clamp to a
        // visible portion of the active screen so a frame saved on a
        // disconnected display doesn't strand the window off-screen.
        if let saved = session.windowFrame {
            let target = WindowFrameSync.clamp(saved, to: NSScreen.screens)
            window.setFrame(target, display: false)
        }

        // Capture future moves/resizes via `NSWindowDelegate`-style
        // selectors. Using selectors keeps the observer registration out
        // of an `[NSObjectProtocol]` (which the Swift 6 deinit isolation
        // rules cannot remove safely).
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWindowEvent(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowEvent(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowEvent(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWindowEvent(_ note: Notification) {
        capture()
    }

    private func capture() {
        guard let window, let session else { return }
        let frame = window.frame
        if session.windowFrame != frame {
            session.windowFrame = frame
        }
    }

    /// Make sure `rect` sits at least partly on one of the supplied
    /// screens. If it doesn't, drop it onto the visibleFrame of the
    /// primary screen.
    private static func clamp(_ rect: CGRect, to screens: [NSScreen]) -> CGRect {
        for screen in screens where screen.frame.intersects(rect) {
            return rect
        }
        guard let primary = screens.first else { return rect }
        let vf = primary.visibleFrame
        let w = min(rect.width, vf.width)
        let h = min(rect.height, vf.height)
        return CGRect(
            x: vf.midX - w / 2,
            y: vf.midY - h / 2,
            width: w,
            height: h
        )
    }
}
