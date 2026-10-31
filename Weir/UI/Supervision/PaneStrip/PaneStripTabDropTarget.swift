// PaneStripTabDropTarget.swift
// Weir — dropping a dragged tab before or after another in the pane strip, and a dragged pane into a tab.

import SwiftUI

/// What a tab of the pane strip does with what is dropped on it.
@MainActor
struct PaneStripTabDrop {
    let tabID: UUID
    let container: ContainerID
    let session: WorkspaceSession
    let window: WindowID

    /// The name the tab takes as a drop target (`reorderableDropTarget`).
    static func targetID(_ tabID: UUID) -> String {
        "tab-\(tabID)"
    }

    /// Whether the drop would change nothing, which hides the indicator: a
    /// pane already in this tab, a tab on itself, just before the next tab
    /// (its current place), or just after the previous tab (its current
    /// place). The strip runs across, so before and after are left and right.
    func isNoOp(_ sourceID: UUID, at position: DropPosition) -> Bool {
        if let paneTab = session.tab(containing: sourceID) {
            return paneTab.id == tabID
        }
        guard sourceID != tabID else { return true }
        // Cross-container drops always change something.
        guard let src = session.tab(sourceID),
              src.container == container
        else { return false }
        let tabs = session.tabs(in: container)
        guard let targetIdx = tabs.firstIndex(where: { $0.id == tabID }),
              let srcIdx = tabs.firstIndex(where: { $0.id == sourceID })
        else { return false }
        switch position {
        case .before:
            // Drop "before target" = no-op when source is the
            // immediate predecessor (or the target itself).
            return srcIdx == targetIdx - 1
        case .after:
            // Drop "after target" = no-op when source is the
            // immediate successor.
            return srcIdx == targetIdx + 1
        }
    }

    /// A pane joins the tab, shown in `window`; a tab lands beside it.
    func drop(prefix: String, _ sourceID: UUID, at position: DropPosition) {
        if prefix == DragPrefix.pane {
            TabActions.mergePaneIntoTab(session, paneID: sourceID, into: tabID, in: window, intent: .person)
            return
        }
        if let src = session.tab(sourceID),
           src.container != container
        {
            session.moveTab(sourceID, to: container)
        }
        switch position {
        case .before:
            session.reorderTab(sourceID, before: tabID)
        case .after:
            session.reorderTab(sourceID, after: tabID)
        }
    }
}

extension View {
    /// Treat this tab as where a dragged tab lands beside it and a dragged
    /// pane joins it (`PaneStripTabDrop`).
    func paneStripTabDropTarget(_ drop: PaneStripTabDrop) -> some View {
        reorderableDropTarget(
            targetID: PaneStripTabDrop.targetID(drop.tabID),
            acceptedPrefixes: [DragPrefix.tab, DragPrefix.pane],
            axis: .horizontal,
            isNoOp: { drop.isNoOp($0, at: $1) },
            onDrop: { prefix, sourceID, position in drop.drop(prefix: prefix, sourceID, at: position) }
        )
    }
}
