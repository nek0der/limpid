// PRHoverPresentation.swift
// Limpid — presentation state for the hover-triggered PR card.
//
// Lives at the scene root so `ContentView` can layer a single floating
// card over the whole window. `.popover` was the obvious first choice,
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
//             lag.
//   - close : rowExited() and cardHoverChanged(false) both feed a
//             single dismiss task, so the pointer can cross the row →
//             card gap without dismissing.
//   - the visible snapshot's `anchorRect` follows the row's global
//     frame — scroll or resize won't leave the card orphaned.

import Foundation
import Observation

@MainActor
@Observable
final class PRHoverPresentation {
    /// Snapshot of the row that currently owns the floating card.
    /// Nil when nothing is visible. `ContentView` reads this to render
    /// the overlay.
    private(set) var visible: Snapshot?

    struct Snapshot: Equatable {
        let rowID: ContainerID
        let info: PRInfo
        var anchorRect: CGRect
    }

    // MARK: - Internal state

    //
    // This type holds the hover state for every request row and the
    // card body itself so we can express "visible while any of them is
    // hovered" as a single condition. Per-row hover state lives in a
    // Set (not a Bool) because during hand-off between two adjacent
    // rows the pointer can enter the second row before leaving the
    // first — a naive Bool would flip the order and dismiss the card
    // mid-slide.

    private var hoveringRows: Set<ContainerID> = []
    private var cardIsHovering = false
    private var dismissTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    /// Row the pending `showTask` belongs to. Without this, leaving
    /// row A would cancel the show task that entering row B had just
    /// armed — SwiftUI delivers the enter before the leave when the
    /// pointer slides between adjacent rows, which is precisely the
    /// ordering `hoveringRows` exists to tolerate.
    private var showTaskRowID: ContainerID?

    /// Grace period between the pointer leaving everything and the
    /// card disappearing, so it can cross the row → card gap.
    /// Injectable so tests can drive the state machine without
    /// sleeping for real.
    private let dismissDelay: Duration

    init(dismissDelay: Duration = LimpidLayout.prHoverCardDismissGrace) {
        self.dismissDelay = dismissDelay
    }

    // MARK: - Row-side events

    /// Pointer entered `rowID`'s hover region.
    func rowEntered(rowID: ContainerID, info: PRInfo, anchor: CGRect, delay: Duration) {
        hoveringRows.insert(rowID)
        dismissTask?.cancel()
        showTask?.cancel()
        let snapshot = Snapshot(rowID: rowID, info: info, anchorRect: anchor)
        showTaskRowID = rowID
        showTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            // `try? await Task.sleep` swallows the cancellation error
            // and falls through, so a cancelled task would otherwise
            // publish immediately with no delay at all.
            guard !Task.isCancelled else { return }
            guard hoveringRows.contains(rowID) else { return }
            visible = snapshot
        }
    }

    /// Pointer left `rowID`'s hover region.
    func rowExited(rowID: ContainerID) {
        hoveringRows.remove(rowID)
        if showTaskRowID == rowID {
            showTask?.cancel()
            showTaskRowID = nil
        }
        scheduleDismiss()
    }

    /// The row left the view hierarchy while still hovered — worktree
    /// removed, PR entry cleared by a refetch, or the feature switched
    /// off. SwiftUI delivers no final `onHover(false)` in that case,
    /// so without this the row's id would stay in `hoveringRows` and
    /// every future dismissal would fail its `isEmpty` guard, leaving
    /// the card on screen with no way to remove it.
    func rowDisappeared(rowID: ContainerID) {
        rowExited(rowID: rowID)
        if visible?.rowID == rowID {
            clear()
        }
    }

    /// The row's on-screen frame moved (scroll, resize, reflow). No-op
    /// unless this row is the one currently visible.
    func updateAnchor(rowID: ContainerID, anchor: CGRect) {
        guard var current = visible, current.rowID == rowID else { return }
        current.anchorRect = anchor
        visible = current
    }

    // MARK: - Card-side events

    /// Pointer entered / left the floating card body.
    func cardHoverChanged(_ hovering: Bool) {
        cardIsHovering = hovering
        if hovering {
            dismissTask?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    // MARK: - Dismissal

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: dismissDelay)
            // See `rowEntered` — a cancelled sleep falls through, and
            // here that would collapse the grace period that lets the
            // pointer travel from the row to the card.
            guard !Task.isCancelled else { return }
            if hoveringRows.isEmpty, !cardIsHovering {
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
        showTask?.cancel()
        showTaskRowID = nil
        dismissTask?.cancel()
        hoveringRows.removeAll()
        clear()
    }
}
