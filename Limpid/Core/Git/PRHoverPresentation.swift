// PRHoverPresentation.swift
// Limpid — presentation state for the hover-triggered PR card.
//
// One per window (`ProjectWindowState.prHover`), drawn at the window's root
// so `WindowChromeHost` can layer a single floating card over it. `.popover` was the obvious first choice,
// but with one open a click on a row only dismissed it — activating
// the row took a second click. A SwiftUI overlay at the scene root has
// no such step: the row's own tap gesture fires directly. See
// `PRHoverCard`'s banner for what that observation does and does not
// establish.
//
// Hover contract:
//   - open  : rowEntered() waits out the caller's delay, then
//             publishes a snapshot. The caller skips the delay under
//             Reduce Motion, where a fade-in with no motion reads as
//             lag. Only a part that opens the card calls it: a sidebar
//             row's mark and its second line's fact, a header's
//             chip.
//   - hold  : the rest of a sidebar row (`holdChanged`) keeps its open
//             card up while the pointer crosses the row toward the card,
//             and opens none, so the row's own tooltip is what its name
//             shows.
//   - close : rowExited() and cardHoverChanged(false) both feed a
//             single dismiss task, so the pointer can cross the row →
//             card gap without dismissing.
//   - the visible snapshot's `anchorRect` follows the row's global
//     frame — scroll or resize won't leave the card orphaned.

import Foundation
import Observation

/// What opened the card: a request's branch, and the place that shows it.
/// The sidebar's row and the session header's chip both show the same
/// branch's request, so the branch alone would let one place's card be
/// moved or closed by the other.
struct PRHoverSource: Hashable, Sendable {
    enum Place: Hashable, Sendable {
        /// A sidebar row.
        case row
        /// The supervision window's session header, under the pointer.
        case sessionHeader
        /// The same chip while the keyboard is on it: counted apart from
        /// the pointer, so the pointer leaving the chip does not close a
        /// card the keyboard still holds open.
        case sessionHeaderFocus
    }

    /// Which part of a place the pointer is on. One place's parts open
    /// one card, the place's, so moving between them neither closes it
    /// nor shows it afresh.
    enum Part: Hashable, Sendable {
        /// The whole view the card is attached to: the header's chip, or
        /// the keyboard's hold on it.
        case whole
        /// A sidebar row's pull request mark, beside its agent badge.
        case mark
        /// A sidebar row's second line, while it states the request.
        case fact
    }

    let container: ContainerID
    var place = Place.row
}

