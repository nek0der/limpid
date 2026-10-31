// NavActions.swift
// Weir — tab navigation verbs: ⇧⌘[ ⇧⌘] to cycle, ⌘1…⌘9 for the session's Nth tab.

import Foundation

@MainActor
enum NavActions {
    /// Activate the Nth tab of the window's active container. Used by
    /// ⌘1 … ⌘9 to map directly onto the tabs the user is looking at
    /// (rather than the global tab array, which would jump around
    /// containers unexpectedly).
    static func activateTabInActiveContainer(
        at index: Int,
        in session: WorkspaceSession,
        window: WindowID,
        intent: SelectionIntent
    ) {
        guard let selection = session.selection(window) else { return }
        let tabs = session.tabs(in: selection.activeContainerID)
        guard index >= 0, index < tabs.count else { return }
        session.setActiveTab(tabs[index].id, in: window, intent: intent)
    }

    /// ⇧⌘] / ⇧⌘[ — cycle within the window's active container, the tabs
    /// its strip or column shows; with no selection we just bail.
    static func cycleTab(_ session: WorkspaceSession, forward: Bool, in window: WindowID, intent: SelectionIntent) {
        guard let selection = session.selection(window) else { return }
        let visible = session.tabs(in: selection.activeContainerID)
        guard !visible.isEmpty else { return }
        let current = selection.activeTabID.flatMap { id in
            visible.firstIndex(where: { $0.id == id })
        } ?? 0
        let count = visible.count
        let next = forward
            ? (current + 1) % count
            : (current - 1 + count) % count
        session.setActiveTab(visible[next].id, in: window, intent: intent)
    }
}
