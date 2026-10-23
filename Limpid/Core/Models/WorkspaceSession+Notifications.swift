// WorkspaceSession+Notifications.swift
// Limpid — aggregate "unread / ringing" state up the hierarchy.
//
//   pane (PaneState) → tab → container → project → window
//
// Every UI layer reads from these helpers instead of touching
// PaneState directly, so the unread indicators on tabs, sidebar rows,
// and the dock badge stay consistent.

import Foundation

@MainActor
extension WorkspaceSession {
    /// `true` if any pane in this tab has an unread notification.
    func hasUnread(in tab: Tab) -> Bool {
        tab.paneStates.values.contains(where: \.hasUnread)
    }

    /// `true` if any pane in this tab is currently flashing its bell.
    /// Walks the tab's leaves against `paneTransients` because bell
    /// state now lives on the session, not on `Tab.paneStates`.
    func isRinging(in tab: Tab) -> Bool {
        for paneID in tab.splitTree.allLeafIDs() where paneTransients[paneID]?.isBellRinging == true {
            return true
        }
        return false
    }

    /// `true` if any tab in the given container has unread.
    func hasUnread(in container: ContainerID) -> Bool {
        tabs(in: container).contains(where: { hasUnread(in: $0) })
    }

    /// `true` if any pane inside the container is flashing right now.
    func isRinging(in container: ContainerID) -> Bool {
        tabs(in: container).contains(where: { isRinging(in: $0) })
    }

    /// Total unread count across the panes the tabs hold now. Worked out
    /// from the tabs rather than kept beside them: a count kept apart went
    /// stale whenever a tab or pane closed with its mark still on, and the
    /// Dock dot (`DockBadgeSync`) stayed lit for a pane that was gone.
    var windowUnreadCount: Int {
        tabs.reduce(0) { sum, tab in
            sum + tab.splitTree.allLeafIDs().reduce(0) { $0 + (tab.paneStates[$1]?.unreadCount ?? 0) }
        }
    }

    var windowHasUnread: Bool {
        windowUnreadCount > 0
    }
}
