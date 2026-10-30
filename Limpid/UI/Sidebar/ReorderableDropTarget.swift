// ReorderableDropTarget.swift
// Limpid — the drop modifier for live reordering, for a tab dropped on a sidebar row, and for a header dropped at a line.
//
// Three interaction modes:
//   * live reorder — for in-list reorder (tabs, a project's worktree
//     rows). As the cursor crosses a neighbor, `onDrop` fires
//     immediately so the rows physically slide into their new positions
//     (Finder / Notes / Reminders semantics). No insertion line is
//     drawn — the rows themselves are the indicator.
//   * assignment — a sidebar row receiving a tab or pane from another
//     container, in any project, or a pane strip tab receiving a pane. A
//     row takes the drop mark
//     (`SupervisionRowDropMark`) since the drop just moves the tab into
//     the container; there's no positional semantics, so we wait for the
//     actual `performDrop` to commit. A line that names its project marks
//     the whole project too (`LimpidDragState.carriedOverProject`).
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
    /// window. `assignsOnDrop`: when `true`, a tab or pane payload
    /// takes the row's drop mark and moves only on the drop. Project and
    /// worktree payloads reorder live, or at a line when `dropsAtLine` is
    /// set.
    /// `isNoOp`: caller-provided predicate that returns `true` when
    /// dropping the given source at the given position wouldn't
    /// actually move it (e.g. drop right where it already is).
    /// Used to hide the indicator for those cases. Sources matching
    /// the target itself are always treated as no-op. `dropsAtLine`: the
    /// line mode, which draws where the source would land and moves it
    /// only on the drop. `rowMark`: which tab drags mark the line as
    /// where the tab would go (`RowDropMark`). `project`: the sidebar
    /// project the line is part of, which a tab over the line marks whole.
    func reorderableDropTarget(
        targetID: String,
        acceptedPrefixes: Set<String>,
        axis: Axis = .vertical,
        assignsOnDrop: Bool = false,
        rowMark: RowDropMark = .own,
        project: SidebarDropProject? = nil,
        dropsAtLine: Bool = false,
        isNoOp: ((UUID, DropPosition) -> Bool)? = nil,
        onDrop: @escaping (String, UUID, DropPosition) -> Void
    ) -> some View {
        modifier(ReorderableDropTarget(
            targetID: targetID,
            acceptedPrefixes: acceptedPrefixes,
            axis: axis,
            assignsOnDrop: assignsOnDrop,
            rowMark: rowMark,
            project: project,
            dropsAtLine: dropsAtLine,
            isNoOp: isNoOp,
            onDrop: onDrop
        ))
    }
}

/// Which tab drags mark a line that takes a tab as where it would go.
enum RowDropMark: Equatable {
    /// A tab over the line itself.
    case own
    /// A tab over the line, or over the target `targetID`, whose drop lands
    /// here: a project's header drops a tab on its repository row, which
    /// shows where the tab would go while the header is under it.
    case alsoUnder(targetID: String)
    /// None: the line's drop lands on another line, which is marked
    /// instead.
    case none
}

