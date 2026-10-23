// ReorderableDropTarget.swift
// Limpid — the drop modifier for live reordering, for a tab dropped on a sidebar row, and for a header dropped at a line.
//
// Three interaction modes:
//   * live reorder — for in-list reorder (tabs, a project's worktree
//     rows). As the cursor crosses a neighbor, `onDrop` fires
//     immediately so the rows physically slide into their new positions
//     (Finder / Notes / Reminders semantics). No insertion line is
//     drawn — the rows themselves are the indicator.
//   * assignment — a sidebar row receiving a tab from another
//     container. The row takes the drop mark (`SupervisionRowDropMark`)
//     since the drop just moves the tab into the container; there's no
//     positional semantics, so we wait for the actual `performDrop` to
//     commit.
//   * line — a project's header in the sidebar. A line is drawn where the
//     header would land, before or after the one under the pointer, and
//     nothing moves until the drop: a project carries its rows with it,
//     and moving whole projects under the pointer would carry the target
//     away with them.
//
// Live reorder mutates the model mid-drag. We snapshot the order
// arrays on the first mutation and roll back if the drag ends outside
// a valid drop target (e.g. user releases over an empty area). The
// snapshot lives on `LimpidDragState` so the mouse-up monitor can
// trigger the restore regardless of how SwiftUI terminates the drag.

import SwiftUI
import UniformTypeIdentifiers

typealias ReorderableDropPosition = DropPosition

enum DropPosition {
    case before
    case after
}

extension View {
    /// `targetID` MUST be unique across all drop targets in the
    /// window. `tabAsContainerAssignment`: when `true`, a tab payload
    /// takes the row's drop mark and moves only on the drop. Project and
    /// worktree payloads reorder live, or at a line when `dropsAtLine` is
    /// set.
    /// `isNoOp`: caller-provided predicate that returns `true` when
    /// dropping the given source at the given position wouldn't
    /// actually move it (e.g. drop right where it already is).
    /// Used to hide the indicator for those cases. Sources matching
    /// the target itself are always treated as no-op. `dropsAtLine`: the
    /// line mode, which draws where the source would land and moves it
    /// only on the drop.
    func reorderableDropTarget(
        targetID: String,
        acceptedPrefixes: Set<String>,
        axis: Axis = .vertical,
        tabAsContainerAssignment: Bool = false,
        dropsAtLine: Bool = false,
        isNoOp: ((UUID, DropPosition) -> Bool)? = nil,
        onDrop: @escaping (String, UUID, DropPosition) -> Void
    ) -> some View {
        modifier(ReorderableDropTarget(
            targetID: targetID,
            acceptedPrefixes: acceptedPrefixes,
            axis: axis,
            tabAsContainerAssignment: tabAsContainerAssignment,
            dropsAtLine: dropsAtLine,
            isNoOp: isNoOp,
            onDrop: onDrop
        ))
    }
}

private struct ReorderableDropTarget: ViewModifier {
    @Environment(LimpidDragState.self) private var dragState
    @Environment(WorkspaceSession.self) private var session
    let targetID: String
    let acceptedPrefixes: Set<String>
    let axis: Axis
    let tabAsContainerAssignment: Bool
    let dropsAtLine: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let onDrop: (String, UUID, DropPosition) -> Void
    @Environment(\.limpidAccent) private var accent

    /// Length of the row along `axis` — height for a vertical list,
    /// width for a horizontal strip. The delegate splits this at its
    /// midpoint to decide before / after.
    @State private var rowExtent: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { rowExtent = extent(of: geo.size) }
                        .onChange(of: extent(of: geo.size)) { _, new in rowExtent = new }
                }
            )
            // The sidebar rows mark a tab's drop as every drop target
            // there is marked, in the row's own shape. The in-list reorder
            // case draws no mark because the rows themselves animate into
            // their new slot.
            .modifier(SupervisionRowDropMark(
                isTargeted: shouldShowBackgroundHighlight,
                cornerRadius: LimpidLayout.Supervision.sessionRowCornerRadius
            ))
            // The line mode's mark: where the source would land, on the
            // edge it would land at, over the gap rather than in it.
            .overlay(alignment: dragState.hoverPosition == .after ? .bottom : .top) {
                if dropsAtLine, isHoveredHere, dragState.current != .tab {
                    Capsule()
                        .fill(accent)
                        .frame(height: LimpidLayout.Supervision.sidebarDropLineHeight)
                        .padding(.horizontal, LimpidLayout.Supervision.sessionRowHorizontalInset)
                        .alignmentGuide(.top) { $0.height / 2 }
                        .alignmentGuide(.bottom) { $0.height / 2 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [.text], delegate: UnifiedReorderDelegate(
                targetID: targetID,
                acceptedPrefixes: acceptedPrefixes,
                axis: axis,
                tabAsContainerAssignment: tabAsContainerAssignment,
                dropsAtLine: dropsAtLine,
                isNoOp: isNoOp,
                dragState: dragState,
                session: session,
                extentProvider: { rowExtent },
                onDrop: onDrop
            ))
    }

    private func extent(of size: CGSize) -> CGFloat {
        axis == .vertical ? size.height : size.width
    }

    private var isHoveredHere: Bool {
        dragState.hoverTargetID == targetID
            && acceptsCurrentDrag
            && !wouldBeNoOp
    }

    /// Suppress the whole-row tint for tab → same-container drags
    /// (the obvious "drop where you already are" case). Mirrors the
    /// pre-live-reorder behavior for the cross-container assignment
    /// path; the live reorder path doesn't paint a highlight at all.
    private var wouldBeNoOp: Bool {
        dropWouldBeNoOp(dragState: dragState, isNoOp: isNoOp, position: dragState.hoverPosition)
    }

    private var shouldShowBackgroundHighlight: Bool {
        isHoveredHere && tabAsContainerAssignment && dragState.current == .tab
    }

    private var acceptsCurrentDrag: Bool {
        guard let current = dragState.current else { return true }
        switch current {
        case .tab: return acceptedPrefixes.contains("tab:")
        case .project: return acceptedPrefixes.contains("project:")
        case .worktree: return acceptedPrefixes.contains("worktree:")
        // A pane dropped on a pane strip tab goes through that tab's merge
        // target (`paneMergeDropTarget`), not the reorder pipeline — never
        // accept here.
        case .pane: return false
        }
    }
}

