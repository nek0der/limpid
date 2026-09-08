// ReviewPasteDelivery.swift
// Limpid — one review paste, from the moment it leaves the surface until
// something says what became of it.

import Foundation

/// A paste that has been started and not yet answered for.
///
/// The receipt used to be a value passed between six early returns, each of
/// which had to remember to report a delivery that never happened — and the
/// one failure a reader cannot see is a comment marked as inserted when
/// nothing arrived. This makes the reporting the default: a delivery that is
/// dropped without anyone claiming it says so.
///
/// Settled exactly once. `landed` and `handedOn` claim it; `failIfUnsettled`
/// is what a `defer` calls on every way out, and does nothing once claimed.
@MainActor
final class ReviewPasteDelivery {
    private var receipt: ReviewPasteReceipt?
    private var isSettled: Bool

    init(receipt: ReviewPasteReceipt?) {
        self.receipt = receipt
        // A paste with no receipt is not a review paste; nothing to answer for.
        isSettled = receipt == nil
    }

    /// The text reached the terminal. Nothing is owed.
    func landed() {
        isSettled = true
        receipt = nil
    }

    /// Ownership moves to whoever answers next — the confirmation sheet, which
    /// reports its own refusal.
    func handedOn() -> ReviewPasteReceipt? {
        defer {
            isSettled = true
            receipt = nil
        }
        return receipt
    }

    /// Report a paste nobody claimed. Idempotent, so a `defer` can call it on
    /// every path including the ones that already answered.
    func failIfUnsettled() {
        guard !isSettled, let receipt else { return }
        isSettled = true
        self.receipt = nil
        ClipboardConfirmationCoordinator.reportReviewPasteDenied(receipt)
    }
}

/// We keep refusal ownership separate from the AppKit view and the C request.
@MainActor
final class ReviewPasteLedger {
    /// Absent when no confirmation is pending, including non-review requests.
    private var pending: ReviewPasteDelivery?

    func enqueue(receipt: ReviewPasteReceipt?) -> Bool {
        let delivery = ReviewPasteDelivery(receipt: receipt)
        guard pending == nil else {
            delivery.failIfUnsettled()
            return false
        }
        pending = delivery
        return true
    }

    func deny() {
        let delivery = pending
        pending = nil
        delivery?.failIfUnsettled()
    }

    func allow(paneIsAlive: Bool) {
        let delivery = pending
        pending = nil
        if paneIsAlive {
            delivery?.landed()
        } else {
            delivery?.failIfUnsettled()
        }
    }
}

@MainActor
protocol ReviewPasteStaging: AnyObject {
    var reviewPasteReceipt: ReviewPasteReceipt? { get set }
    func stagePaste(_ text: String)
    func takeStagedPaste() -> String?
    func takeReviewPasteReceipt() -> ReviewPasteReceipt?
}

@MainActor
enum ReviewPasteAttempt {
    static func deliver(
        _ prompt: ReviewPrompt, receipt: ReviewPasteReceipt?, staging: any ReviewPasteStaging, perform: () -> Bool
    ) throws {
        staging.reviewPasteReceipt = receipt
        staging.stagePaste(prompt.text)
        guard perform() else {
            _ = staging.takeStagedPaste()
            _ = staging.takeReviewPasteReceipt()
            throw ReviewError.targetUnavailable
        }
        // Clipboard type-listing requests can report success without reading text.
        // We require consumption in the synchronous callback before recording delivery.
        guard staging.takeStagedPaste() == nil else {
            _ = staging.takeReviewPasteReceipt()
            throw ReviewError.targetUnavailable
        }
    }
}
