// ReorderableDropTarget.swift
// Limpid — shared drop modifier. Two interaction modes:
//   * live reorder — for in-list reorder (L2 tab reorder, L1 group /
//     project / worktree reorder). As the cursor crosses a neighbour,
//     `onDrop` fires immediately so the rows physically slide into
//     their new positions (Finder / Notes / Reminders semantics). No
//     insertion line is drawn — the rows themselves are the indicator.
//   * background highlight — for container assignment (L1 rows
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
        tabAsContainerAssignment: Bool = false,
        isNoOp: ((UUID, DropPosition) -> Bool)? = nil,
        onDrop: @escaping (String, UUID, DropPosition) -> Void
    ) -> some View {
        modifier(ReorderableDropTarget(
            targetID: targetID,
            acceptedPrefixes: acceptedPrefixes,
            tabAsContainerAssignment: tabAsContainerAssignment,
            isNoOp: isNoOp,
            onDrop: onDrop
        ))
    }
}

private struct ReorderableDropTarget: ViewModifier {
    @Environment(LimpidDragState.self) private var dragState
    @Environment(WindowSession.self) private var session
    let targetID: String
    let acceptedPrefixes: Set<String>
    let tabAsContainerAssignment: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let onDrop: (String, UUID, DropPosition) -> Void

    @State private var rowHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { rowHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, new in rowHeight = new }
                }
            )
            .overlay {
                // Whole-row tint when a tab is being dropped into a
                // container (the L1 use case). The in-list reorder
                // case skips the overlay because the rows themselves
                // animate into their new slot.
                if shouldShowBackgroundHighlight {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LimpidColor.accent.opacity(0.20))
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.text], delegate: UnifiedReorderDelegate(
                targetID: targetID,
                acceptedPrefixes: acceptedPrefixes,
                tabAsContainerAssignment: tabAsContainerAssignment,
                isNoOp: isNoOp,
                dragState: dragState,
                session: session,
                rowHeightProvider: { rowHeight },
                onDrop: onDrop
            ))
    }

    private var isHoveredHere: Bool {
        dragState.hoverTargetID == targetID
            && acceptsCurrentDrag
            && !wouldBeNoOp
    }

    /// Suppress the whole-row tint for tab → same-container drags
    /// (the obvious "drop where you already are" case). Mirrors the
    /// pre-live-reorder behaviour for the cross-container assignment
    /// path; the live reorder path doesn't paint a highlight at all.
    private var wouldBeNoOp: Bool {
        guard let raw = dragState.currentSourceID,
              let isNoOp,
              let position = dragState.hoverPosition,
              let sourceUUID = UUID(uuidString: raw)
        else { return false }
        return isNoOp(sourceUUID, position)
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
        }
    }
}

private struct UnifiedReorderDelegate: DropDelegate {
    let targetID: String
    let acceptedPrefixes: Set<String>
    let tabAsContainerAssignment: Bool
    let isNoOp: ((UUID, DropPosition) -> Bool)?
    let dragState: LimpidDragState
    let session: WindowSession
    let rowHeightProvider: () -> CGFloat
    let onDrop: (String, UUID, DropPosition) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragState.hoverTargetID == targetID {
            withAnimation(.easeInOut(duration: 0.12)) {
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
        // Live reorder already mutated the model the moment the
        // cursor crossed a neighbour. Commit those changes by
        // discarding the snapshot before `end()` runs.
        dragState.commitLiveReorder()
        dragState.end()
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let raw = item as? String else { return }
            for prefix in acceptedPrefixes {
                if raw.hasPrefix(prefix),
                   let id = UUID(uuidString: String(raw.dropFirst(prefix.count)))
                {
                    Task { @MainActor in
                        // Cross-container assignment (e.g. tab into a
                        // group / project row) still flows through
                        // `performDrop` — live reorder only handles
                        // same-list reorder. Animate this last leg so
                        // the L2/L3 transition matches the live
                        // animation curve.
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
            withAnimation(.easeInOut(duration: 0.12)) {
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
        // Resolve the payload prefix from the in-flight kind. The
        // `acceptedPrefixes` set is the receiver's filter; we pick
        // the prefix matching the active drag so the same `onDrop`
        // closure callsites (group: / project: / worktree: / tab:)
        // keep working unchanged.
        guard let prefix = livePrefix() else { return }
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
        let h = rowHeightProvider()
        guard h > 0 else { return .before }
        return info.location.y < h / 2 ? .before : .after
    }
}
