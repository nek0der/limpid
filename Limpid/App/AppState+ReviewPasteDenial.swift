// AppState+ReviewPasteDenial.swift
// Limpid — what happens when a review paste is refused at the
// clipboard confirmation sheet.

import Foundation

extension AppState {
    /// A paste the user refused at the confirmation sheet delivered nothing,
    /// but review has already recorded the comments as inserted and usually
    /// closed. The store is reached through the pool rather than through the
    /// surface that was showing it.
    func configureReviewPasteDenial() {
        clipboardConfirmation.onReviewPasteDenied = { [reviewStores, toastCenter] receipt in
            reviewStores.store(root: receipt.root).unmarkInserted(receipt.commentIDs)
            // Said out loud, because the refusal arrives after review has told
            // the reader it went and usually after review has closed. Without
            // this the only two paths that refuse — the confirmation sheet,
            // and a second request arriving while one is already up — took the
            // comments back in silence.
            toastCenter.show(ToastItem(
                message: String(localized: "Review was not delivered. The comments stay in this review."),
                undo: nil
            ))
        }
    }
}
