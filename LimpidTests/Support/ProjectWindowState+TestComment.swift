// ProjectWindowState+TestComment.swift
// Limpid — a comment being written in a window's review tab, for tests that ask what the window does with it.

import Foundation
@testable import Limpid

extension ProjectWindowState {
    /// Writes `text` in the window's review, on lines 3–4, as the composer
    /// holds it (`ReviewSession.composer`): in a review of the window's own
    /// when it has none, reading `review`'s worktree. The review is what the
    /// tab keeps the comment in, and what goes with it.
    @discardableResult
    func writeComment(_ text: String = "Why this?") -> ReviewSession {
        let session = reviewSession ?? Self.reviewSession(root: review?.root ?? "/repo")
        reviewSession = session
        var composer = ReviewComposerState()
        composer.compose(start: 3, end: 4, side: nil)
        composer.text = text
        session.composer = composer
        return session
    }

    /// The comment is saved or thrown away: nothing is held any longer.
    func letGoOfComment() {
        reviewSession?.composer.cancel()
        reviewSession?.unplacedComment = nil
    }

    /// A review of `root` with a draft store of its own, which reads nothing
    /// from disk.
    static func reviewSession(root: String) -> ReviewSession {
        ReviewSession(root: URL(fileURLWithPath: root), drafts: RecordingReviewDraftStore())
    }
}
