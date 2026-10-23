// PaneTabDropTargets.swift
// Limpid — the drop target on a pane strip tab that merges a ⌥⌘-dragged pane into that tab.
//
// The strip takes no detach drop: its empty space is only the gaps between
// tabs, where a pane would leave its tab by accident. The pane's own "Move
// Pane to New Tab" does that.

import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let paneDropLog = Logger.limpid("pane.drop")

extension WorkspaceSession {
    /// The tab of the pane being dragged, or `nil` while no pane drag is in
    /// flight. A tab list reads it once per drawing and hands it to each
    /// tab's merge target, rather than each target looking it up on every
    /// frame of the drag; that tab refuses the drop instead of showing the
    /// green "+" copy badge.
    func tabOfDraggedPane(_ dragState: LimpidDragState) -> UUID? {
        guard dragState.current == .pane,
              let raw = dragState.currentSourceID,
              let paneID = UUID(uuidString: raw)
        else { return nil }
        return tab(containing: paneID)?.id
    }
}

extension View {
    /// Attach to a pane strip tab so dropping a ⌥⌘-dragged pane on it
    /// merges the pane into that tab.
    ///
    /// The drop catcher only renders while a pane drag is in flight, so
    /// the tab's existing `.tabReorderTarget` modifier (the legacy
    /// `onDrop(of:delegate:)` route used for tab reorder) still owns the
    /// drop area for tab drags — without that gate, SwiftUI's
    /// `.dropDestination` and the older `onDrop` modifier competed for
    /// drops on the same view and pane drops silently no-op'd. Paired
    /// with `UnifiedReorderDelegate.validateDrop` returning `false` for
    /// `.pane` drags, so the inner reorder modifier never consumes the
    /// drop even if SwiftUI's dispatch order ever changes.
    @MainActor
    func paneMergeDropTarget(
        targetTabID: UUID,
        session: WorkspaceSession,
        dragState: LimpidDragState,
        highlightNamespace: Namespace.ID,
        sourceTabID: UUID?
    ) -> some View {
        overlay {
            if dragState.current == .pane {
                let isSourceRow = sourceTabID == targetTabID
                if isSourceRow {
                    // Cursor over the tab the pane came from: refuse
                    // the drop via a delegate that returns
                    // `.forbidden`, so the cursor loses the green `+`
                    // (and no accent tint is painted). The merge would
                    // be a no-op anyway: `TabActions.mergePaneIntoTab`
                    // guards source == target.
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.text], delegate: ForbidPaneDropDelegate())
                } else {
                    PaneMergeDropArea(
                        targetTabID: targetTabID,
                        session: session,
                        dragState: dragState,
                        highlightNamespace: highlightNamespace
                    )
                }
            }
        }
    }

    /// The `.dropDestination(for: String.self)` body of the merge target:
    /// the hover-state bookkeeping and the `paneIDFromWire` parse.
    @MainActor
    fileprivate func paneStringDropCatcher(
        key: String,
        dragState: LimpidDragState,
        perform: @escaping (UUID) -> Void
    ) -> some View {
        dropDestination(for: String.self) { strings, _ in
            for wire in strings {
                if let paneID = paneIDFromWire(wire) {
                    perform(paneID)
                    return true
                }
            }
            return false
        } isTargeted: { hovering in
            if hovering, dragState.current == .pane {
                dragState.hoverTargetID = key
            } else if dragState.hoverTargetID == key {
                dragState.hoverTargetID = nil
            }
        }
    }
}

/// Parse a `pane:<UUID>` wire payload back into a leaf id. Returns nil
/// for any other prefix (tab/project/worktree) so the same drop
/// target can silently ignore a stray sidebar drag that ends up on it —
/// `paneStringDropCatcher`'s `isTargeted` already filters by
/// `dragState.current == .pane`, this is a defense in depth against a
/// malformed pasteboard payload that slips through anyway.
private func paneIDFromWire(_ wire: String) -> UUID? {
    let prefix = "pane:"
    guard wire.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(wire.dropFirst(prefix.count)))
}

/// Hover-marked merge zone painted on every non-source tab while
/// a pane drag is in flight. Lifted out of the `paneMergeDropTarget`
/// modifier so it can read the window from the environment — the
/// modifier itself runs inside an `extension View` and so can't pull
/// environment values directly.
@MainActor
private struct PaneMergeDropArea: View {
    let targetTabID: UUID
    let session: WorkspaceSession
    let dragState: LimpidDragState
    let highlightNamespace: Namespace.ID
    /// The window the drop lands in, which shows the tab the pane joins.
    @Environment(ProjectWindowState.self) private var window

    private var key: String {
        "pane-merge-\(targetTabID)"
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .paneStringDropCatcher(
                    key: key,
                    dragState: dragState
                ) { paneID in
                    paneDropLog.debug(
                        "merge target=\(targetTabID.uuidString, privacy: .public) pane=\(paneID.uuidString, privacy: .public)"
                    )
                    TabActions.mergePaneIntoTab(session, paneID: paneID, into: targetTabID, in: window.id, intent: .person)
                }
            // Single accent rectangle slides between tabs via a shared
            // `matchedGeometryEffect` id, mirroring AppKit's drop
            // indicator glide.
            if dragState.hoverTargetID == key {
                highlight
                    .matchedGeometryEffect(
                        id: "pane-merge-highlight",
                        in: highlightNamespace
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    /// The tab's own shape, so the mark reads as the tab rather than a box
    /// laid on it: the folder tab's top corners, down to the strip's rule,
    /// as a tab's hover fill is.
    private var highlight: some View {
        let layout = LimpidLayout.Supervision.self
        return SupervisionDropMark(shape: UnevenRoundedRectangle(
            topLeadingRadius: layout.paneStripTabCornerRadius,
            topTrailingRadius: layout.paneStripTabCornerRadius,
            style: .circular
        ))
        .padding(.bottom, layout.paneStripRuleWidth)
    }
}

/// Refuses every drop with `.forbidden`. Mounted only on the source
/// pane's own tab so dragging back onto it shows the macOS "no
/// drop" cursor instead of the green-plus `Copy` badge that
/// `.dropDestination` defaults to.
@MainActor
private struct ForbidPaneDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        false
    }
}
