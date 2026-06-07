// NavActions.swift
// Limpid — tab + container navigation verbs (⌘[/⌘] for cycle, ⌘1…⌘9
// for the active container's Nth tab, ⌘⌃1…⌘⌃9 for the Nth top-level
// container). Second slice from the `TabActions` namespace split; see
// `SearchActions` for the pattern.

import Foundation

@MainActor
enum NavActions {
    /// Activate the Nth tab inside the container-column-selected
    /// container. Used by ⌘1 … ⌘9 to map directly onto the tab column
    /// the user is looking at (rather than the global tab array,
    /// which would jump around containers unexpectedly).
    static func activateTabInActiveContainer(at index: Int, in session: WindowSession) {
        let tabs = session.tabs(in: session.activeContainerID)
        guard index >= 0, index < tabs.count else { return }
        session.setActiveTab(tabs[index].id)
    }

    /// ⌘] / ⌘[ — cycle within the currently-selected container.
    /// Matches the tab column list scope; if the container column
    /// selection is empty we just bail.
    static func cycleTab(_ session: WindowSession, forward: Bool) {
        let visible = session.tabs(in: session.activeContainerID)
        guard !visible.isEmpty else { return }
        let current = session.activeTabID.flatMap { id in
            visible.firstIndex(where: { $0.id == id })
        } ?? 0
        let count = visible.count
        let next = forward
            ? (current + 1) % count
            : (current - 1 + count) % count
        session.setActiveTab(visible[next].id)
    }

    /// ⌘⌥] / ⌘⌥[ — cycle the top-level container selection.
    static func cycleContainer(_ session: WindowSession, forward: Bool) {
        session.cycleTopLevelContainer(forward: forward)
    }

    /// ⌘⌃1…⌘⌃9 — activate the Nth top-level container.
    static func activateContainer(at index: Int, in session: WindowSession) {
        session.activateTopLevelContainer(at: index)
    }
}
