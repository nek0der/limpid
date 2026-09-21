// BackgroundAgentTabPlacement.swift
// Limpid — where an agent's tab sat when it was closed, so opening it again from the Background list puts it back.

import Foundation

/// The place a tab held in the list the user sees: which container, and
/// which position within it.
///
/// A position rather than a neighbouring tab's id: the neighbour may itself
/// be closed while the agent runs on in the background, and then there would
/// be nothing to anchor to. The index is read against the container's list
/// at the moment it is used, so a shorter list simply puts the tab at its
/// end.
struct BackgroundAgentTabPlacement: Equatable {
    let container: ContainerID
    /// Index within `container`'s tabs, counted as the tab column shows them.
    let index: Int
}

/// What Limpid remembers about the tabs of agents that keep running after
/// their tab is closed, so the Background list can open one where it was
/// (design D7).
///
/// Keyed by the agent's leaf, which is the one identifier that survives the
/// tab: the agent's records, badges, and its row in the Background list all
/// name that leaf, while the tab's own id dies with it.
///
/// Held here rather than on `WindowSession` because none of it is session
/// state: it is not restored, not persisted, and a record nobody claims is
/// only worth what the next reopen makes of it.
@MainActor
enum BackgroundAgentTabPlacements {
    private struct Record {
        let leafID: UUID
        let placement: BackgroundAgentTabPlacement
    }

    /// Oldest first. Bounded because a record is only spent when its agent
    /// is opened again, and an agent that never is would otherwise keep its
    /// record for as long as the app runs.
    private static var records: [Record] = []

    private static let limit = 64

    /// Remember where `tab` sat, if it is the tab of an agent that keeps
    /// running without it. Called from the close path, before the tab
    /// leaves the session.
    ///
    /// Other tabs are not recorded: a user's mirror and an ordinary terminal
    /// come back through ⌘⇧T, which restores the tab itself rather than
    /// opening a new one for an agent that outlived it.
    static func record(_ tab: Tab, in session: WindowSession) {
        guard tab.kind == .tmuxMirror, tab.mirrorOrigin == .agent else { return }
        guard let index = session.tabs(in: tab.container).firstIndex(where: { $0.id == tab.id }) else { return }
        let placement = BackgroundAgentTabPlacement(container: tab.container, index: index)
        for leafID in tab.splitTree.allLeafIDs() {
            records.removeAll { $0.leafID == leafID }
            records.append(Record(leafID: leafID, placement: placement))
        }
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
    }

    /// What was remembered for `leafID`, without spending it. For callers
    /// that want to decide where to open before the tab exists.
    static func placement(forLeaf leafID: UUID) -> BackgroundAgentTabPlacement? {
        records.last { $0.leafID == leafID }?.placement
    }

    /// Move the tab showing `leafID` back to where that agent's tab was when
    /// it closed, and spend the record.
    ///
    /// Call it once the tab exists; the caller does not have to know whether
    /// anything was remembered. Nothing happens when no record was kept, or
    /// when no tab shows the leaf. When the container it was closed in is
    /// gone the record is spent and the tab is left where it opened — the
    /// end of the active container (design D7).
    static func restore(forLeaf leafID: UUID, in session: WindowSession) {
        guard let recordIndex = records.lastIndex(where: { $0.leafID == leafID }) else { return }
        let placement = records.remove(at: recordIndex).placement
        guard let tab = session.tab(containing: leafID),
              session.containerExists(placement.container)
        else { return }
        // `moveTab` hands the selection to a neighbour when the tab it moves
        // is the active one, which is right for a drag out of the container
        // the user is looking at and wrong here: the user asked for this tab
        // a moment ago.
        let wasActive = session.activeTabID == tab.id
        session.moveTab(tab.id, to: placement.container)
        let siblings = session.tabs(in: placement.container).filter { $0.id != tab.id }
        if placement.index < siblings.count {
            session.reorderTab(tab.id, before: siblings[placement.index].id)
        } else {
            session.reorderTab(tab.id, before: nil)
        }
        if wasActive {
            session.setActiveTab(tab.id)
        }
    }
}
