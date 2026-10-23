// DockBadgeSync.swift
// Limpid — keeps the Dock icon's badge in sync with the attention count.
// Same pattern as `WindowTitleSync` / `WindowFrameSync`: observe the
// sources and push the derived value out.
//
// The Dock shows the number every "Needs attention n" shows, so it
// counts what the attention list counts and nothing else. Command
// notifications and the bell are not attention items; when nothing needs
// attention and one of them waits, the Dock shows a dot instead of a
// number (`DockBadge`).

import Foundation

@MainActor
final class DockBadgeSync {
    private let historyStore: NotificationHistoryStore
    private let session: WorkspaceSession
    /// The attention list's count. A closure because the list lives above
    /// Core; the app layer passes it in.
    private let attentionCount: @MainActor () -> Int
    /// Where the badge goes: the Dock tile in the app, a recorder in tests.
    private let setBadge: @MainActor (DockBadge) -> Void

    init(
        historyStore: NotificationHistoryStore,
        session: WorkspaceSession,
        attentionCount: @escaping @MainActor () -> Int,
        setBadge: @escaping @MainActor (DockBadge) -> Void
    ) {
        self.historyStore = historyStore
        self.session = session
        self.attentionCount = attentionCount
        self.setBadge = setBadge
        // Defer the initial refresh — `NSApp.dockTile` isn't safe to
        // touch until the run loop has come up. `[weak self]` mirrors
        // the surrounding `observeRepeatedly` blocks so the file
        // pattern stays uniform.
        Task { @MainActor [weak self] in
            self?.refresh()
        }
        observeRepeatedly { [weak self] in
            _ = self?.badge
        } onChange: { [weak self] in
            self?.refresh()
        }
    }

    var badge: DockBadge {
        DockBadge.badge(
            attentionCount: attentionCount(),
            // A pane's unread mark (the tab's dot) covers a bell and
            // a command notification until the pane is looked at; the
            // history covers the notifications not yet read there.
            hasOtherNews: historyStore.hasUnreadCommandEntries || session.windowUnreadCount > 0
        )
    }

    private func refresh() {
        setBadge(badge)
    }
}
