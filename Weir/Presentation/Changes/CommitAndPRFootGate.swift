// CommitAndPRFootGate.swift
// Weir — the changes panel's foot bar lets a press through only once its button has been there a moment.

import Foundation

/// The guard on the changes panel's foot bar. Its one button changes in
/// place: "Mark as Viewed" in the review clears the changes outside turns,
/// and "Show Current Diff" gives way to "Create PR" under the pointer. A
/// second press meant for the button before would then run
/// `gh pr create --fill` in a new tab at once, with nothing to confirm. So
/// a press counts only once the button it lands on has been shown for the
/// settle time, as ⌘⏎ waits on the decision bar.
struct CommitAndPRFootGate: Equatable {
    /// The shortest settle time: long enough to outlast a double press,
    /// short enough that a person reading the new button never meets it.
    static let minimumSettle: Duration = .milliseconds(500)

    private var shown: CommitAndPRModel.FootActionKind?
    private var shownAt: SuspendingClock.Instant?

    /// The settle time for a person whose two presses of a double click
    /// may stand `doubleClickInterval` seconds apart (the system's setting,
    /// which a slower hand sets to seconds): never shorter than
    /// `minimumSettle`.
    static func settle(doubleClickInterval: TimeInterval) -> Duration {
        max(minimumSettle, .milliseconds(Int((doubleClickInterval * 1000).rounded(.up))))
    }

    /// The bar now shows `kind`. A move of the same kind keeps its time:
    /// "Create PR" turning pressable once its block ends is no new button.
    mutating func noteShown(_ kind: CommitAndPRModel.FootActionKind?, at now: SuspendingClock.Instant) {
        guard kind != shown || shownAt == nil else { return }
        shown = kind
        shownAt = now
    }

    /// Whether a press on `kind` at `now` is meant for it: it is the button
    /// shown, and has been for `settle`.
    func accepts(_ kind: CommitAndPRModel.FootActionKind, at now: SuspendingClock.Instant, settle: Duration) -> Bool {
        guard kind == shown, let shownAt else { return false }
        return now - shownAt >= settle
    }
}
