// ClosedTab.swift
// Limpid — frozen snapshot of a tab the user just closed, used by
// ⌘⇧T (Reopen Closed Tab). The shell process is already dead by the
// time we keep one of these, so reopen can't revive it; what we
// CAN do is rebuild the same split layout pointed at the same cwd
// and replay each pane's last scrollback above the fresh shells.
//
// Carries the full `Tab` snapshot (splitTree, scrollbackPaths,
// paneStates, zoomedLeafID, initialCommands) so reopen feeds the
// existing session-restore machinery — same path ⌘Q uses on launch.
//
// Transient — pushed in `SessionActions.closeTab`, popped in
// `reopenClosedTab`. Not persisted across launches.

import Foundation

struct ClosedTab: Equatable {
    let tab: Tab
    let closedAt: Date
}
