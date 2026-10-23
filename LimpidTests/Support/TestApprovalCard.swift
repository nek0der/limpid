// TestApprovalCard.swift
// Limpid — one window's approval card over a store, for suites that test the card rather than which window shows it.

import CoreGraphics
import Foundation
@testable import Limpid

/// One window's card over `store`, kept settled as the app keeps every
/// window's (`WindowRegistry.settleApprovalCards`). Each window has its own
/// card; most suites test what a card does, not which window it is
/// in, so they act on one through this. A suite about windows uses each
/// window's `approvalCard` and settles them through its registry.
@MainActor
final class TestApprovalCard {
    let store: ApprovalPresentationStore
    let card = WindowApprovalCard()

    init(_ store: ApprovalPresentationStore) {
        self.store = store
        store.onRequestsChanged = { [weak store, card] in
            guard let store else { return }
            card.settle(against: store)
        }
    }

    func present(_ approval: ApprovalPresentation, shouldFocusCard: Bool = true) {
        card.present(approval, from: store, shouldFocusCard: shouldFocusCard)
    }

    func dismissCard() {
        card.dismiss()
    }

    func cardFocusChanged(_ focused: Bool, for approval: ApprovalPresentation) {
        card.focusChanged(focused, for: approval)
    }

    func cardFocusRequestCompleted(for approval: ApprovalPresentation) {
        card.focusRequestCompleted(for: approval)
    }

    func updateRowAnchor(_ rect: CGRect, for approval: ApprovalPresentation) {
        card.updateRowAnchor(rect, for: approval, in: store)
    }

    func rowAnchor(for approval: ApprovalPresentation) -> CGRect? {
        card.rowAnchor(for: approval)
    }

    var presentedApproval: ApprovalPresentation? {
        card.presentedApproval(in: store)
    }

    var isCardOpen: Bool {
        card.isOpen(in: store)
    }

    var isCardFocused: Bool {
        card.isFocused
    }

    var presentedID: String? {
        card.state.presentedID
    }

    var cardFocusRequestID: String? {
        card.state.cardFocusRequestID
    }
}
