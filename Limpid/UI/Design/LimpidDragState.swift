// LimpidDragState.swift
// Limpid — what a sidebar drag carries, and which kind of drag is in flight.
//
// SwiftUI's `.dropDestination(for: String.self)` is treated internally as
// Copy, so a green "+" badge attaches to the cursor mid-drag. The drop
// targets go through a DropDelegate (`UnifiedReorderDelegate`) that returns
// `DropProposal(operation: .move)`, which gives a clean move cursor with no
// badge.
//
// In addition, a global `LimpidDragState` holds the kind of drag in flight
// (worktree / tab / project / pane) so each drop target can declare the kinds it
// `accepts`. Unaccepted kinds return `.forbidden` and the insertion-line
// indicator is suppressed.

import OSLog
import SwiftUI

/// Module-internal so the four sidebar `.draggable` sites can log
/// drag-start events through a single category (`sidebar.drag`) —
/// surfaces in `log show --predicate 'subsystem == "dev.limpid"'`
/// so the user can confirm a drag session actually starts.
let limpidDragLog = Logger.limpid("sidebar.drag")

// MARK: - SidebarDragPayload (Transferable)

/// Transferable payload used by every sidebar draggable row (tab,
/// project, worktree). macOS 26 regressed the legacy
/// `.onDrag { NSItemProvider(object: NSString) }` path — drags
/// silently never start. `.draggable(Transferable)` is the
/// supported route. We keep the existing "`<prefix>:<uuid>`" wire
/// format so the receiving `UnifiedReorderDelegate` (which reads
/// `[.text]` item providers) keeps working unchanged: the
/// `ProxyRepresentation` to `String` makes that side a no-op.
struct SidebarDragPayload: Codable, Transferable {
    /// Same prefix strings the drop side already greps for:
    /// "tab:", "project:", "worktree:".
    let prefix: String
    let id: String

    var wire: String {
        "\(prefix)\(id)"
    }

    static var transferRepresentation: some TransferRepresentation {
        // String proxy so item providers expose UTType.text — matches
        // what `UnifiedReorderDelegate.validateDrop` looks for.
        ProxyRepresentation(exporting: \.wire)
    }
}

extension SidebarDragPayload {
    /// Constructs the payload while announcing the drag kind to the
    /// global `LimpidDragState`. Called from the `.draggable`
    /// autoclosure — `begin()` is idempotent, so multiple invocations
    /// during a single drag session are safe.
    @MainActor
    static func make(
        kind: LimpidDragState.Kind,
        prefix: String,
        id: String,
        dragState: LimpidDragState
    ) -> SidebarDragPayload {
        dragState.begin(kind, sourceID: id)
        limpidDragLog.debug(
            "drag start \(prefix, privacy: .public)\(id, privacy: .public)"
        )
        return SidebarDragPayload(prefix: prefix, id: id)
    }
}

extension View {
    /// Shared sidebar draggable wrapper. The legacy `.onDrag` path
    /// regressed on macOS 26 (drag sessions never start when the
    /// closure returns an `NSItemProvider`). `.draggable(Transferable)`
    /// is the supported route. We also bump the preview from the old
    /// 1×1 transparent rect to 40×24 — macOS 26 also refuses to begin
    /// a drag session when the snapshot is effectively invisible.
    @MainActor
    func limpidDraggable(
        kind: LimpidDragState.Kind,
        prefix: String,
        id: String,
        dragState: LimpidDragState
    ) -> some View {
        draggable(
            SidebarDragPayload.make(
                kind: kind,
                prefix: prefix,
                id: id,
                dragState: dragState
            )
        ) {
            limpidDragPreview(kind: kind)
        }
    }
}

/// Drag preview for the shared `.draggable` rows. Only a tab gets a
/// visible chip (mirroring `SurfaceView.paneDragChip`), since it can
/// move to a different container; project / worktree only
/// reorder in place and keep the transparent rect — non-empty only
/// because macOS 26 won't start a drag from an invisible snapshot.
@MainActor @ViewBuilder
private func limpidDragPreview(kind: LimpidDragState.Kind) -> some View {
    if kind == .tab {
        // The popovers' surface in its `line` edge, at a surface's corner,
        // the glyph in the text color. Its colors are the tokens, not the
        // system's, so it reads as part of the window it is dragged across.
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.surfaceCornerRadius, style: .continuous)
        Image(systemName: "macwindow")
            .font(.supervision(.display, weight: .medium))
            .foregroundStyle(SupervisionTokens.text.color)
            .frame(width: 40, height: 40)
            .background(shape.fill(SupervisionTokens.popover.color))
            .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
    } else {
        Color.clear.frame(width: 40, height: 24)
    }
}

