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
// `accepts`. Unaccepted kinds return `.forbidden` and take no drop mark. A
// dragged project has no drop target: it is here for the sections' hold and
// the mouse-up.

import OSLog
import SwiftUI

/// Module-internal so the sidebar's `.draggable` sites can log
/// drag-start events through a single category (`sidebar.drag`) —
/// surfaces in `log show --predicate 'subsystem == "dev.limpid"'`
/// so the user can confirm a drag session actually starts.
let limpidDragLog = Logger.limpid("sidebar.drag")

/// What a drag's wire format (`<prefix><uuid>`) starts with, by what it
/// carries.
enum DragPrefix {
    static let tab = "tab:"
    static let worktree = "worktree:"
    static let pane = "pane:"
}

// MARK: - SidebarDragPayload (Transferable)

/// Transferable payload used by every sidebar draggable row (tab,
/// worktree). macOS 26 regressed the legacy
/// `.onDrag { NSItemProvider(object: NSString) }` path — drags
/// silently never start. `.draggable(Transferable)` is the
/// supported route. We keep the existing "`<prefix>:<uuid>`" wire
/// format so the receiving `UnifiedReorderDelegate` (which reads
/// `[.text]` item providers) keeps working unchanged: the
/// `ProxyRepresentation` to `String` makes that side a no-op.
struct SidebarDragPayload: Codable, Transferable {
    /// One of `DragPrefix`, which the drop side looks for.
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

@MainActor
extension SidebarDragPayload {
    /// Constructs the payload while announcing the drag kind to the
    /// global `LimpidDragState`. Called from the `.draggable`
    /// autoclosure — `begin()` is idempotent, so multiple invocations
    /// during a single drag session are safe.
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

@MainActor
extension View {
    /// Shared sidebar draggable wrapper. The legacy `.onDrag` path
    /// regressed on macOS 26 (drag sessions never start when the
    /// closure returns an `NSItemProvider`). `.draggable(Transferable)`
    /// is the supported route. We also bump the preview from the old
    /// 1×1 transparent rect to 40×24 — macOS 26 also refuses to begin
    /// a drag session when the snapshot is effectively invisible.
    /// `tabTitle` names the tab a `.tab` drag carries, on its chip.
    func limpidDraggable(
        kind: LimpidDragState.Kind,
        prefix: String,
        id: String,
        tabTitle: String? = nil,
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
            limpidDragPreview(tabTitle: tabTitle)
        }
    }
}

/// Drag preview for the shared `.draggable` rows. A tab shows a chip with
/// its name, since it can move to a different container and the person has
/// to see what they carry; a worktree only reorders in place and keeps the
/// transparent rect, non-empty only because macOS 26 won't start a drag from
/// an invisible snapshot.
@MainActor @ViewBuilder
private func limpidDragPreview(tabTitle: String?) -> some View {
    if let tabTitle {
        TabDragChip(title: tabTitle)
    } else {
        Color.clear.frame(
            width: LimpidLayout.Supervision.dragPreviewMinSize.width,
            height: LimpidLayout.Supervision.dragPreviewMinSize.height
        )
    }
}

/// @Observable singleton that tracks the current in-flight drag kind.
///
/// SwiftUI's `.onDrop` may skip `dropExited` when a drop is forbidden or
/// rejected, leaving a stale drop mark. `begin()` installs global/local
/// `NSEvent` mouse-up monitors and `watchForRelease`, which covers the
/// release they never see, so every drag reaches `end()` and resets `current`
/// to nil. Views observe `current` via `onChange` to clear their marks.
@MainActor
@Observable
final class LimpidDragState {
    enum Kind { case worktree, tab, project, pane }

    private(set) var current: Kind?

    /// The pane this drag carries. AppKit's own drag, whose pasteboard item an
    /// item provider cannot read as a string, so the drop reads it here.
    var carriedPaneID: UUID? {
        current == .pane ? currentSourceID.flatMap(UUID.init(uuidString:)) : nil
    }

    /// Whether the drag carries work a sidebar row can take: a tab, or a
    /// pane ⌥⌘-dragged out of one.
    var isCarryingToRow: Bool {
        current == .tab || current == .pane
    }

