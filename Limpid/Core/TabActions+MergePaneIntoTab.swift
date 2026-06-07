// TabActions+MergePaneIntoTab.swift
// Limpid — merges a pane that's being dragged in tab column into the tab whose
// row it was dropped on. Symmetric with `movePaneToNewTab`: the same
// leaf id flows through, so libghostty keeps the surface and its PTY.

import Foundation

@MainActor
extension TabActions {
    /// Move `paneID` out of its current tab and into `targetTabID` as a
    /// new horizontal split appended at the rightmost leaf. The leaf id
    /// is preserved, so `SurfaceRegistry` carries the existing
    /// `SurfaceView` and libghostty surface along — the pane just
    /// "follows" the leaf to its new home, like `movePaneToNewTab` does.
    ///
    /// Per-pane state (claude/codex sessions + badges, paneStates,
    /// scrollback paths, initial commands) migrates with it.
    ///
    /// No-op when source and target are the same tab (would only churn
    /// the tree), the target tab can't be found, or the target's split
    /// tree has no leaf to pivot off.
    ///
    /// Single-pane source is fine: the moved leaf leaves an empty source
    /// tab behind, which we close at the end of the routine. That folds
    /// "drag the only pane of tab A onto tab B" into "consume tab A by
    /// merging its pane into tab B" — the user's intent when they pick
    /// up the pane rather than the tab.
    static func mergePaneIntoTab(
        _ session: WindowSession,
        paneID: UUID,
        into targetTabID: UUID
    ) {
        guard let sourceTab = session.tab(containing: paneID),
              let targetTab = session.tab(targetTabID),
              sourceTab.id != targetTabID
        else { return }
        guard let pivot = targetTab.splitTree.allLeafIDs().last else { return }

        // Capture per-pane state from source before any mutation so the
        // two update() calls see consistent dictionaries. Only Tab-level
        // dictionaries need explicit migration here; `paneSearchStates`
        // and `paneTransients` live on `WindowSession` (keyed by pane
        // id, not nested under Tab), so they follow the leaf id
        // automatically and need no copy / clear step.
        let paneState = sourceTab.paneStates[paneID]
        let claudeSession = sourceTab.claudeSessions[paneID]
        let codexSession = sourceTab.codexSessions[paneID]
        let claudeBadge = sourceTab.claudeAgentBadges[paneID]
        let codexBadge = sourceTab.codexAgentBadges[paneID]
        let scrollbackPath = sourceTab.scrollbackPaths[paneID]
        let initialCommand = sourceTab.initialCommands[paneID]

        // Attach the leaf to target with the SAME paneID so the
        // SurfaceView in SurfaceRegistry keeps mapping cleanly. We
        // append at the rightmost leaf via `.horizontal` so the dropped
        // pane appears on the right — predictable, matches "Split Right".
        session.update(targetTabID) { t in
            let result = t.splitTree.insert(at: pivot, direction: .horizontal, newID: paneID)
            t.splitTree = result.tree
            t.splitTree.focusedLeafID = paneID
            if let s = paneState { t.paneStates[paneID] = s }
            if let s = claudeSession { t.claudeSessions[paneID] = s }
            if let s = codexSession { t.codexSessions[paneID] = s }
            if let s = claudeBadge { t.claudeAgentBadges[paneID] = s }
            if let s = codexBadge { t.codexAgentBadges[paneID] = s }
            if let s = scrollbackPath { t.scrollbackPaths[paneID] = s }
            if let s = initialCommand { t.initialCommands[paneID] = s }
        }

        // Drop the pane from the source tab. zoom is per-tab so clear
        // it if the moved pane was the zoomed one.
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

        // If the source tab held only the moved pane, it's empty now —
        // close it so it doesn't linger as a phantom row in tab column. We
        // bypass `TabActions.closeTab`'s scrollback snapshot + closed-
        // tab stack on purpose: the pane is alive in the target tab,
        // it just changed homes, so recording a "closed tab" would
        // make ⌘⇧T re-mint a duplicate ghost.
        if let refreshed = session.tab(sourceTab.id), refreshed.splitTree.isEmpty {
            session.closeTab(sourceTab.id)
        }

        session.setActiveTab(targetTabID)
    }
}