/// Runs the card's delayed steps, the open delay and the dismiss grace,
/// and hands back what cancels a step that has not run. Tests pass a
/// timer they step by hand, so they check the order of the transitions
/// without sleeping for them.
struct PRHoverTimer: Sendable {
    /// Runs the action once the delay has passed, unless the returned
    /// cancel runs first.
    let schedule: @MainActor @Sendable (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// Sleeps on a task for the delay.
    static let live = PRHoverTimer { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            // `try? await Task.sleep` swallows the cancellation error
            // and falls through, so a canceled step would otherwise run
            // at once: a show with no delay, or a dismissal with no grace.
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

@MainActor
@Observable
final class PRHoverPresentation {
    /// Snapshot of the row that currently owns the floating card.
    /// Nil when nothing is visible. `WindowChromeHost` reads this to render
    /// the overlay.
    private(set) var visible: Snapshot?

    struct Snapshot: Equatable {
        let rowID: PRHoverSource
        let info: PRInfo
        var anchorRect: CGRect
    }

    /// One hovered region: a part that opens its place's card, or the
    /// rest of a row, which only holds that row's card open.
    private struct Region: Hashable {
        let source: PRHoverSource
        /// The part that opens the card; `nil` for the rest of a row.
        let part: PRHoverSource.Part?

        var opensCard: Bool {
            part != nil
        }
    }

    // MARK: - Internal state

    //
    // This type holds the hover state for every request row and the
    // card body itself so we can express "visible while any of them is
    // hovered" as a single condition. Per-row hover state lives in a
    // Set (not a Bool) because during hand-off between two adjacent
    // rows the pointer can enter the second row before leaving the
    // first — a naive Bool would flip the order and dismiss the card
    // mid-slide. The same holds between a row's mark and its fact.

    private var hovering: Set<Region> = []
    private var cardIsHovering = false
    /// Cancels the pending dismissal, if one is scheduled.
    private var cancelDismiss: (@MainActor () -> Void)?
    /// Cancels the pending show, if one is scheduled.
    private var cancelShow: (@MainActor () -> Void)?
    /// Region the pending show belongs to. Without this, leaving
    /// row A would cancel the show that entering row B had just
    /// armed — SwiftUI delivers the enter before the leave when the
    /// pointer slides between adjacent rows, which is precisely the
    /// ordering `hovering` exists to tolerate.
    private var pendingShowRegion: Region?
    /// Where each sidebar row is (`anchorChanged`), for a card opened from
    /// a part of the row and hung beside the whole row rather than the
    /// part. Read only when a card is shown, so it is not observed: a
    /// scroll writes it every frame.
    @ObservationIgnored private var anchors: [PRHoverSource: CGRect] = [:]

    /// How long the pointer has to rest on a row before its card
    /// appears. Long enough that dragging the pointer down the sidebar
    /// does not flash a card per row, short enough to read as a
    /// deliberate peek rather than a wait.
    static let openDelay: Duration = .milliseconds(250)

    /// Grace period started when the pointer leaves either the row or
    /// the card, long enough to cross the gap between them before the
    /// card is taken away. Whether it is actually gone is decided when
    /// the period expires, not when it starts. Long enough for the
    /// trip, short enough that a dismissal the user did intend does
    /// not feel sticky — nothing ties it to the open delay.
    static let dismissGrace: Duration = .milliseconds(150)

    /// Runs the open delay and the dismiss grace.
    private let timer: PRHoverTimer

    init(timer: PRHoverTimer = .live) {
        self.timer = timer
    }

    // MARK: - Row-side events

    /// Pointer entered `part` of `rowID`. `anchor` is what the card hangs
    /// beside; `nil` hangs it beside the row's own frame (`anchorChanged`).
    func rowEntered(
        rowID: PRHoverSource,
        part: PRHoverSource.Part = .whole,
        info: PRInfo,
        anchor: CGRect?,
        delay: Duration
    ) {
        let region = Region(source: rowID, part: part)
        hovering.insert(region)
        cancelDismiss?()
        cancelShow?()
        pendingShowRegion = region
        cancelShow = timer.schedule(delay) { [weak self] in
            guard let self, hovering.contains(region) else { return }
            // Read as it is shown, so a row that moved while the pointer
            // rested on it hangs its card where the row is now. A row that
            // never said where it is shows none: a card at the window's
            // origin, over the title bar, is never beside its row.
            guard let anchorRect = anchor ?? anchors[rowID] else { return }
            visible = Snapshot(rowID: rowID, info: info, anchorRect: anchorRect)
        }
    }

    /// Pointer left `part` of `rowID`.
    func rowExited(rowID: PRHoverSource, part: PRHoverSource.Part = .whole) {
        let region = Region(source: rowID, part: part)
        hovering.remove(region)
        if pendingShowRegion == region {
            cancelShow?()
            pendingShowRegion = nil
        }
        scheduleDismiss()
    }

    /// The pointer came onto or left the rest of a row whose card opens
    /// from its parts. It holds that row's open card up, so the pointer
    /// can cross the row to the card, and opens none.
    func holdChanged(rowID: PRHoverSource, isHovering: Bool) {
        let region = Region(source: rowID, part: nil)
        if isHovering {
            hovering.insert(region)
            if visible?.rowID == rowID {
                cancelDismiss?()
            }
        } else {
            hovering.remove(region)
            scheduleDismiss()
        }
    }

    /// The part left the view hierarchy while still hovered — worktree
    /// removed, PR entry cleared by a refetch, the row's mark gave way to
    /// a state, or the feature switched off. SwiftUI delivers no final
    /// `onHover(false)` in that case, so without this the part would stay
    /// in `hovering` and every future dismissal would fail its guard,
    /// leaving the card on screen with no way to remove it.
    func rowDisappeared(rowID: PRHoverSource, part: PRHoverSource.Part = .whole) {
        rowExited(rowID: rowID, part: part)
        if visible?.rowID == rowID, !isPointerOnPart(of: rowID) {
            clear()
        }
    }

    /// The row's on-screen frame moved (scroll, resize, reflow). No-op
    /// unless this row is the one currently visible.
    func updateAnchor(rowID: PRHoverSource, anchor: CGRect) {
        guard var current = visible, current.rowID == rowID else { return }
        current.anchorRect = anchor
        visible = current
    }

    /// A row whose card opens from its parts moved: kept for the card a
    /// part shows next, and followed by the card it shows now.
    func anchorChanged(rowID: PRHoverSource, anchor: CGRect) {
        anchors[rowID] = anchor
        updateAnchor(rowID: rowID, anchor: anchor)
    }

    /// That row left the hierarchy, and its card goes with it.
    func anchorDisappeared(rowID: PRHoverSource) {
        anchors[rowID] = nil
        holdChanged(rowID: rowID, isHovering: false)
        if visible?.rowID == rowID {
            clear()
        }
    }

    // MARK: - Card-side events

    /// Pointer entered / left the floating card body.
    func cardHoverChanged(_ hovering: Bool) {
        cardIsHovering = hovering
        if hovering {
            cancelDismiss?()
        } else {
            scheduleDismiss()
        }
    }

    // MARK: - Dismissal

    /// Whether a part of `source` that opens its card is under the pointer.
    private func isPointerOnPart(of source: PRHoverSource) -> Bool {
        hovering.contains { $0.source == source && $0.opensCard }
    }

    /// Whether anything keeps the visible card up: a part that opens a
    /// card (this one's, or the next one's about to replace it), or the
    /// rest of this card's own row. Another row's rest does not.
    private var keepsVisible: Bool {
        hovering.contains { $0.opensCard || $0.source == visible?.rowID }
    }

    private func scheduleDismiss() {
        cancelDismiss?()
        cancelDismiss = timer.schedule(Self.dismissGrace) { [weak self] in
            guard let self else { return }
            if !keepsVisible, !cardIsHovering {
                clear()
            }
        }
    }

    /// Drop the visible card and reset hover bookkeeping. Resetting
    /// `cardIsHovering` matters because SwiftUI does not reliably
    /// deliver a final `onHover(false)` when a hovered view leaves the
    /// hierarchy — a latched flag would block every later dismissal.
    private func clear() {
        visible = nil
        cardIsHovering = false
    }

    /// Hide everything at once. Used when the feature is switched off
    /// mid-hover, where waiting out the grace period would leave a
    /// card floating over a sidebar that no longer explains it.
    func reset() {
        cancelShow?()
        pendingShowRegion = nil
        cancelDismiss?()
        hovering.removeAll()
        clear()
    }
}

/// Tells `PRHoverPresentation` where a sidebar row is, for the card its
/// parts open (`prHoverCardAnchor`). Three things have to meet before the
/// row can say so: its frame, its request, and its being in the list. They
/// arrive in any order: the request is fetched after the row is laid out,
/// and the sidebar's lazy list takes a row away and brings it back without
/// moving it. Reporting only when the frame changed left such a row with
/// no anchor, and its card opened at the window's origin. A class held in
/// the view's state, so a scroll's frames are kept without drawing the
/// row again.
@MainActor
final class PRHoverAnchorReporter {
    private var frame: CGRect?
    private var source: PRHoverSource?
    private var isShown = false

    /// The row's frame in the window moved, or was first measured.
    func frameChanged(_ frame: CGRect, in presentation: PRHoverPresentation) {
        self.frame = frame
        report(to: presentation)
    }

    /// The row's request came, went, or moved to another branch: the old
    /// one's card goes, as it would were the row gone.
    func sourceChanged(to source: PRHoverSource?, in presentation: PRHoverPresentation) {
        guard source != self.source else { return }
        if let old = self.source {
            presentation.anchorDisappeared(rowID: old)
        }
        self.source = source
        report(to: presentation)
    }

    func appeared(in presentation: PRHoverPresentation) {
        isShown = true
        report(to: presentation)
    }

    func disappeared(in presentation: PRHoverPresentation) {
        isShown = false
        if let source {
            presentation.anchorDisappeared(rowID: source)
        }
    }

    private func report(to presentation: PRHoverPresentation) {
        guard isShown, let source, let frame else { return }
        presentation.anchorChanged(rowID: source, anchor: frame)
    }
}
