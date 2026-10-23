// WindowOcclusionSync.swift
// Limpid — tells the window registry whether one window can be seen at all.

import AppKit

/// Reports a window going off screen (hidden, minimized, fully covered)
/// and coming back, so the registry stops counting its panes as visible
/// while it is away.
///
/// The occlusion notification is the signal rather than `willClose` or
/// `orderOut`: at `willClose` the window still reads as visible, and
/// AppKit posts the occlusion change only once the window has actually
/// left the screen.
///
/// Bound before the window is first shown, it reports the window off
/// screen at first. That is not left standing: a new window starts without
/// `.visible` in its occlusion state, and AppKit posts the change when the
/// window first appears (tens of milliseconds after `showWindow`).
@MainActor
final class WindowOcclusionSync: NSObject {
    private let windowID: WindowID
    private weak var registry: WindowRegistry?
    private weak var window: NSWindow?

    init(windowID: WindowID, registry: WindowRegistry, window: NSWindow) {
        self.windowID = windowID
        self.registry = registry
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        report()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func occlusionChanged(_ note: Notification) {
        report()
    }

    private func report() {
        guard let window, let registry else { return }
        let isOnScreen = window.isVisible && window.occlusionState.contains(.visible)
        registry.windowScreenPresenceChanged(windowID, isOnScreen: isOnScreen)
    }
}
