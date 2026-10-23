// ReviewPasteDelivery.swift
// Limpid — one review paste, from the moment it leaves the surface until
// something says what became of it.

import Foundation

/// What became of one review paste, for the insert that is waiting on it.
///
/// The paste action answers as soon as libghostty's clipboard read starts,
/// not when the text reaches the terminal: a paste the program did not ask
/// for bracketed goes through the confirmation sheet first, and the reader's
/// answer there comes much later. Taking the action's answer for the
/// paste's, the insert would have marked the comments and closed the review
/// tab by the time a refusal arrived — and a refusal can take the marks
/// back, but not reopen the tab. This is what lets the insert wait for
/// the paste's own answer instead.
///
/// Answered once: the first answer stands, so a delivery that is claimed and
/// then dropped does not change its mind.
@MainActor
final class ReviewPasteSettlement {
    /// Whether the text reached the terminal; `nil` while nothing has said.
    private(set) var wasDelivered: Bool?
    /// The one insert waiting; `nil` until it asks, and after it is answered.
    private var waiter: CheckedContinuation<Bool, Never>?

    init() {}

    /// The paste reached the terminal (`wasDelivered`) or did not (refused
    /// at the sheet, dropped with its pane, or never claimed).
    func settle(wasDelivered: Bool) {
        guard self.wasDelivered == nil else { return }
        self.wasDelivered = wasDelivered
        waiter?.resume(returning: wasDelivered)
        waiter = nil
    }

    /// Whether the text reached the terminal, waiting for the answer when it
    /// has not come yet. Not cancellable: the paste is already on its way, and
    /// the insert that started it owes the reader its outcome.
    func landed() async -> Bool {
        if let wasDelivered {
            return wasDelivered
        }
        // Nothing can answer between the read above and here: both run on
        // the main actor with no suspension between them, so the waiter is
        // parked unconditionally.
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// A paste that has been started and not yet answered for.
///
/// An object rather than a value passed between early returns, each of
/// which would have to remember to report a delivery that never happened —
/// and the one failure a reader cannot see is a comment marked as inserted
/// when nothing arrived. This makes the reporting the default: a delivery
/// that is dropped without anyone claiming it says so.
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

    /// The text reached the terminal. The insert waiting on it may go on.
    func landed() {
        receipt?.settlement?.settle(wasDelivered: true)
        isSettled = true
        receipt = nil
    }

    /// Ownership moves to whoever answers next — the confirmation sheet, which
    /// settles the receipt with the reader's answer.
    func handedOn() -> ReviewPasteReceipt? {
        defer {
            isSettled = true
            receipt = nil
        }
        return receipt
    }

    /// Settle a paste nobody claimed as refused. Idempotent, so a `defer` can
    /// call it on every path including the ones that already answered.
    func failIfUnsettled() {
        guard !isSettled, let receipt else { return }
        isSettled = true
        self.receipt = nil
        receipt.settlement?.settle(wasDelivered: false)
    }
}

/// We keep refusal ownership separate from the AppKit view and the C request.
@MainActor
final class ReviewPasteLedger {
    /// Absent when no confirmation is pending, including non-review requests.
    private var pending: ReviewPasteDelivery?

    init() {}

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
