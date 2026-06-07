// WindowTitleSync.swift
// Limpid — keep `NSWindow.title` in sync with the active tab's display
// title, so the OS-level window header (Mission Control, ⌘`, app
// switcher previews) reflects the live terminal title even when the
// title bar itself is hidden.

import AppKit
import Foundation

@MainActor
final class WindowTitleSync {
    private weak var session: WindowSession?
    private weak var window: NSWindow?

    init(session: WindowSession, window: NSWindow) {
        self.session = session
        self.window = window
        // Push the initial value immediately so the window doesn't read
        // "Limpid" for one frame before the first observation fires.
        apply()

        // Re-arm the observation tracker after every fire so the title
        // keeps following all subsequent mutations.
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = self.session?.activeTabID
            if let tab = self.session?.activeTab {
                _ = tab.title
                _ = tab.titleOverride
            }
        } onChange: { [weak self] in
            self?.apply()
        }
    }

    private func apply() {
        guard let window else { return }
        let title = session?.activeTab?.displayTitle ?? "Limpid"
        // Avoid redundant writes — assigning the same string still bumps
        // AppKit's internal observers.
        if window.title != title {
            window.title = title
            // Setting title makes AppKit re-lay out the titlebar, which
            // resets traffic lights to default position. Re-apply our
            // slab-aligned offset so the shell title (vim / claude /
            // etc.) updating doesn't visibly knock the buttons sideways.
            repositionTrafficLights(in: window)
        }
    }
}
