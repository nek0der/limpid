// WindowSession+Notifications.swift
// Limpid — aggregate "unread / ringing" state up the hierarchy.
//
//   pane (PaneState) → tab → container → project → window
//
// Every UI layer reads from these helpers instead of touching
// PaneState directly, so the bell indicators on L2 TabRow, L1
// ContainerRow, the chrome bell button, and the dock badge stay
// consistent.

import Foundation

@MainActor
extension WindowSession {
    /// `true` if any pane in this tab has an unread notification.
    func hasUnread(in tab: Tab) -> Bool {
        tab.paneStates.values.contains(where: \.hasUnread)
    }

    /// `true` if any pane in this tab is currently flashing its bell.
    /// Walks the tab's leaves against `paneTransients` because bell
    /// state now lives on the session, not on `Tab.paneStates`.
    func isRinging(in tab: Tab) -> Bool {
        for paneID in tab.splitTree.allLeafIDs() {
            if paneTransients[paneID]?.isBellRinging == true { return true }
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

    /// Aggregate of project-direct + every worktree inside the project.
    /// Used by Project headers in L1, including when collapsed.
    func hasUnreadInProject(_ projectID: UUID) -> Bool {
        tabs.contains { tab in
            tab.container.projectID == projectID && hasUnread(in: tab)
        }
    }

    func isRingingInProject(_ projectID: UUID) -> Bool {
        tabs.contains { tab in
            tab.container.projectID == projectID && isRinging(in: tab)
        }
    }

    /// Total unread count across every pane in every tab. Drives the
    /// numeric badge on the chrome bell button. Reads the cache
    /// directly so observers (DockBadgeSync, chrome) only re-evaluate
    /// when the scalar itself changes — unrelated `tabs` edits don't
    /// fan out.
    var windowUnreadCount: Int {
        cachedWindowUnreadCount
    }

    var windowHasUnread: Bool {
        windowUnreadCount > 0
    }

    var windowIsRinging: Bool {
        tabs.contains(where: { isRinging(in: $0) })
    }
}
