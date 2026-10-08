// PaneRenamePresentation.swift
// Limpid — the one channel for pane renames that start outside the header:
// the terminal's "Rename Pane…" item asks here, and the floating rename
// field a narrow header opens is published here.
//
// Held per window at the scene root, like `PRHoverPresentation`, because
// the floating field is wider than the pane it renames and the pane clips
// what it draws. The header decides where a rename is edited;
// `PaneRenamePanelHost` draws the floating one over the whole window,
// anchored under that header.

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class PaneRenamePresentation {
    /// A rename the terminal's context menu asked for. The menu lives on the
    /// AppKit surface and the field in the header, so the menu only says
    /// "start" and the header takes it from here. `id` is minted per ask, so
    /// asking twice for the same pane is still seen as a new ask.
    struct PendingRename: Equatable {
        let id: UUID
        let paneID: UUID
    }

    /// One floating rename. `id` is minted per open so a field that has
    /// been replaced cannot finish the request that replaced it.
    struct Request: Equatable {
        let id: UUID
        let paneID: UUID
        /// The name the header showed when the edit began, which the field
        /// opens with and the commit rule compares against.
        let name: String
        /// The header's frame in global coordinates. The panel hangs below
        /// it, or above it near the window's bottom, and follows it while
        /// the window resizes.
        var anchor: CGRect
    }

    /// The ask a header has not taken yet. Headers react to it changing,
    /// never to finding it set when they mount, so an ask nobody took
    /// cannot fire later on a header that appears afterwards.
    private(set) var pendingRename: PendingRename?

    /// The floating rename on screen, if any. One per window: opening
    /// another replaces it.
    private(set) var request: Request?

    // MARK: - Asking for a rename

    /// Ask `paneID`'s header to start a rename. The caller only asks while
    /// that header is on screen (`PaneHeaderRules.showsHeader`).
    func requestRename(paneID: UUID) {
        pendingRename = PendingRename(id: UUID(), paneID: paneID)
    }

    /// Take the ask if it is for `paneID`. True when this header should
    /// start a rename.
    func takeRenameRequest(paneID: UUID) -> Bool {
        guard pendingRename?.paneID == paneID else { return false }
        pendingRename = nil
        return true
    }

    // MARK: - The floating field

    /// Show the floating field for `paneID`. An open field for another pane
    /// is replaced without finishing it: the keyboard is about to belong to
    /// the new field, and handing it back to the old pane's terminal would
    /// take it away again.
    func open(paneID: UUID, name: String, anchor: CGRect) {
        request = Request(id: UUID(), paneID: paneID, name: name, anchor: anchor)
    }

    /// The floating field ended, by commit or cancel. Returns the request it
    /// ended, so the host can hand the keyboard back to that pane; nil for a
    /// request that has already been replaced or closed.
    @discardableResult
    func finish(requestID: UUID) -> Request? {
        guard let current = request, current.id == requestID else { return nil }
        request = nil
        return current
    }

    /// `paneID`'s header left the screen — the pane closed, its tab was
    /// switched away, or another pane was zoomed. Its floating field goes
    /// without committing, the keyboard stays where it is because the pane
    /// it would return to is not on screen, and an ask it never took is
    /// dropped rather than kept for a header that might mount later.
    func headerDisappeared(paneID: UUID) {
        if request?.paneID == paneID {
            request = nil
        }
        if pendingRename?.paneID == paneID {
            pendingRename = nil
        }
    }

    /// The header moved or resized. No-op unless it owns the open field.
    func updateAnchor(paneID: UUID, anchor: CGRect) {
        guard var current = request, current.paneID == paneID, current.anchor != anchor else { return }
        current.anchor = anchor
        request = current
    }

    // MARK: - Placement

    /// Where the floating panel's top-leading corner goes, in the same
    /// coordinates as `anchor` and `container`. Its leading edge follows the
    /// header's, pulled inside the window by `margin`. It hangs `gap` below
    /// the header, or sits that far above it when below would run past the
    /// window's bottom; when neither fits, it is pinned inside the bottom.
    /// Whatever the branch, the result is kept within `margin` of the
    /// window's top and bottom, so an anchor that has scrolled or been laid
    /// out off screen cannot take the panel with it.
    nonisolated static func panelOrigin(
        anchor: CGRect,
        panelSize: CGSize,
        container: CGSize,
        margin: CGFloat,
        gap: CGFloat
    ) -> CGPoint {
        let maximumX = container.width - panelSize.width - margin
        let x = maximumX >= margin ? min(max(anchor.minX, margin), maximumX) : margin

        let below = anchor.maxY + gap
        let above = anchor.minY - gap - panelSize.height
        let maximumY = container.height - panelSize.height - margin
        let y: CGFloat = if below <= maximumY {
            below
        } else if above >= margin {
            above
        } else {
            max(margin, maximumY)
        }
        return CGPoint(x: x, y: min(max(y, margin), max(margin, maximumY)))
    }
}
