// PaneMergeMark.swift
// Limpid — the mark on a pane strip tab that a ⌥⌘-dragged pane would join.
//
// The strip takes no detach drop: its empty space is only the gaps between
// tabs, where a pane would leave its tab by accident. The pane's own "Move
// Pane to New Tab" does that.

import SwiftUI

extension WorkspaceSession {
    /// The tab of the pane being dragged, or `nil` while no pane drag is in
    /// flight. A tab list reads it once per drawing and hands it to each
    /// tab's mark, rather than each mark looking it up on every frame of the
    /// drag; that tab draws none.
    func tabOfDraggedPane(_ dragState: LimpidDragState) -> UUID? {
        guard dragState.current == .pane,
              let raw = dragState.currentSourceID,
              let paneID = UUID(uuidString: raw)
        else { return nil }
        return tab(containing: paneID)?.id
    }
}

extension View {
    /// Marks a pane strip tab while a ⌥⌘-dragged pane would join it. The
    /// drop itself goes through `paneStripTabDropTarget`, which is mounted
    /// before the drag starts: a drop destination that appeared only once
    /// the pane was picked up never heard of the drag.
    @MainActor
    func paneMergeMark(
        targetTabID: UUID,
        dragState: LimpidDragState,
        highlightNamespace: Namespace.ID,
        sourceTabID: UUID?
    ) -> some View {
        overlay {
            if dragState.current == .pane,
               sourceTabID != targetTabID,
               dragState.hoverTargetID == PaneStripTabDrop.targetID(targetTabID)
            {
                // Single accent rectangle slides between tabs via a shared
                // `matchedGeometryEffect` id, mirroring AppKit's drop
                // indicator glide. The tab's own shape, so the mark reads as
                // the tab rather than a box laid on it.
                SupervisionDropMark(shape: UnevenRoundedRectangle(
                    topLeadingRadius: LimpidLayout.Supervision.paneStripTabCornerRadius,
                    topTrailingRadius: LimpidLayout.Supervision.paneStripTabCornerRadius,
                    style: .circular
                ))
                .padding(.bottom, LimpidLayout.Supervision.paneStripRuleWidth)
                .matchedGeometryEffect(id: "pane-merge-highlight", in: highlightNamespace)
                .allowsHitTesting(false)
            }
        }
    }
}