private struct ReorderableDropTarget: ViewModifier {
    @Environment(LimpidDragState.self) private var dragState
    @Environment(WorkspaceSession.self) private var session
    let targetID: String
    let acceptedPrefixes: Set<String>
    let axis: Axis
    let assignsOnDrop: Bool
    let rowMark: RowDropMark
    let project: SidebarDropProject?
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
            // The sidebar rows mark a tab's drop in the row's own shape,
            // and the row's name takes the accent with it. The in-list
            // reorder case draws no mark because the rows themselves animate
            // into their new slot.
            .environment(\.isDropTarget, shouldShowBackgroundHighlight)
            .modifier(SupervisionRowDropMark(
                isTargeted: shouldShowBackgroundHighlight,
                cornerRadius: LimpidLayout.Supervision.sessionRowCornerRadius
            ))
            // The line mode's mark: where the source would land, on the
            // edge it would land at, over the gap rather than in it.
            .overlay(alignment: dragState.hoverPosition == .after ? .bottom : .top) {
                // A project's drag alone: as any drag ends, its kind goes
                // before its hover does.
                if dropsAtLine, isHoveredHere, dragState.current == .project {
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
                assignsOnDrop: assignsOnDrop,
                project: project,
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
        guard assignsOnDrop, dragState.isCarryingToRow else { return false }
        switch rowMark {
        case .own:
            return isHoveredHere
        case let .alsoUnder(other):
            return isHoveredHere || (dragState.hoverTargetID == other && acceptsCurrentDrag && !wouldBeNoOp)
        case .none:
            return false
        }
    }

    private var acceptsCurrentDrag: Bool {
        guard let current = dragState.current else { return true }
        switch current {
        case .tab: return acceptedPrefixes.contains(DragPrefix.tab)
        case .project: return acceptedPrefixes.contains(DragPrefix.project)
        case .worktree: return acceptedPrefixes.contains(DragPrefix.worktree)
        case .pane: return acceptedPrefixes.contains(DragPrefix.pane)
        }
    }
}

private struct UnifiedReorderDelegate: DropDelegate {
    let targetID: String
    let acceptedPrefixes: Set<String>
    let axis: Axis
    let assignsOnDrop: Bool
    let project: SidebarDropProject?
    let dropsAtLine: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let dragState: LimpidDragState
    let session: WorkspaceSession
    let extentProvider: () -> CGFloat
    let onDrop: (String, UUID, DropPosition) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        // A target that takes no pane refuses one, so SwiftUI lets the drop
        // bubble up to whichever outer modifier layers one.
        if dragState.current == .pane {
            return acceptedPrefixes.contains(DragPrefix.pane)
        }
        // A target that takes no tab refuses one outright, rather than
        // badge it and drop it on nothing.
        if dragState.current == .tab, !acceptedPrefixes.contains(DragPrefix.tab) {
            return false
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        // Every drop here moves its source, and `.move` shows no badge: a
        // tab landing on another container too, where the green `+` would
        // say it is copied. When the tab already lives in this container
        // the drop is a no-op, so refuse it with `.forbidden`, which also
        // matches the mark, which `isHoveredHere` gates on `!wouldBeNoOp`.
        // The delegate has no live `hoverPosition` to read, so resolve the
        // position straight from `DropInfo`.
        if isAssignedOnDrop,
           dropWouldBeNoOp(dragState: dragState, isNoOp: isNoOp, position: computePosition(info))
        {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragState.isCarryingToRow, let project {
            dragState.leaveProject(project)
        }
        if dragState.hoverTargetID == targetID {
            withAnimation(LimpidMotion.dropIndicator) {
                dragState.hoverTargetID = nil
                dragState.hoverPosition = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let position = computePosition(info)
        let carriedPane = dragState.carriedPaneID
        let provider = info.itemProviders(for: [.text]).first
        guard carriedPane != nil || provider != nil else {
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
        // A project the drag drew open stays open once the tab lands in
        // it; `end()` would fold it before the tab got there.
        if dragState.isCarryingToRow, let project {
            dragState.keepSpringOpen(for: project)
        }
        // Discard the snapshot before `end()` so the live mutations stick.
        dragState.commitLiveReorder()
        dragState.end()
        guard needsCommitOnDrop else { return true }
        if let carriedPane {
            withAnimation(LimpidMotion.reorderUnlessReduced) {
                onDrop(DragPrefix.pane, carriedPane, position)
            }
            return true
        }
        _ = provider?.loadObject(ofClass: NSString.self) { item, _ in
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
        // A line the drag would change nothing on marks nothing, as the
        // line's own mark does not.
        if dragState.isCarryingToRow, let project,
           !dropWouldBeNoOp(dragState: dragState, isNoOp: isNoOp, position: next)
        {
            dragState.enterProject(project)
        }
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
        isAssignedOnDrop || dropsAtLine
    }

    /// True when the in-flight drag assigns what it carries to this target
    /// on the drop: a tab or pane on a row that treats them as
    /// container-assignment, or a pane on any target that takes one. Project
    /// / worktree drags on the same row still flow through the live reorder
    /// branch (so e.g. a worktree row is also a reorder target for other
    /// worktrees).
    private var isAssignedOnDrop: Bool {
        ReorderDropRule.isAssignedOnDrop(
            isCarryingToRow: dragState.isCarryingToRow,
            isPane: dragState.current == .pane,
            assignsOnDrop: assignsOnDrop,
            acceptedPrefixes: acceptedPrefixes
        )
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
        // Resolve the payload prefix from the in-flight kind first, and
        // bail BEFORE installing the snapshot for a kind that never
        // reorders live: a no-op snapshot's mouse-up `restoreOrder` could
        // silently roll back unrelated mid-drag mutations (GitSync
        // worktree resync, a tab opened from another code path, etc.).
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
        case .tab where acceptedPrefixes.contains(DragPrefix.tab): DragPrefix.tab
        case .project where acceptedPrefixes.contains(DragPrefix.project): DragPrefix.project
        case .worktree where acceptedPrefixes.contains(DragPrefix.worktree): DragPrefix.worktree
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

/// Which drags a target commits only on the drop, rather than live.
enum ReorderDropRule {
    static func isAssignedOnDrop(isCarryingToRow: Bool, isPane: Bool, assignsOnDrop: Bool, acceptedPrefixes: Set<String>) -> Bool {
        (assignsOnDrop && isCarryingToRow) || (isPane && acceptedPrefixes.contains(DragPrefix.pane))
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
