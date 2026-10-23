// TabReorderTarget.swift
// Limpid — dropping a dragged tab before or after another in the pane strip.

import SwiftUI

extension View {
    /// Treat this tab as a reorder target. The `isNoOp` closure
    /// hides the indicator for "drop where you already are" cases —
    /// dropping a tab on itself, just before the next tab (its current
    /// place), or just after the previous tab (its current place).
    /// The strip runs across, so before and after are left and right.
    func tabReorderTarget(
        beforeTabID: UUID,
        container: ContainerID,
        session: WorkspaceSession
    ) -> some View {
        reorderableDropTarget(
            targetID: "tab-\(beforeTabID)",
            acceptedPrefixes: ["tab:"],
            axis: .horizontal,
            isNoOp: { sourceID, position in
                guard sourceID != beforeTabID else { return true }
                // Cross-container drops always change something.
                guard let src = session.tab(sourceID),
                      src.container == container
                else { return false }
                let tabs = session.tabs(in: container)
                guard let targetIdx = tabs.firstIndex(where: { $0.id == beforeTabID }),
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
            },
            onDrop: { _, sourceID, position in
                if let src = session.tab(sourceID),
                   src.container != container
                {
                    session.moveTab(sourceID, to: container)
                }
                switch position {
                case .before:
                    session.reorderTab(sourceID, before: beforeTabID)
                case .after:
                    session.reorderTab(sourceID, after: beforeTabID)
                }
            }
        )
    }
}