/// @Observable singleton that tracks the current in-flight drag kind.
///
/// SwiftUI's `.onDrop` may skip `dropExited` when a drop is forbidden or
/// rejected, leaving stale insertion-line indicators. `begin()` installs
/// global/local `NSEvent` mouse-up monitors so we always call `end()` on
/// mouse-up and reset `current` to nil. Views observe `current` via
/// `onChange` to clear their indicators.
@MainActor
@Observable
final class LimpidDragState {
    enum Kind { case worktree, tab, project, pane }

    private(set) var current: Kind?

    /// Identifier of the in-flight payload. Lets drop targets skip the
    /// "would be a no-op" cases (dropping a row right before itself,
    /// dragging the bottom item to "end of list", etc.) so the insertion
    /// indicator only appears where releasing the mouse actually moves
    /// the item. Lives on the @MainActor instance so we don't need a
    /// `nonisolated(unsafe)` escape — drop targets reach it through
    /// the same `@Environment(LimpidDragState.self)` they use for
    /// `current` / `hoverTargetID`.
    var currentSourceID: String?

    /// Which drop target currently has the cursor over it. Each row in
    /// a reorderable list registers itself with a unique string here so
    /// only the hovered row paints the insertion line — and so a single
    /// `end()` from the mouse-up monitor wipes the indicator regardless
    /// of how SwiftUI's drop lifecycle terminated.
    var hoverTargetID: String?
    var hoverPosition: ReorderableDropPosition?

    /// Last (target, position) pair the live-reorder pipeline applied.
    /// Compared inside `UnifiedReorderDelegate.update` to dedupe
    /// repeat `dropUpdated` callbacks — SwiftUI fires those at roughly
    /// the mouse-move rate, but we only want to mutate the model on
    /// actual transitions.
    var lastLiveTarget: String?
    var lastLivePosition: ReorderableDropPosition?

    /// Snapshot taken at drag-start so a drag that ends outside any
    /// drop target (or releases on a no-op) returns the order arrays
    /// to their pre-drag state. Cleared on a successful `performDrop`
    /// so the deferred mouse-up teardown leaves the live mutations in
    /// place; restored from in `end()` otherwise.
    var orderSnapshot: WorkspaceSession.OrderSnapshot?
    /// Closure that knows how to restore the snapshot against the
    /// concrete `WorkspaceSession`. Installed by the same callsite that
    /// captures the snapshot — keeps `LimpidDragState` from importing
    /// the session type directly. Cleared in `end()` after restore (or
    /// when `performDrop` commits the live edits and the caller wipes
    /// the snapshot itself).
    var restoreSnapshot: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {}

    func begin(_ kind: Kind, sourceID: String? = nil) {
        current = kind
        currentSourceID = sourceID
        installMouseUpMonitor()
    }

    func end() {
        // Restore the pre-drag order ONLY when the user never moved
        // the cursor onto a reorder sibling (no live reorder ever
        // applied). If `lastLiveTarget` is set, the row already
        // visibly settled into its new slot — keep it there even
        // when SwiftUI cancels the drag session before
        // `performDrop` fires (it sometimes does when the dragged
        // row moves out from under the cursor mid-mutation, which
        // is exactly the live-reorder happy path).
        let liveCommitted = lastLiveTarget != nil
        if !liveCommitted, let restore = restoreSnapshot {
            restore()
        }
        orderSnapshot = nil
        restoreSnapshot = nil
        lastLiveTarget = nil
        lastLivePosition = nil
        current = nil
        currentSourceID = nil
        // Animate the indicator out so it never snaps off-screen
        // mid-drop. Also a safety net in case SwiftUI skipped the
        // delegate's `dropExited` (which sometimes happens when the
        // drag terminates outside any target).
        withAnimation(LimpidMotion.dropIndicator) {
            hoverTargetID = nil
            hoverPosition = nil
        }
        removeMouseUpMonitor()
    }

    /// Called by `performDrop` once it has accepted the drop. Wipes
    /// the snapshot so the deferred mouse-up `end()` leaves the live
    /// mutations in place instead of rolling them back.
    func commitLiveReorder() {
        orderSnapshot = nil
        restoreSnapshot = nil
        lastLiveTarget = nil
        lastLivePosition = nil
    }

    private func installMouseUpMonitor() {
        guard globalMonitor == nil else { return }
        // Local monitor handles mouse-up inside the app; global covers
        // mouse-up while the cursor is over another app's window. Both
        // are needed so the indicator never lingers regardless of where
        // the drag finishes.
        //
        // Once `performDrop` lands on a target it already calls
        // `dragState.end()` itself before doing anything else, so
        // letting the monitor end the drag synchronously on the
        // mouse-up event is safe: the monitor's `end()` becomes a
        // no-op (re-entrant), and we avoid the perceptible "row
        // stays grabbed after release" lag that 3-finger drag users
        // see when the system's release-dwell timer stacks on top
        // of any deferred teardown we add.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.end()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.end()
        }
    }

    private func removeMouseUpMonitor() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }
}
