// TabActions+MovePane.swift
// Limpid — promotes a pane out of its split tree into a fresh sibling
// tab. Kept out of `TabActions.swift` so the main enum body stays under
// the SwiftLint `type_body_length` error threshold.

import Foundation

@MainActor
extension TabActions {
    /// Promote `paneID` out of its split tree and into a freshly-created
    /// sibling tab. Same leaf id is reused, so `SurfaceRegistry` keeps
    /// the existing `SurfaceView` and libghostty surface alive — the
    /// pane just "follows" the leaf to its new home. Per-pane state
    /// (claude/codex sessions + badges, paneStates, scrollback paths,
    /// initial commands) migrates with it.
    ///
    /// No-op when the owning tab has a single leaf: there's nothing to
    /// "split off", and creating an empty source tab would surprise the
    /// user. The right-click menu hides the item in that case via
    /// `canMoveToNewTab`; the guard here covers programmatic callers.
    static func movePaneToNewTab(_ session: WindowSession, paneID: UUID) {
        guard let sourceTab = session.tab(containing: paneID) else { return }
        guard sourceTab.splitTree.allLeafIDs().count > 1 else { return }

        var newTab = Tab(
            title: sourceTab.title,
            workingDirectory: sourceTab.workingDirectory,
            pwd: sourceTab.pwd,
            splitTree: SplitTree(leafID: paneID),
            container: sourceTab.container
        )
        // Carry per-pane state across so the new tab is byte-identical
        // for the moved leaf — agent badges, unread, replay payloads.
        if let s = sourceTab.paneStates[paneID] {
            newTab.paneStates[paneID] = s
        }
        for (provider, sessions) in sourceTab.agentSessions {
            if let hint = sessions[paneID] {
                newTab.agentSessions[provider, default: [:]][paneID] = hint
            }
        }
        if let s = sourceTab.tmuxBindings[paneID] {
            newTab.tmuxBindings[paneID] = s
        }
        for (provider, badges) in sourceTab.agentBadges {
            if let badge = badges[paneID] {
                newTab.agentBadges[provider, default: [:]][paneID] = badge
            }
        }
        if let s = sourceTab.scrollbackPaths[paneID] {
            newTab.scrollbackPaths[paneID] = s
        }
        if let s = sourceTab.initialCommands[paneID] {
            newTab.initialCommands[paneID] = s
        }

        // The pane lives on in the new tab, so only the source forgets it;
        // the session state and the unread count travel with the leaf id.
        session.update(sourceTab.id) { $0.removeLeaf(paneID) }

        session.tabs.append(newTab)
        session.setActiveTab(newTab.id)
    }
}
