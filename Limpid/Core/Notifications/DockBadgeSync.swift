// DockBadgeSync.swift
// Limpid — keeps `NSApp.dockTile.badgeLabel` in sync with the unread
// count of the notification history. Same pattern as
// `WindowTitleSync` / `WindowFrameSync`: observe the @Observable
// store and push the derived value into AppKit.
//
// The history's unread count — not the per-pane `windowUnreadCount` —
// is the number the Dock shows. Both the toolbar bell and the panel
// header read the same scalar, so the three surfaces always agree;
// the per-pane count only feeds the bell glyphs on individual rows,
// which by design ignore agent turns (the lifecycle badge and the
// Waiting list are those rows' attention channel).

import AppKit
import Foundation

@MainActor
final class DockBadgeSync {
    private let historyStore: NotificationHistoryStore
    private let notificationManager: LimpidNotificationManager

    init(historyStore: NotificationHistoryStore, notificationManager: LimpidNotificationManager) {
        self.historyStore = historyStore
        self.notificationManager = notificationManager
        // Defer the initial refresh — `NSApp.dockTile` isn't safe to
        // touch until the run loop has come up. `[weak self]` mirrors
        // the surrounding `observeRepeatedly` blocks so the file
        // pattern stays uniform.
        Task { @MainActor [weak self] in
            self?.refresh()
        }
        observeRepeatedly { [weak self] in
            _ = self?.historyStore.unreadCount
        } onChange: { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        notificationManager.setDockBadge(unreadCount: historyStore.unreadCount)
    }
}
