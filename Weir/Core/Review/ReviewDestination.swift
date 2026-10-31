// ReviewDestination.swift
// Weir — the pane the assembled feedback is pasted into.

import Foundation
import WeirDomain

/// The one thing review needs from the pane it writes to.
///
/// A protocol rather than a method on `SurfaceView`, so no UI type sits in
/// the middle of the delivery path and the path can be exercised without a
/// real surface and a live libghostty. What crosses the boundary is this
/// sentence: take this text, and say if you could not.
@MainActor
protocol ReviewTextDelivering {
    /// Hands the prompt to the terminal. Throws when the paste could not be
    /// started; a paste that was started and then refused answers later,
    /// through the receipt.
    func deliverReviewText(_ prompt: ReviewPrompt, receipt: ReviewPasteReceipt?) throws

    /// Whether the terminal would take a review now
    /// (`ReviewPasteReadiness.isReady`).
    var isReadyForReviewPaste: Bool { get }

    /// Whether libghostty has made the pane's surface yet.
    var hasTerminalSurface: Bool { get }
}

/// When a pane can take a review's paste. Its view is registered before
/// libghostty makes its surface, and a restored pane types the command it
/// was staged with (`claude --resume …`) a moment after that: a paste before
/// then reaches the shell, which would run each of its lines. Even once it
/// is typed, the program takes the terminal some time later and turns its
/// bracketed paste on later still; a paste in that gap arrives unbracketed,
/// and the agent reads each line as a message of its own.
enum ReviewPasteReadiness {
    /// A restored pane's staged command, as far as it has got.
    struct StagedCommand: Equatable {
        /// When it was typed at the shell; nil while it waits for the
        /// shell's prompt.
        var typedAt: ContinuousClock.Instant?
        /// When the shell was first seen away from its prompt after that:
        /// the command's program took the terminal
        /// (`AgentForeground.isShellAtPrompt`). Nil until then.
        var startedAt: ContinuousClock.Instant?
    }

    /// How long a program that took the terminal is given to set it up
    /// (raw mode, bracketed paste) before a paste goes to it. The agents'
    /// TUIs do it as they draw their first screen; no event says when.
    static let startSettle: Duration = .milliseconds(500)
    /// How long after it was typed a staged command holds the pane while
    /// the shell is still seen at its prompt: one that ran and came back
    /// before anyone looked, or failed at once, is not waited for longer.
    static let startLimit: Duration = .milliseconds(2500)

    /// The surface is there, and the staged command, if the pane has one,
    /// was typed and its program has had the terminal for `startSettle`,
    /// or `startLimit` has passed since it was typed.
    static func isReady(hasSurface: Bool, stagedCommand: StagedCommand?, now: ContinuousClock.Instant) -> Bool {
        guard hasSurface else { return false }
        guard let stagedCommand else { return true }
        guard let typedAt = stagedCommand.typedAt else { return false }
        if let startedAt = stagedCommand.startedAt, now - startedAt >= startSettle {
            return true
        }
        return now - typedAt >= startLimit
    }

    /// Whether the shell is still to be watched for leaving its prompt: the
    /// command was typed, has not been seen starting, and the limit has not
    /// passed, after which nothing more is learned by looking.
    static func watchesForStart(_ stagedCommand: StagedCommand?, now: ContinuousClock.Instant) -> Bool {
        guard let stagedCommand, let typedAt = stagedCommand.typedAt, stagedCommand.startedAt == nil else { return false }
        return now - typedAt < startLimit
    }

    /// Whether an insert waiting for the pane brings its tab on screen: a
    /// surface is made only for a view in a window, and a view made while
    /// its tab was in front, then switched away from before it reached one,
    /// is registered with none. A pane whose surface is there is only
    /// waited for, without moving the review behind it.
    static func bringsTabForward(hasView: Bool, hasSurface: Bool) -> Bool {
        !hasView || !hasSurface
    }
}

/// Review pastes into one pane, and does not gate on what that pane is
/// doing.
///
/// What arrives depends on the program. One that asked for bracketed paste —
/// an agent composer, or an interactive shell's line editor — receives a framed
/// block, and nothing runs until the reader says so. One that did not ask gets
/// an unbracketed paste, which turns newlines into carriage returns; there the
/// confirmation sheet is what stands between a quoted diff and a shell running
/// it line by line.
///
/// Insert does not wait for an agent badge to say idle, or for the agent to
/// own the surface's terminal: both are wrong often enough — a stuck badge, a
/// pane hosted in tmux — that the button would mostly sit disabled. What the
/// reader actually needs is to see where the text goes and what is in front
/// there, which is what this carries.
struct ReviewDestination: Equatable {
    let paneID: UUID
    /// The agent in that pane; failing that the worktree's own directory name,
    /// and only as a last resort the tab's title — which for a pane hosted in
    /// tmux is a line of `attach -t` arguments.
    let title: String
    /// The command in the foreground of the terminal the text will reach.
    /// `nil` until the first probe answers, and whenever it cannot be resolved.
    var foreground: String?
    /// The agent the pane hosts, `nil` for a shell. The decision bar names
    /// the agent by kind, as its other lines do, rather than by this title,
    /// which for a pane hosted in tmux is the worktree's directory.
    var agent: AgentKind?
    /// Whether the pane's terminal would take the text now
    /// (`ReviewPasteReadiness`). A pane restored into a tab not shown since
    /// has none yet, as a surface is made only for a tab on screen; it is
    /// still a destination, started when the text goes to it
    /// (`ReviewInsertion.Target.startPane`).
    var isLive = true
}

/// Which destination probe is the current one.
///
/// Two things start a probe — the two-second poll and a pane switch — and
/// they overlap. The pane id alone cannot tell them apart when both look at
/// the same pane, so an older probe finishing last would put its answer
/// back on screen.
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
/// The paste action returns as soon as the request starts; the answer — the
/// text reached the terminal, or the reader refused it at the confirmation
/// sheet — comes later, through whichever clipboard callback has the receipt
/// then. The `settlement` is how that answer gets back to the insert, which
/// marks the comments and closes the review tab only once it has.
struct ReviewPasteReceipt {
    let root: URL
    let commentIDs: [UUID]
    /// The insert waiting for the paste's answer; `nil` for a paste nothing
    /// waits on. Fixed for the paste's life: a receipt moves between the
    /// clipboard callbacks whole, and nothing takes over the wait.
    let settlement: ReviewPasteSettlement?

    init(root: URL, commentIDs: [UUID], settlement: ReviewPasteSettlement? = nil) {
        self.root = root
        self.commentIDs = commentIDs
        self.settlement = settlement
    }
}
