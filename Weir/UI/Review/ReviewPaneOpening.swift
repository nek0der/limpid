// ReviewPaneOpening.swift
// Weir — which review a review surface draws once its worktree is resolved, and what happens to a comment when none can be drawn.

import Foundation

/// Which review `ReviewPane` draws once Git has named the worktree.
///
/// The window's review tab draws its own review and no other: the comment
/// being written lives in that review (`ReviewSession.composer`), and the
/// window counts only that one when it decides whether the tab can close,
/// be replaced, or go with its project. A review from the pool drawn in its
/// place would take a comment the window never sees, and lose it on the
/// next of those. So where the tab's worktree no longer resolves to its
/// review's (moved into another repository, gone), the tab cannot open; the
/// surface then sets its comment aside in the banner the failure screen
/// draws (`ReviewSession.setComposerAside`, `ReviewPane`), which lets the
/// tab close once the text is copied or thrown away.
@MainActor
enum ReviewPaneOpening {
    enum Choice {
        /// The review kept for the surface.
        case kept(ReviewSession)
        /// No review: the screen says why.
        case cannotOpen(DisplayText)
    }

    static func choose(kept: ReviewSession, resolved: Result<URL, any Error>) -> Choice {
        switch resolved {
        case let .failure(error):
            return .cannotOpen(DisplayText(error: error))
        case let .success(root):
            guard kept.root.standardizedFileURL.path == root.standardizedFileURL.path else {
                return .cannotOpen(DisplayText(error: ReviewError.worktreeMoved))
            }
            return .kept(kept)
        }
    }
}
