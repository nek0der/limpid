// TabActions+MoveToRow.swift
// Weir — a tab or pane moved to a sidebar row of any project: which rows take it, and the move.

import Foundation
import WeirDomain

@MainActor
extension TabActions {
    /// Whether `container`'s row can take work: it still exists, and its
    /// worktree is on disk. A moved tab's new panes start in the row's folder
    /// (`WorkspaceSession.moveTab`), and a missing worktree has none.
    private static func canTakeWork(_ container: ContainerID, in session: WorkspaceSession) -> Bool {
        switch container {
        case .loose:
            true
        case let .project(projectID):
            session.project(projectID) != nil
        case let .worktree(projectID, worktreeID):
            session.worktree(projectID: projectID, worktreeID: worktreeID)?.isMissing == false
        }
    }

    /// Whether dropping `work` on `container`'s row would move it. A pane
    /// with others beside it still has somewhere to go in its own row: a
    /// tab of its own.
    static func wouldMove(_ work: CarriedWork, to container: ContainerID, in session: WorkspaceSession) -> Bool {
        guard canTakeWork(container, in: session) else { return false }
        switch work {
        case let .tab(tabID):
            guard let tab = session.tab(tabID) else { return false }
            return tab.container != container
        case let .pane(paneID):
            guard let tab = session.tab(containing: paneID) else { return false }
            return tab.container != container || tab.splitTree.allLeafIDs().count > 1
        }
    }

    /// Moves `work` to `container`'s row. Every window stays where it is
    /// (`moveTab`). False when it is not there afterward: the row went while
    /// the drag was held, after it last said it would take the drop. A pane
    /// goes in a tab of its own, and one alone in its tab takes the tab with
    /// it. The row is checked before the split, so a refused pane stays
    /// beside the others.
    @discardableResult
    static func move(_ work: CarriedWork, to container: ContainerID, in session: WorkspaceSession) -> Bool {
        guard canTakeWork(container, in: session) else { return false }
        let tabID: UUID
        switch work {
        case let .tab(id):
            tabID = id
        case let .pane(paneID):
            guard let source = session.tab(containing: paneID) else { return false }
            // Selecting nothing: the window stays on the tab the pane left.
            tabID = splitPaneOff(session, paneID: paneID) ?? source.id
        }
        session.moveTab(tabID, to: container)
        guard session.tab(tabID)?.container == container else { return false }
        // The person put work there: one of the other worktrees becomes
        // theirs, and stays a working row once the tab closes.
        session.admitWorktree(container, intent: .person)
        return true
    }
}
