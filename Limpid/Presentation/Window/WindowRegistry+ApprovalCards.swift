// WindowRegistry+ApprovalCards.swift
// Limpid — every window's approval card following the requests the windows share.

import Foundation

extension WindowRegistry {
    /// Every window's approval card follows the requests as they move
    /// (`ApprovalPresentationStore.onRequestsChanged`): one whose request is
    /// settled closes, and the frames of rows no longer known go.
    func settleApprovalCards(against approvals: ApprovalPresentationStore) {
        for window in windows {
            window.approvalCard.settle(against: approvals)
        }
    }
}
