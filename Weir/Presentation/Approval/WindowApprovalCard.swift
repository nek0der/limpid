// WindowApprovalCard.swift
// Weir — one window's approval card: which request it shows, where it was opened from, and its rows' frames.

import Foundation
import WeirDomain

/// What one window's approval card shows. Each window has its own
/// card, the rows it points from, and keyboard focus; the requests, their
/// ledger, and the unsent answers are shared (`ApprovalPresentationStore`).
struct ApprovalCardState: Equatable {
    /// The one request whose detail card is visible in the window.
    /// The card can outlive the request's place in the pending list: it
    /// follows the ledger (`ApprovalLedger.Entry.holdsCardOpen`).
    /// It never closes by itself when the pointer or the keyboard leaves:
    /// only on Escape, its close button, once its request is settled, when
    /// another request's card replaces it, when the window switches project
    /// while the card stands beside a row (`forgetRows`), or with its window.
    /// What it holds back from the rest of the window follows `isFocused`.
    var presentedID: String?
    /// A row click requests one hand-off of keyboard focus into the card.
    /// It is only that request: the card stays whether or not the focus
    /// ever arrived.
    var cardFocusRequestID: String?
    /// The control the card was opened from when that was not its row (the
    /// title bar's Needs Attention list), in global coordinates. The card
    /// stands beside it instead: the row may be off screen.
    var openedFrom: CGRect?
    /// Whether keyboard focus is in the card. Only then does the card act
    /// as the surface the person works in: it takes Escape, holds back ⌘⏎
    /// in its window, and keeps the window's small panels from opening.
    /// Without focus it is on screen only, and keys reach the terminal,
    /// where the person may be answering the very request the card shows.
    var isFocused = false
}

/// One window's approval card and the frames of its sidebar's request rows
/// (`ProjectWindowState.approvalCard`). Kept with the window rather than
/// with the requests, so a window that closes takes its card and its rows
/// with it, and a window switching project closes only its own card
/// (`forgetRows`).
/// Whether a card may show a request is the shared store's to say: each
/// method that needs to know takes the store as an argument.
@MainActor
@Observable
final class WindowApprovalCard {
    /// The card. Presentation state only; the broker remains the authority.
    private(set) var state = ApprovalCardState()
    /// Where each request's row is in this window, in global coordinates.
    /// Apart from `state`: rows report their frames while the sidebar
    /// scrolls, and the views that read only whether a card is up or
    /// focused must not be drawn again for each one.
    private var rowAnchors: [String: CGRect] = [:]

    private func update(_ change: (inout ApprovalCardState) -> Void) {
        var card = state
        change(&card)
        if card != state {
            state = card
        }
    }

    /// Opens the card on `approval`, when its request may still show one.
    /// `openedFrom` is the control the card was asked for from, when that is
    /// not the request's row (`ApprovalCardState.openedFrom`).
    func present(
        _ approval: ApprovalPresentation,
        from approvals: ApprovalPresentationStore,
        shouldFocusCard: Bool = true,
        openedFrom: CGRect? = nil
    ) {
        guard approvals.approvalForCard(approval.id) != nil else { return }
        update { card in
            card.openedFrom = openedFrom
            if card.presentedID == approval.id {
                if shouldFocusCard {
                    card.cardFocusRequestID = approval.id
                }
                return
            }
            card.isFocused = false
            card.presentedID = approval.id
            card.cardFocusRequestID = shouldFocusCard ? approval.id : nil
        }
    }

    func dismiss() {
        update { $0 = ApprovalCardState() }
    }

    /// Focus leaving a card closes nothing.
    func focusChanged(_ focused: Bool, for approval: ApprovalPresentation) {
        guard state.presentedID == approval.id else { return }
        update { card in
            card.isFocused = focused
            if focused {
                card.cardFocusRequestID = nil
            }
        }
    }

    func focusRequestCompleted(for approval: ApprovalPresentation) {
        guard state.cardFocusRequestID == approval.id else { return }
        update { $0.cardFocusRequestID = nil }
    }

    /// The request the card shows, while the card should stay open.
    func presentedApproval(in approvals: ApprovalPresentationStore) -> ApprovalPresentation? {
        state.presentedID.flatMap { approvals.approvalForCard($0) }
    }

    /// Whether the card shows the request `key` names: a row or a card that
    /// would open it hides its Answer… or marks itself as the card's source.
    func isPresenting(_ key: ApprovalKey, in approvals: ApprovalPresentationStore) -> Bool {
        presentedApproval(in: approvals)?.key == key
    }

    /// Whether the card is up.
    func isOpen(in approvals: ApprovalPresentationStore) -> Bool {
        presentedApproval(in: approvals) != nil
    }

    /// Whether keyboard focus is in the card.
    var isFocused: Bool {
        state.isFocused
    }

    func updateRowAnchor(_ rect: CGRect, for approval: ApprovalPresentation, in approvals: ApprovalPresentationStore) {
        guard approvals.isKnown(approval.id), rowAnchors[approval.id] != rect else { return }
        rowAnchors[approval.id] = rect
    }

    func rowAnchor(for approval: ApprovalPresentation) -> CGRect? {
        rowAnchors[approval.id]
    }

    /// Forgets the rows' frames: the sidebar went away, and a card pointing
    /// at a row off screen points at nothing.
    func clearRowAnchors() {
        if !rowAnchors.isEmpty {
            rowAnchors = [:]
        }
    }

    /// Closes a card standing beside a row as the window switches to
    /// another project: the person has moved on from that row. The
    /// rows' frames stay, as the sidebar lists every project's rows through
    /// a switch, and a row that does not move reports none again. A card
    /// opened from a control (`ApprovalCardState.openedFrom`) stands beside
    /// that control and stays. The request stays pending, and opens again
    /// from Needs Attention or its row.
    func forgetRows() {
        if state.presentedID != nil, state.openedFrom == nil {
            dismiss()
        }
    }

    /// The requests moved (`ApprovalPresentationStore.onRequestsChanged`):
    /// the card closes once its request is settled, and the frames of rows
    /// whose request the store no longer knows go. The card reads the same
    /// rule (`presentedApproval`), so this only drops the state behind a
    /// card that already shows nothing.
    func settle(against approvals: ApprovalPresentationStore) {
        if let presentedID = state.presentedID, approvals.approvalForCard(presentedID) == nil {
            dismiss()
        }
        let known = rowAnchors.filter { approvals.isKnown($0.key) }
        if known.count != rowAnchors.count {
            rowAnchors = known
        }
    }
}