    /// Identifier of the in-flight payload. Lets drop targets skip the
    /// "would be a no-op" cases (dropping a row right before itself,
    /// dragging the bottom item to "end of list", etc.) so the drop mark
    /// only appears where releasing the mouse actually moves the item. Lives on the @MainActor instance so we don't need a
    /// `nonisolated(unsafe)` escape — drop targets reach it through
    /// the same `@Environment(LimpidDragState.self)` they use for
    /// `current` / `hoverTargetID`.
    var currentSourceID: String?

    /// Which drop target currently has the cursor over it. Each row in
    /// a reorderable list registers itself with a unique string here so
    /// only the hovered row paints the drop mark — and so a single
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

    /// The project whose header or rows a dragged tab or pane is over, in the one
    /// window's sidebar it is dragged across: the whole project is marked,
    /// so where the tab would go reads as this project before it reads as
    /// one of its rows. Kept through the hairline between two of its lines
    /// (`leaveProject`), so the mark does not flicker from row to row.
    private(set) var carriedOverProject: SidebarDropProject?
    /// The folded projects a dragged tab or pane rested on long enough
    /// (`LimpidMotion.springOpenDelay`): drawn open until the drag ends,
    /// without touching the window's arrangement, so a drag that goes
    /// elsewhere leaves them folded as they were. All of them stay open: one
    /// folding as the next opened would pull the rows under the pointer away.
    private(set) var springOpenProjects: Set<SidebarDropProject> = []
    /// The folded project the drag is resting on, waiting to open it.
    private var restingProject: SidebarDropProject?
    private var cancelRest: (@MainActor () -> Void)?
    /// The project drawn open by the drag that a tab was just dropped into.
    /// It outlives `end()` until the tab has landed and the sidebar opens the
    /// project for good (`SessionSidebarView`), so the rows the tab
    /// landed among do not fold away and back between the two.
    private(set) var keptOpenProject: SidebarDropProject?
    /// The row a tab was just dropped on, which flashes once so the eye
    /// finds where the tab went.
    private(set) var landing: SidebarLanding?
    /// Cancels the wait before a left project's mark goes, so an old leave
    /// never clears a mark the tab came back to.
    private var cancelProjectLeave: (@MainActor () -> Void)?
    /// Cancels the wait before the landed row's light fades, so an old drop
    /// never puts out the light of the next.
    private var cancelLandingFade: (@MainActor () -> Void)?

    /// Runs as the drag ends (`begin`).
    private var onEnd: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Ends a drag that AppKit let go of without telling us
    /// (`watchForRelease`). Stored so `end()` can stop it.
    private var cancelReleaseWatch: (@MainActor () -> Void)?
    /// Whether the mouse button is held. Injected so a test can hold a drag
    /// open with no real button down.
    private let isMouseButtonDown: () -> Bool

    /// Runs the drag's waits. Injected so a test steps them without sleeping.
    private let timer: HoverDelayTimer

    init(
        isMouseButtonDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
        timer: HoverDelayTimer = .live
    ) {
        self.isMouseButtonDown = isMouseButtonDown
        self.timer = timer
    }

    /// `onEnd` runs as the drag ends, however it does. A view watching
    /// `current` could miss a drag that began and ended between two updates.
    func begin(_ kind: Kind, sourceID: String? = nil, onEnd: (() -> Void)? = nil) {
        current = kind
        currentSourceID = sourceID
        // A drop that never landed, whose payload could not be read, holds
        // nothing open past the next drag.
        keptOpenProject = nil
        self.onEnd = onEnd
        installMouseUpMonitor()
        watchForRelease()
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
        springOpenProjects = []
        cancelRest?()
        cancelRest = nil
        restingProject = nil
        cancelReleaseWatch?()
        cancelReleaseWatch = nil
        cancelProjectLeave?()
        cancelProjectLeave = nil
        // Animate the indicator out so it never snaps off-screen
        // mid-drop. Also a safety net in case SwiftUI skipped the
        // delegate's `dropExited` (which sometimes happens when the
        // drag terminates outside any target).
        withAnimation(LimpidMotion.dropIndicator) {
            hoverTargetID = nil
            hoverPosition = nil
            carriedOverProject = nil
        }
        removeMouseUpMonitor()
        let onEnd = onEnd
        self.onEnd = nil
        onEnd?()
    }

    // MARK: - A tab over the sidebar's projects

    /// A dragged tab or pane came onto one of `project`'s lines.
    func enterProject(_ project: SidebarDropProject) {
        cancelProjectLeave?()
        cancelProjectLeave = nil
        guard carriedOverProject != project else { return }
        withAnimation(LimpidMotion.dropIndicator) {
            carriedOverProject = project
        }
    }

