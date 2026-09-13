// ReviewInsertion.swift
// Limpid — handing a review's comments to the pane below it.

import Foundation

/// The order the insert has to happen in, away from the view that starts it.
///
/// Three rules travel together here, and each one is a bug if it moves: the
/// destination is resolved twice because Git answers slowly enough for the
/// reader to switch panes inside the gap; the comments are marked only after
/// the pane took the text; and the receipt names only the comments this insert
/// is marking, so a later refusal cannot unmark a delivery that did happen.
/// Left in a view, they belonged to that view's lifetime — and a second way in
/// (a menu item, the palette) would have had to restate them.
enum ReviewInsertion {
    /// What the surface needs to know afterwards, and nothing about how it is
    /// drawn.
    struct Outcome {
        /// The pane the text reached.
        let paneID: UUID
        /// How many comments were left behind because the worktree moved past
        /// them. They stay in the review, and the banner names them.
        let held: Int
        /// Whether the insert could be written into the draft. False means the
        /// text arrived but this review will not remember that it did.
        let wasRecorded: Bool

        /// Whether there is nothing left for the reader to see here.
        ///
        /// Named on the outcome rather than worked out by the caller: the two
        /// things that make an insert incomplete are read in two different
        /// places — a toast names what was held back, the banner says the
        /// record failed — and both need the review still on screen. A caller
        /// that closed on delivery alone took the explanation with it.
        ///
        /// Not an enum: a partial insert can also fail to record, and cases
        /// that cannot hold both would either lose one or multiply.
        var isComplete: Bool {
            held == 0 && wasRecorded
        }
    }

    /// Where the text is going, and what it should say. One value rather than
    /// four arguments: they arrive together and mean nothing apart.
    @MainActor
    struct Target {
        let session: WindowSession
        let registry: any SurfaceViewProviding
        /// The pane review was opened over, which is the one it writes to.
        ///
        /// Read through a closure rather than captured: the surface can be
        /// retargeted while Git answers, and a value taken before that wait
        /// makes the check afterwards compare a number to itself.
        let originPaneID: () -> UUID?
        /// The reader's own opening, empty for the default.
        let instructions: String
        /// Whether this is still the review the insert was started from.
        /// Checked after the repository answers, because the reader can close
        /// it — and open it again — inside that wait.
        let isSameReview: () -> Bool
        /// Transient Quick Tab and Group reviews belong to the repository the
        /// owner pane was in when they opened. Project and worktree reviews do
        /// not: their container remains authoritative when a shell runs a
        /// command elsewhere.
        var requiresMatchingRepository = false
        /// Whether repository validation must ask the tmux server for the
        /// hosted pane's path instead of trusting the outer surface's OSC 7.
        var isTmuxHosted = false
    }

    /// Resolves, builds, delivers and records — in that order.
    ///
    /// Throws `targetUnavailable` when the pane the reader pressed Insert in
    /// is no longer the pane that would receive the text.
    @MainActor
    static func run(store: ReviewStore, to target: Target) async throws -> Outcome {
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
        let root = store.root
        let comments = store.comments
        // Line numbers age with the worktree. Inserting a comment that points
        // at code which has since moved is worse than refusing: the agent
        // would edit the wrong lines with full confidence. Only the comments
        // that still match go into the prompt; the rest stay in the draft and
        // are called out on screen.
        let sending = try await store.insertable(comments)
        if target.requiresMatchingRepository {
            guard let paneID = target.originPaneID() else { throw ReviewError.targetUnavailable }
            let path = await ReviewAgents.insertionWorkingDirectory(
                session: session,
                paneID: paneID,
                registry: registry,
                isTmuxHosted: target.isTmuxHosted
            )
            guard let path else { throw ReviewError.targetUnavailable }
            let paneRoot = try? await ReviewGit.root(at: URL(fileURLWithPath: path))
            let currentPath = await ReviewAgents.insertionWorkingDirectory(
                session: session,
                paneID: paneID,
                registry: registry,
                isTmuxHosted: target.isTmuxHosted
            )
            guard currentPath == path,
                  paneRoot?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath()
            else { throw ReviewError.targetUnavailable }
        }
        // Resolved again after the await. The check runs Git once per
        // commented file, and in that time the reader can switch pane or close
        // the one we were about to write to. Project and worktree review may
        // still deliver while their shell is elsewhere because the container
        // owns their repository; transient review has already revalidated its
        // owner repository above.
        // Asked again, and asked of the surface rather than of a value taken
        // before the wait: the reader can switch pane inside it, and writing a
        // review into the pane they left is worse than refusing.
        guard target.isSameReview(),
              let destination = ReviewAgents.destination(
                  session: session,
                  paneID: target.originPaneID(),
                  registry: registry
              ), destination.paneID == pressed.paneID
        else { throw ReviewError.targetUnavailable }
        // The prompt names the worktree it was written against. A container-
        // owned review therefore does not require its pane to be sitting in it.
        let prompt = try ReviewPromptBuilder.build(root: root, comments: sending, instructions: target.instructions)
        try ReviewAgents.insert(
            prompt,
            into: destination,
            registry: registry,
            // Only the ones this insert is marking. `sending` is the snapshot
            // taken before `markInserted`, so a comment that was already
            // delivered still reads as inserted here — and taking its mark
            // back on a later refusal would erase a delivery that did happen.
            receipt: ReviewPasteReceipt(
                root: root,
                commentIDs: sending.filter { $0.insertedAt == nil }.map(\.id)
            )
        )
        // Cleared before the mark, not after: the write can fail, and that
        // message is the only trace of a delivery this review will not
        // remember making.
        store.clearError()
        // Marked from what went into the prompt, not from what is on screen: a
        // stale comment was held back, and recording it as delivered would
        // tell the reader it had been asked for.
        let wasRecorded = store.markInserted(sending.map(\.id))
        return Outcome(
            paneID: destination.paneID,
            held: comments.count(where: { !$0.isResolved }) - sending.count,
            wasRecorded: wasRecorded
        )
    }
}
