// ReorderableDropTarget.swift
// Limpid — shared drop modifier. Two interaction modes:
//   * live reorder — for in-list reorder (tab column tab reorder, container column group /
//     project / worktree reorder). As the cursor crosses a neighbour,
//     `onDrop` fires immediately so the rows physically slide into
//     their new positions (Finder / Notes / Reminders semantics). No
//     insertion line is drawn — the rows themselves are the indicator.
//   * background highlight — for container assignment (container column rows
//     receiving a tab from another container). The whole row tints
//     since the drop just moves the tab into the container; there's
//     no positional semantics, so we wait for the actual `performDrop`
//     to commit.
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
    /// window. `tabAsContainerAssignment`: when `true`, tab payloads
    /// trigger a background-highlight instead of an insertion line.
    /// Group / project payloads always use the insertion line.
    /// `isNoOp`: caller-provided predicate that returns `true` when
    /// dropping the given source at the given position wouldn't
    /// actually move it (e.g. drop right where it already is).
    /// Used to hide the indicator for those cases. Sources matching
    /// the target itself are always treated as no-op.
    func reorderableDropTarget(
        targetID: String,
        acceptedPrefixes: Set<String>,
        axis: Axis = .vertical,
        tabAsContainerAssignment: Bool = false,
        isNoOp: ((UUID, DropPosition) -> Bool)? = nil,
        onDrop: @escaping (String, UUID, DropPosition) -> Void
    ) -> some View {
        modifier(ReorderableDropTarget(
            targetID: targetID,
            acceptedPrefixes: acceptedPrefixes,
            axis: axis,
            tabAsContainerAssignment: tabAsContainerAssignment,
            isNoOp: isNoOp,
            onDrop: onDrop
        ))
    }
}

private struct ReorderableDropTarget: ViewModifier {
    @Environment(LimpidDragState.self) private var dragState
    @Environment(WindowSession.self) private var session
    @Environment(\.limpidAccent) private var accent
    let targetID: String
    let acceptedPrefixes: Set<String>
    let axis: Axis
    let tabAsContainerAssignment: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let onDrop: (String, UUID, DropPosition) -> Void

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
            .overlay {
                // Whole-row tint when a tab is being dropped into a
                // container (the container column use case). The in-list reorder
                // case skips the overlay because the rows themselves
                // animate into their new slot.
                if shouldShowBackgroundHighlight {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.20))
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.text], delegate: UnifiedReorderDelegate(
                targetID: targetID,
                acceptedPrefixes: acceptedPrefixes,
                axis: axis,
                tabAsContainerAssignment: tabAsContainerAssignment,
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
        case .group: return acceptedPrefixes.contains("group:")
        case .project: return acceptedPrefixes.contains("project:")
        case .worktree: return acceptedPrefixes.contains("worktree:")
        // tab column pane drops go through `MoveDropDelegate` directly, not the
        // sidebar reorder pipeline — never accept here.
        case .pane: return false
        }
    }
}

private struct UnifiedReorderDelegate: DropDelegate {
    let targetID: String
    let acceptedPrefixes: Set<String>
    let axis: Axis
    let tabAsContainerAssignment: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let dragState: LimpidDragState
    let session: WindowSession
    let extentProvider: () -> CGFloat
    let onDrop: (String, UUID, DropPosition) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        // Pane drops route through `paneMergeDropTarget` (or
        // `paneDetachDropTarget`), not the sidebar reorder pipeline.
        // Refuse here so SwiftUI lets the drop bubble up to whichever
        // outer drop modifier the TabRow / list happens to layer for
        // panes. Without this, a pane dropped on a tab row would be
        // consumed by `performDrop` below — which then no-ops, because
        // the UUID isn't a tab/group/project/worktree — and the user
        // sees the drag "vanish" with no merge.
        if dragState.current == .pane { return false }
        return true
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        // In-list reorder keeps `.move` (no badge) — the rows slide into
        // place and a badge would read as "duplicate".
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
        let needsCommitOnDrop = isCrossContainerTabAssignment
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
                        withAnimation(LimpidMotion.reorder) {
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
        // group X" without rewriting the tab's container repeatedly,
        // which would thrash the active tab.
        guard !isCrossContainerTabAssignment else { return }
        applyLiveReorder(at: next)
    }

    /// True when the in-flight drag is a tab landing on a row that
    /// treats tab payloads as container-assignment. Group / project /
    /// worktree drags on the same row still flow through the live
    /// reorder branch (so e.g. a group row is also a reorder target
    /// for other groups).
    private var isCrossContainerTabAssignment: Bool {
        tabAsContainerAssignment && dragState.current == .tab
    }

    private func applyLiveReorder(at position: DropPosition) {
        guard let raw = dragState.currentSourceID,
              let sourceUUID = UUID(uuidString: raw)
        else { return }
        // Skip self-drop and adjacency no-ops — the caller's
        // predicate already knows the data shape (group / project /
        // worktree / tab) and detects "drop right where you already
        // are" without us reverse-engineering targetID strings.
        if let isNoOp, isNoOp(sourceUUID, position) { return }
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
                withAnimation(LimpidMotion.reorder) {
                    session.restoreOrder(snapshot)
                }
            }
        }
        dragState.lastLiveTarget = targetID
        dragState.lastLivePosition = position
        withAnimation(LimpidMotion.reorderLive) {
            onDrop(prefix, sourceUUID, position)
        }
    }

    private func livePrefix() -> String? {
        switch dragState.current {
        case .tab where acceptedPrefixes.contains("tab:"): "tab:"
        case .group where acceptedPrefixes.contains("group:"): "group:"
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
