// WindowFullScreenSync.swift
// Limpid — mirrors the hosting `NSWindow`'s native fullscreen state into
// `WindowSelection.isFullScreen` so the window background can neutralize
// its behind-window vibrancy while fullscreen.
//
// `WindowVibrancyBackground` (`NSVisualEffectView` with
// `blendingMode = .behindWindow`) blurs the framebuffer *behind* the
// window. In a regular window that backdrop is a mix of other windows so
// it reads neutral; in a native fullscreen Space the only thing behind
// the window is the desktop wallpaper, and `.underWindowBackground` is a
// desktop-tinted material, so the backdrop floods with the wallpaper's
// color. `WindowBaseFill` reads `isFullScreen`
// and drains the saturation there — the blur stays, the hue goes neutral.
//
// Timing: we pre-set the flag on `willEnter` so the saturation drop is in
// place before the grow animation (no wallpaper flash on the way in), then
// re-sync from the real `styleMask` on `didEnter` / `didExit` so the flag
// matches the settled state — `didExit` fires after the shrink animation,
// so the drop also survives the way out. A fullscreen *enter* that fails
// has no `did…` follow-up, and AppKit posts no failure notification: only
// the window's delegate hears of it. Each window's controller
// (`ProjectWindowController`) is that delegate and calls `resync()` through
// `WindowSyncs.fullScreenEntryFailed()`.
//
// It also keeps `WindowSelection.areTrafficLightsHidden`, which the title
// bar reads to move its leading controls into the traffic lights' place. That
// flag clears on `willExit` instead, because the traffic lights reappear
// during the shrink animation.

import AppKit
import Foundation

@MainActor
final class WindowFullScreenSync: NSObject {
    private weak var selection: WindowSelection?
    private weak var window: NSWindow?

    init(selection: WindowSelection, window: NSWindow) {
        self.selection = selection
        self.window = window
        super.init()

        // Seed from the live state in case the window is restored
        // straight into fullscreen.
        selection.isFullScreen = window.styleMask.contains(.fullScreen)
        selection.areTrafficLightsHidden = selection.isFullScreen

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
            selector: #selector(handleWillExit(_:)),
            name: NSWindow.willExitFullScreenNotification,
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
        selection?.isFullScreen = true
        selection?.areTrafficLightsHidden = true
    }

    /// The traffic lights come back during the shrink animation, so the
    /// title bar makes room for them before `didExit`.
    @objc private func handleWillExit(_ note: Notification) {
        selection?.areTrafficLightsHidden = false
    }

    /// Authoritative sync once a transition settles. `didExit` fires after
    /// the shrink animation, so the drop survives the way out too.
    @objc private func syncFromStyleMask(_ note: Notification) {
        resync()
    }

    /// Reads the settled state off the window. Also called by an owner
    /// that hears of a failed transition (`WindowSyncs.fullScreenEntryFailed`).
    func resync() {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        selection?.isFullScreen = isFullScreen
        selection?.areTrafficLightsHidden = isFullScreen
    }
}
