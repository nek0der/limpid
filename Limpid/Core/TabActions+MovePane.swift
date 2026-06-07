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
        if let s = sourceTab.paneStates[paneID] { newTab.paneStates[paneID] = s }
        if let s = sourceTab.claudeSessions[paneID] { newTab.claudeSessions[paneID] = s }
        if let s = sourceTab.codexSessions[paneID] { newTab.codexSessions[paneID] = s }
        if let s = sourceTab.claudeAgentBadges[paneID] { newTab.claudeAgentBadges[paneID] = s }
        if let s = sourceTab.codexAgentBadges[paneID] { newTab.codexAgentBadges[paneID] = s }
        if let s = sourceTab.scrollbackPaths[paneID] { newTab.scrollbackPaths[paneID] = s }
        if let s = sourceTab.initialCommands[paneID] { newTab.initialCommands[paneID] = s }

        session.update(sourceTab.id) { t in
            let result = t.splitTree.remove(paneID)
            t.splitTree = result.tree
            if t.zoomedLeafID == paneID { t.zoomedLeafID = nil }
            t.paneStates.removeValue(forKey: paneID)
            t.claudeSessions.removeValue(forKey: paneID)
            t.codexSessions.removeValue(forKey: paneID)
            t.claudeAgentBadges.removeValue(forKey: paneID)
            t.codexAgentBadges.removeValue(forKey: paneID)
            t.scrollbackPaths.removeValue(forKey: paneID)
            t.initialCommands.removeValue(forKey: paneID)
        }

        session.tabs.append(newTab)
        session.setActiveTab(newTab.id)
    }
}