    /// A dragged tab or pane left one of `project`'s lines. The mark goes only when
    /// it has not come onto another of them a moment later: crossing the
    /// hairline between two rows leaves one before it enters the next.
    func leaveProject(_ project: SidebarDropProject) {
        guard carriedOverProject == project else { return }
        cancelProjectLeave?()
        cancelProjectLeave = timer.schedule(.seconds(LimpidMotion.projectLeaveGrace)) { [weak self] in
            guard let self, carriedOverProject == project else { return }
            withAnimation(LimpidMotion.dropIndicator) {
                carriedOverProject = nil
            }
        }
    }

    /// The drag came to rest on folded `project`, which opens once it has
    /// waited there.
    func beginRest(on project: SidebarDropProject) {
        cancelRest?()
        restingProject = project
        cancelRest = timer.schedule(.seconds(LimpidMotion.springOpenDelay)) { [weak self] in
            self?.restingProject = nil
            self?.springOpen(project)
        }
    }

    /// The drag moved off `project`, which cancels its wait. Another
    /// project's rest, begun first as the pointer crossed between them, goes
    /// on.
    func endRest(on project: SidebarDropProject) {
        guard restingProject == project else { return }
        cancelRest?()
        cancelRest = nil
        restingProject = nil
    }

    /// Draws `project` open while the drag lasts.
    func springOpen(_ project: SidebarDropProject) {
        guard isCarryingToRow, !springOpenProjects.contains(project) else { return }
        withAnimation(LimpidMotion.reorderUnlessReduced) {
            _ = springOpenProjects.insert(project)
        }
    }

    /// A tab dropped into `project`: when the drag drew it open, it stays
    /// open past `end()` (`keptOpenProject`). Called before `end()`.
    func keepSpringOpen(for project: SidebarDropProject) {
        guard springOpenProjects.contains(project) else { return }
        keptOpenProject = project
    }

    /// The tab did not land after all, or the sidebar now holds its project
    /// open itself.
    func releaseKeptOpen() {
        keptOpenProject = nil
    }

    /// The tab landed on `container` in `window`'s sidebar: that row
    /// flashes, and stops by itself.
    func land(on container: ContainerID, in window: WindowID) {
        let landing = SidebarLanding(window: window, container: container)
        self.landing = landing
        cancelLandingFade?()
        cancelLandingFade = timer.schedule(.seconds(LimpidMotion.landingHold)) { [weak self] in
            guard let self else { return }
            withAnimation(LimpidMotion.landingFadeUnlessReduced) {
                self.landing = nil
            }
        }
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

    /// Ends the drag once the button has been up for a moment. A release
    /// over no drop target calls no delegate, and the drag session's own
    /// mouse-up reaches neither monitor, so without this the drag lasted
    /// until the next click: the source stayed faded and a project the drag
    /// opened stayed open. The wait leaves `performDrop`, which reads
    /// `current` and arrives just after the release, to go first.
    private func watchForRelease() {
        guard cancelReleaseWatch == nil else { return }
        scheduleReleaseCheck()
    }

    private func scheduleReleaseCheck() {
        cancelReleaseWatch = timer.schedule(.seconds(LimpidMotion.dragReleasePoll)) { [weak self] in
            guard let self else { return }
            guard !isMouseButtonDown() else {
                scheduleReleaseCheck()
                return
            }
            cancelReleaseWatch = timer.schedule(.seconds(LimpidMotion.dragReleaseGrace)) { [weak self] in
                guard let self else { return }
                guard !isMouseButtonDown() else {
                    scheduleReleaseCheck()
                    return
                }
                end()
            }
        }
    }

    private func installMouseUpMonitor() {
        guard globalMonitor == nil else { return }
        // Local monitor handles mouse-up inside the app; global covers
        // mouse-up while the cursor is over another app's window. A drag
        // session's own mouse-up reaches neither (`watchForRelease`).
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

/// A project as one window's sidebar lists it: every window lists every
/// project, and a drag marks only the one it is dragged across.
struct SidebarDropProject: Hashable {
    let window: WindowID
    let projectID: UUID
}

/// A row a tab was dropped on, told apart from the next drop on the same
/// row, which flashes again.
struct SidebarLanding: Equatable {
    let id = UUID()
    let window: WindowID
    let container: ContainerID
}
