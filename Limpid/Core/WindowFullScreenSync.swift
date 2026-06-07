// WindowFullScreenSync.swift
// Limpid — mirrors the hosting `NSWindow`'s native fullscreen state into
// `WindowSession.isFullScreen` so the window background can neutralize
// its behind-window vibrancy while fullscreen.
//
// `WindowVibrancyBackground` (`NSVisualEffectView` with
// `blendingMode = .behindWindow`) blurs the framebuffer *behind* the
// window. In a regular window that backdrop is a mix of other windows so
// it reads neutral; in a native fullscreen Space the only thing behind
// the window is the desktop wallpaper, and `.underWindowBackground` is a
// desktop-tinted material, so the backdrop floods with the wallpaper's
// color. `ThreePaneLayout.windowBaseFill` reads `session.isFullScreen`
// and drains the saturation there — the blur stays, the hue goes neutral.
//
// Timing: we pre-set the flag on `willEnter` so the saturation drop is in
// place before the grow animation (no wallpaper flash on the way in), then
// re-sync from the real `styleMask` on `didEnter` / `didExit` so the flag
// matches the settled state — `didExit` fires after the shrink animation,
// so the drop also survives the way out. Caveat: if a fullscreen *enter*
// is cancelled / fails (no `did…` follow-up), the pre-set `true` lingers
// until the next transition. AppKit posts no failure notification, and
// taking over `window.delegate` to catch `windowDidFailToEnterFullScreen`
// would fight SwiftUI's own delegate, so we accept this rare edge.

import AppKit
import Foundation

@MainActor
final class WindowFullScreenSync: NSObject {
    private weak var session: WindowSession?
    private weak var window: NSWindow?

    init(session: WindowSession, window: NSWindow) {
        self.session = session
        self.window = window
        super.init()

        // Seed from the live state in case the window is restored
        // straight into fullscreen.
        session.isFullScreen = window.styleMask.contains(.fullScreen)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWillEnter(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(syncFromStyleMask(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(syncFromStyleMask(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Pre-set before the grow animation so the saturation drop is already
    /// in place — no wallpaper flash mid-transition.
    @objc private func handleWillEnter(_ note: Notification) {
        session?.isFullScreen = true
    }

    /// Authoritative sync once a transition settles. `didExit` fires after
    /// the shrink animation, so the drop survives the way out too.
    @objc private func syncFromStyleMask(_ note: Notification) {
        guard let window else { return }
        session?.isFullScreen = window.styleMask.contains(.fullScreen)
    }
}
