// ReviewDestination.swift
// Limpid — the pane the assembled feedback is pasted into.

import Foundation

/// Review pastes into the pane docked below it, and does not gate on what
/// that pane is doing. A tab holding more than one pane offers a switcher in
/// the strip header; the destination is otherwise the pane the reader is
/// already looking at.
///
/// What arrives depends on the program. One that asked for bracketed paste —
/// an agent composer, or an interactive shell's line editor — receives a framed
/// block, and nothing runs until the reader says so. One that did not ask gets
/// an unbracketed paste, which turns newlines into carriage returns; there the
/// confirmation sheet is what stands between a quoted diff and a shell running
/// it line by line.
///
/// The previous shape refused to insert unless an agent badge said idle and
/// the agent owned the surface's terminal. Both conditions were wrong often
/// enough — a stuck badge, a pane hosted in tmux — that the button mostly sat
/// disabled. What the reader actually needs is to see where the text goes and
/// what is in front there, which is what this carries.
/// The one thing review needs from the pane it writes to.
///
/// Core used to reach a method defined on `SurfaceView`, which put a UI type
/// in the middle of the delivery path and meant nothing on that path could be
/// exercised without a real surface and a live libghostty. What crosses the
/// boundary is this sentence: take this text, and say if you could not.
@MainActor
protocol ReviewTextDelivering {
    /// Hands the prompt to the terminal. Throws when the paste could not be
    /// started; a paste that was started and then refused answers later,
    /// through the receipt.
    func deliverReviewText(_ prompt: ReviewPrompt, receipt: ReviewPasteReceipt?) throws
}

struct ReviewDestination: Equatable {
    let paneID: UUID
    /// The agent in that pane; failing that the worktree's own directory name,
    /// and only as a last resort the tab's title — which for a pane hosted in
    /// tmux is a line of `attach -t` arguments.
    let title: String
    /// The command in the foreground of the terminal the text will reach.
    /// `nil` until the first probe answers, and whenever it cannot be resolved.
    var foreground: String?
}

/// Which destination probe is the current one.
///
/// Three things start a probe — the two-second poll, a pane switch, and the
/// strip being collapsed or expanded — and they overlap. The pane id alone
/// cannot tell them apart when they are all looking at the same pane, so an
/// older probe finishing last would put its answer back on screen.
///
/// A plain class rather than observable state: a token that changed every two
/// seconds would invalidate the surface every two seconds, which is the cost
/// this is meant to avoid.
@MainActor
final class ReviewProbeToken {
    private var current = UUID()

    func begin() -> UUID {
        current = UUID()
        return current
    }

    func isCurrent(_ token: UUID) -> Bool {
        current == token
    }
}

/// What a review paste was carrying, kept until libghostty answers for it.
///
/// The paste action returns as soon as the request starts, so a refusal at the
/// confirmation sheet arrives after review has already recorded the comments as
/// inserted, and usually closed itself. This is what lets a refusal find them
/// again.
struct ReviewPasteReceipt {
    let root: URL
    let commentIDs: [UUID]
}
