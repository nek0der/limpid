// ReviewInsertion.swift
// Weir — handing a review's comments to the pane below it.

import Foundation
import WeirDomain

/// The order the insert has to happen in, away from the view that starts it.
///
/// Three rules travel together here, and each one is a bug if it moves: the
/// destination is resolved twice because Git answers slowly enough for the
/// reader to switch panes inside the gap; the comments are marked only after
/// the pane took the text, which the paste says through its receipt rather
/// than the paste action's return; and the receipt names only the comments
/// this insert is marking. Left in a view, they belonged to that view's
/// lifetime — and a second way in (a menu item, the palette) would have had
/// to restate them.
enum ReviewInsertion {
    /// What the surface needs to know afterwards, and nothing about how it is
    /// drawn.
    struct Outcome {
        /// The pane the text reached.
        let paneID: UUID
        /// The agent the pane hosts, for the decision bar's sentence that
        /// says where the comments went; `nil` for a shell, whose pane has
        /// no bar.
        let agent: AgentKind?
        /// How many comments were left behind because the worktree moved past
        /// them. They stay in the review, and the banner names them.
        let held: Int
        /// How many comments that went out were edited elsewhere before the
        /// paste landed. They stay unmarked, as what the agent got is not
        /// what they say now (`ReviewSession.markInserted`).
        let changed: Int
        /// Whether the insert could be written into the draft. False means the
        /// text arrived but this review will not remember that it did.
        let wasRecorded: Bool

        /// Whether there is nothing left for the reader to see here.
        ///
        /// We name this on the outcome rather than have the caller work it out: the
        /// things that make an insert incomplete are read in different
        /// places — a toast names what was held back, the banner says the
        /// record failed, a comment edited meanwhile still reads as not
        /// inserted — and each needs the review still on screen. A caller
        /// that closed on delivery alone took the explanation with it.
        ///
        /// Not an enum: a partial insert can also fail to record, and cases
        /// that cannot hold both would either lose one or multiply.
        var isComplete: Bool {
            held == 0 && changed == 0 && wasRecorded
        }
    }

    /// Where the text is going, and what it should say. One value rather than
    /// four arguments: they arrive together and mean nothing apart.
    @MainActor
    struct Target {
        let session: WorkspaceSession
        let registry: any SurfaceViewProviding
        /// The pane review was opened over, which is the one it writes to.
        ///
        /// Read through a closure rather than captured: the surface can be
        /// retargeted while Git answers, and a value taken before that wait
        /// makes the check afterwards compare a number to itself.
        let originPaneID: () -> UUID?
        /// The reader's own opening, empty for the default.
        let instructions: String
        /// The app locale, which the default opening is written in.
        let locale: Locale
        /// Whether this is still the review the insert was started from.
        /// Checked after the repository answers, because the reader can close
        /// it — and open it again — inside that wait.
        let isSameReview: () -> Bool
        /// Starts the terminal of a pane that has none yet (one restored
        /// into a tab not shown since), and says whether it got ready for
        /// the paste (`ReviewPasteReadiness`): the window brings the pane's
        /// tab forward a moment, since a surface is made only for a tab on
        /// screen. Without it such a pane takes nothing.
        var startPane: @MainActor (UUID) async -> Bool = { _ in false }
    }

    /// Resolves, builds, delivers and records — in that order.
    ///
    /// Throws `targetUnavailable` when the pane the reader pressed Insert in
    /// is no longer the pane that would receive the text, and `pasteRefused`
    /// when the paste was started and the terminal did not take it.
    @MainActor
    static func run(reviewSession: ReviewSession, to target: Target) async throws -> Outcome {
        let session = target.session
        let registry = target.registry
        // Resolved here rather than read from the chip: that one is refreshed
        // on a two-second poll, and a pane switch inside that window would
        // have pasted into the pane the reader just left.
        guard let pressed = ReviewAgents.destination(
            session: session,
            paneID: target.originPaneID(),
            registry: registry
        ) else { throw ReviewError.targetUnavailable }
        let root = reviewSession.root
        let comments = reviewSession.shownComments
        // Line numbers age with the worktree. Inserting a comment that points
        // at code which has since moved is worse than refusing: the agent
        // would edit the wrong lines with full confidence. Only the comments
        // that still match go into the prompt; the rest stay in the draft and
        // are called out on screen.
        let sending = try await reviewSession.insertable(comments)
        // A pane with no terminal yet, or one still typing the command it
        // was restored with, is waited for first.
        if !pressed.isLive, await !target.startPane(pressed.paneID) {
            throw ReviewError.paneDidNotStart
        }
        // Resolved again after the await, and asked of the surface rather than
        // of a value taken before it: the check runs Git once per commented
        // file, the reader can switch pane or close the one we were about to
        // write to in that time, and writing a review into the pane they left
        // is worse than refusing.
        guard target.isSameReview(),
              let destination = ReviewAgents.destination(
                  session: session,
                  paneID: target.originPaneID(),
                  registry: registry
              ), destination.paneID == pressed.paneID, destination.isLive
        else { throw ReviewError.targetUnavailable }
        // The prompt names the worktree it was written against. A container-
        // owned review therefore does not require its pane to be sitting in it.
        let prompt = try ReviewPromptBuilder.build(
            root: root,
            comments: sending,
            instructions: target.instructions,
            locale: target.locale
        )
        let settlement = ReviewPasteSettlement()
        try ReviewAgents.insert(
            prompt,
            into: destination,
            registry: registry,
            receipt: ReviewPasteReceipt(
                root: root,
                commentIDs: sending.filter { $0.insertedAt == nil }.map(\.id),
                settlement: settlement
            )
        )
        // The paste action answers when the clipboard read starts, not when
        // the text arrives. A program that has not asked for bracketed paste
        // yet (a shell this insert just started) gets the confirmation sheet
        // first, and the reader can refuse there. Marking and closing on the
        // action's answer put the tab away before that refusal came, and a
        // refusal could unmark the comments but not bring the tab back.
        // So the insert waits for the paste's own answer: refused, nothing
        // is marked and the review stays as it was, destination included.
        guard await settlement.landed() else { throw ReviewError.pasteRefused }
        // Cleared before the mark, not after: the write can fail, and that
        // message is the only trace of a delivery this review will not
        // remember making.
        reviewSession.clearError()
        // Marked from what went into the prompt, not from what is on screen: a
        // stale comment was held back, and recording it as delivered would
        // tell the reader it had been asked for. We also mark each comment
        // only as it was sent: marking one edited in another window during
        // the paste's wait would say its new text was sent, which it was not.
        let marked = reviewSession.markInserted(sending)
        return Outcome(
            paneID: destination.paneID,
            agent: destination.agent,
            held: comments.count(where: { !$0.isResolved }) - sending.count,
            changed: marked.changed,
            wasRecorded: marked.wasRecorded
        )
    }
}
