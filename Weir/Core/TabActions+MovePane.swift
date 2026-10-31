// TabActions+MovePane.swift
// Weir — promotes a pane out of its split tree into a fresh sibling
// tab. Kept out of `TabActions.swift` so the main enum body stays under
// the SwiftLint `type_body_length` error threshold.

import Foundation
import WeirDomain

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
    /// Returns the new tab, `nil` when it made none.
    @discardableResult
    static func movePaneToNewTab(
        _ session: WorkspaceSession,
        paneID: UUID,
        in window: WindowID,
        intent: SelectionIntent
    ) -> UUID? {
        guard let newTabID = splitPaneOff(session, paneID: paneID) else { return nil }
        session.setActiveTab(newTabID, in: window, intent: intent)
        return newTabID
    }

    /// The move itself, selecting nothing: a pane dropped on a sidebar row
    /// leaves every window where it was. Returns the new tab, `nil` when
    /// the pane is alone in its tab.
    @discardableResult
    static func splitPaneOff(_ session: WorkspaceSession, paneID: UUID) -> UUID? {
        guard let sourceTab = session.tab(containing: paneID) else { return nil }
        guard sourceTab.splitTree.allLeafIDs().count > 1 else { return nil }

        // A pane the user named carries that name to its new tab, pinned
        // the way a tab rename pins one: the source tab's title belongs to
        // whatever the source was showing, and an unpinned title would be
        // replaced by the moved shell's next OSC 2 within a prompt. An
        // unnamed pane keeps the copied title, as before.
        let paneName = sourceTab.paneStates[paneID]?.name
        var newTab = Tab(
            title: paneName ?? sourceTab.title,
            titleOverride: paneName,
            workingDirectory: sourceTab.workingDirectory,
            pwd: sourceTab.pwd,
            splitTree: SplitTree(leafID: paneID),
            container: sourceTab.container
        )
        // The name prefix, color, and folder default a scratch tab kept
        // from its group stay with that tab: the new tab is the moved
        // pane's own, not the group's.
        // Carry per-pane state across so the new tab is byte-identical
        // for the moved leaf — agent badges, unread, replay payloads.
        newTab.apply(sourceTab.paneTransferState(of: paneID), to: paneID)

        session.update(sourceTab.id) { t in
            // The conversation that names the tab goes with its pane.
            newTab.receiveConversationName(t.takeConversationName(of: paneID))
            let result = t.splitTree.remove(paneID)
            t.splitTree = result.tree
            if t.zoomedLeafID == paneID {
                t.zoomedLeafID = nil
            }
            t.removePaneTransferState(of: paneID)
        }

        session.tabs.append(newTab)
        return newTab.id
    }
}
