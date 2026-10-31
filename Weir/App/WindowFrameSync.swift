// WindowFrameSync.swift
// Weir — captures the user's `NSWindow` frame into the window's
// `WindowSelection` whenever it moves or resizes, and applies a
// previously-persisted frame when the window first attaches.
//
// `WindowSelection.frame` is the source of truth; the SessionStore
// auto-save observation tracks it and writes the new value to disk on a
// short debounce.

import AppKit
import Foundation

@MainActor
final class WindowFrameSync: NSObject {
    private weak var selection: WindowSelection?
    private weak var window: NSWindow?

    init(selection: WindowSelection, window: NSWindow) {
        self.selection = selection
        self.window = window
        super.init()

        // Apply the persisted frame first (if any). A frame that lies on
        // no connected screen (saved on a display since disconnected) is
        // centered on the primary screen, so it is not stranded off-screen.
        if let saved = selection.frame {
            // AppKit does not apply `contentMinSize` to programmatic
            // `setFrame` calls. Expand the restored frame explicitly before
            // setting it so an old snapshot cannot bypass the live-resize
            // floor. Preserve the top edge, where the title bar lives.
            let minimumFrameSize = window.frameRect(forContentRect: CGRect(
                origin: .zero,
                size: window.contentMinSize
            )).size
            let minimumSized = WindowFrameSync.expanding(saved, toAtLeast: minimumFrameSize)
            let target = WindowFrameSync.clamp(minimumSized, to: NSScreen.screens)
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
        // In full screen the window fills the screen; the frame to keep is
        // the one it goes back to, so a window saved in full screen still
        // has its own size once it leaves it. `isFullScreen` is set as the
        // transition starts (`WindowFullScreenSync`), so the resizes of the
        // animation in are left out as well.
        guard let window, let selection, !selection.isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        if selection.frame != frame {
            selection.frame = frame
        }
    }

    static func expanding(_ rect: CGRect, toAtLeast minimumSize: CGSize) -> CGRect {
        let width = max(rect.width, minimumSize.width)
        let height = max(rect.height, minimumSize.height)
        return CGRect(
            x: rect.minX,
            y: rect.maxY - height,
            width: width,
            height: height
        )
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
