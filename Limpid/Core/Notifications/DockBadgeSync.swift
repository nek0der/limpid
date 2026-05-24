// DockBadgeSync.swift
// Limpid — keeps `NSApp.dockTile.badgeLabel` in sync with the total
// unread count across every pane Limpid knows about. Same pattern as
// `WindowTitleSync` / `WindowFrameSync`: observe the @Observable
// session and push the derived value into AppKit.

import AppKit
import Foundation

@MainActor
final class DockBadgeSync {
    private weak var session: WindowSession?
    private let notificationManager: LimpidNotificationManager

    init(session: WindowSession, notificationManager: LimpidNotificationManager) {
        self.session = session
        self.notificationManager = notificationManager
        // Defer the initial refresh — `NSApp.dockTile` isn't safe to
        // touch until the run loop has come up.
        Task { @MainActor in
            self.refresh()
        }
        observeRepeatedly { [weak self] in
            // The cached scalar (`cachedWindowUnreadCount`) is
            // maintained incrementally by every unread mutator
            // (`markUnread` / `clearUnread` / `clearAllUnread` /
            // `restore(from:)`), so observing it directly means
            // unrelated `tabs` edits — split-tree changes, title
            // renames, drag reorders — don't fan out into a badge
            // recompute. Reading via `windowUnreadCount` to keep
            // the abstraction.
            _ = self?.session?.windowUnreadCount
        } onChange: { [weak self] in
            self?.refresh()
        }
    }

    /// Push the cached window-wide unread total onto the Dock badge.
    /// Reads `windowUnreadCount` (the incrementally-maintained scalar
    /// on `WindowSession`) instead of walking every pane.
    private func refresh() {
        guard let session else { return }
        notificationManager.setDockBadge(unreadCount: session.windowUnreadCount)
    }
}