private struct UnifiedReorderDelegate: DropDelegate {
    let targetID: String
    let acceptedPrefixes: Set<String>
    let axis: Axis
    let tabAsContainerAssignment: Bool
    let dropsAtLine: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let dragState: LimpidDragState
    let session: WorkspaceSession
    let extentProvider: () -> CGFloat
    let onDrop: (String, UUID, DropPosition) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        // Pane drops route through `paneMergeDropTarget`, not the
        // reorder pipeline.
        // Refuse here so SwiftUI lets the drop bubble up to whichever
        // outer drop modifier the tab / list happens to layer for
        // panes. Without this, a pane dropped on a tab row would be
        // consumed by `performDrop` below — which then no-ops, because
        // the UUID isn't a tab/project/worktree — and the user
        // sees the drag "vanish" with no merge.
        if dragState.current == .pane {
            return false
        }
        // A target that takes no tab refuses one outright (another
        // project's row), rather than badge it as a copy and drop it
        // on nothing.
        if dragState.current == .tab, !acceptedPrefixes.contains("tab:") {
            return false
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        // In-list reorder keeps `.move` (no badge) — the rows slide into
        // place and a badge would read as "duplicate". So does the line
        // mode, which moves the source too.
        guard isCrossContainerTabAssignment else {
            return DropProposal(operation: .move)
        }
        // A tab landing on a *different* container shows the green `+`
        // copy badge, matching the ⌥⌘ pane-drag affordance (pane drops
        // run through `.dropDestination`, which defaults to `.copy`).
        // When the tab already lives in this container the drop is a
        // no-op, so refuse it with `.forbidden` — same as a pane dragged
        // back over its own source row. This also matches the tint,
        // which `isHoveredHere` already gates on `!wouldBeNoOp`.
        // The delegate has no live `hoverPosition` to read, so resolve
        // the position straight from `DropInfo`.
        if dropWouldBeNoOp(dragState: dragState, isNoOp: isNoOp, position: computePosition(info)) {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if dragState.hoverTargetID == targetID {
            withAnimation(LimpidMotion.dropIndicator) {
                dragState.hoverTargetID = nil
                dragState.hoverPosition = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let position = computePosition(info)
        guard let provider = info.itemProviders(for: [.text]).first else {
            // No payload — fall through to the mouse-up monitor's
            // restore path (snapshot survives).
            dragState.end()
            return false
        }
        // Same-list reorder is already committed by `applyLiveReorder`
        // during the drag. Re-running `onDrop` here would re-resolve the
        // target relative to the *moved* rows — and the dragged row has
        // slid under the cursor, so `onDrop` lands on the source's own
        // target (`reorderTab(src, before/after: src)`), corrupting the
        // order. Only cross-container assignment still needs `performDrop`
        // to commit, since `update` deliberately deferred its mutation.
        let needsCommitOnDrop = isCommittedOnDrop
        // Discard the snapshot before `end()` so the live mutations stick.
        dragState.commitLiveReorder()
        dragState.end()
        guard needsCommitOnDrop else { return true }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let raw = item as? String else { return }
            for prefix in acceptedPrefixes {
                if raw.hasPrefix(prefix),
                   let id = UUID(uuidString: String(raw.dropFirst(prefix.count)))
                {
                    Task { @MainActor in
                        // Animate this last leg so the tab/terminal column transition
                        // matches the live animation curve.
                        withAnimation(LimpidMotion.reorderUnlessReduced) {
                            onDrop(prefix, id, position)
                        }
                    }
                    return
                }
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        // If the global drag has already ended (mouse-up monitor
        // fired) ignore any straggler dropUpdated / dropEntered
        // callbacks — otherwise the indicator briefly reappears
        // *after* the drop completes.
        guard dragState.current != nil else { return }
        let next = computePosition(info)
        let positionChanged = dragState.hoverTargetID != targetID
            || dragState.hoverPosition != next
        if positionChanged {
            withAnimation(LimpidMotion.dropIndicator) {
                dragState.hoverTargetID = targetID
                dragState.hoverPosition = next
            }
        }
        // Only the same-list reorder case mutates the model mid-drag.
        // Cross-container tab assignment (the whole-row tint case)
        // waits for `performDrop` so the user can still cancel by
        // releasing elsewhere — we can't roll back a "move tab into
        // worktree X" without rewriting the tab's container repeatedly,
        // which would thrash the active tab.
        guard !isCommittedOnDrop else { return }
        applyLiveReorder(at: next)
    }

    /// True when nothing moves until the drop: a tab assigned to a row, or
    /// a source dropped at a line, which a release elsewhere leaves where
    /// it was.
    private var isCommittedOnDrop: Bool {
        isCrossContainerTabAssignment || (dropsAtLine && dragState.current != .tab)
    }

    /// True when the in-flight drag is a tab landing on a row that
    /// treats tab payloads as container-assignment. Project / worktree
    /// drags on the same row still flow through the live reorder branch
    /// (so e.g. a worktree row is also a reorder target for other
    /// worktrees).
    private var isCrossContainerTabAssignment: Bool {
        tabAsContainerAssignment && dragState.current == .tab
    }

    private func applyLiveReorder(at position: DropPosition) {
        guard let raw = dragState.currentSourceID,
              let sourceUUID = UUID(uuidString: raw)
        else { return }
        // Skip self-drop and adjacency no-ops — the caller's
        // predicate already knows the data shape (project / worktree /
        // tab) and detects "drop right where you already
        // are" without us reverse-engineering targetID strings.
        if let isNoOp, isNoOp(sourceUUID, position) {
            return
        }
        // Dedupe repeat `dropUpdated` callbacks — SwiftUI fires those
        // at roughly the mouse-move rate.
        if dragState.lastLiveTarget == targetID,
           dragState.lastLivePosition == position
        {
            return
        }
        // Resolve the payload prefix from the in-flight kind first —
        // a pane drag returns nil here and we want to bail BEFORE
        // installing the snapshot. Pane drags cross `tabReorderTarget`
        // areas en route from the source `SurfaceView` to a tab pill,
        // so without this ordering every visit installed a no-op
        // snapshot whose mouse-up `restoreOrder` could silently roll
        // back unrelated mid-drag mutations (GitSync worktree
        // resync, a tab opened from another code path, etc.).
        guard let prefix = livePrefix() else { return }
        // Capture the order snapshot lazily on the first actual
        // mutation. Deferring it past `dragState.begin()` keeps the
        // SidebarDragPayload.make path unaware of the session, and
        // skips the work for drags that never live-reorder (e.g.
        // pure cross-container tab assignments).
        if dragState.orderSnapshot == nil {
            let snapshot = session.captureOrderSnapshot()
            dragState.orderSnapshot = snapshot
            dragState.restoreSnapshot = { [weak session] in
                guard let session else { return }
                withAnimation(LimpidMotion.reorderUnlessReduced) {
                    session.restoreOrder(snapshot)
                }
            }
        }
        dragState.lastLiveTarget = targetID
        dragState.lastLivePosition = position
        withAnimation(LimpidMotion.reorderLiveUnlessReduced) {
            onDrop(prefix, sourceUUID, position)
        }
    }

    private func livePrefix() -> String? {
        switch dragState.current {
        case .tab where acceptedPrefixes.contains("tab:"): "tab:"
        case .project where acceptedPrefixes.contains("project:"): "project:"
        case .worktree where acceptedPrefixes.contains("worktree:"): "worktree:"
        default: nil
        }
    }

    private func computePosition(_ info: DropInfo) -> DropPosition {
        let extent = extentProvider()
        guard extent > 0 else { return .before }
        let location = axis == .vertical ? info.location.y : info.location.x
        return location < extent / 2 ? .before : .after
    }
}

/// Shared no-op resolution so the modifier's whole-row tint and the
/// delegate's drop badge never disagree about "would releasing here
/// move anything?". The position source differs by caller — the
/// modifier reads the live `hoverPosition`, the delegate computes it
/// from `DropInfo` — so it's passed in rather than derived here.
@MainActor
private func dropWouldBeNoOp(
    dragState: LimpidDragState,
    isNoOp: ((UUID, DropPosition) -> Bool)?,
    position: DropPosition?
) -> Bool {
    guard let isNoOp,
          let position,
          let raw = dragState.currentSourceID,
          let sourceUUID = UUID(uuidString: raw)
    else { return false }
    return isNoOp(sourceUUID, position)
}
