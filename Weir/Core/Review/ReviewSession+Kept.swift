// ReviewSession+Kept.swift
// Weir — a review kept while nothing draws it: its stack let go of, and the comment being written held for it.

import Foundation

extension ReviewSession {
    /// Lets go of what the stacked diff has read, and of the reads under
    /// way, while the review is kept with nothing to draw it: a review tab
    /// kept for its project reads its list again as it comes back, and the
    /// files are read again from there. The open file, the comments, the
    /// comment being written, and the read marks stay.
    func releaseStack() {
        stackLoader.release(listed: files)
    }

    /// The review is drawn again: its stack reads as asked from now on,
    /// whether or not its next read of the list succeeds.
    func resumeStack() {
        stackLoader.resume()
    }

    /// Whether the composer holds text the person would lose: a new comment
    /// with text, or a saved one rewritten into something else. A saved
    /// comment opened to rewrite and left as it was loses nothing.
    var composerHoldsUnsavedText: Bool {
        guard composer.hasUnsavedText else { return false }
        guard let id = composer.editingCommentID else { return true }
        return !ReviewComposerFollow.isUnchangedEdit(composer, savedBody: comments.first { $0.id == id }?.body)
    }

    /// Whether the review holds a comment the person has not saved or let
    /// go of: in the composer, or set aside in the banner.
    var holdsComment: Bool {
        composerHoldsUnsavedText || unplacedComment != nil
    }

    /// Moves the text of the comment being written to the banner and closes
    /// the composer: the review cannot show it where it was written (its
    /// code went, or the review cannot open at all). A comment already
    /// there is kept above it.
    func setComposerAside() {
        // A saved comment opened and left as it was loses nothing: it closes.
        guard composerHoldsUnsavedText else {
            composer.cancel()
            return
        }
        unplacedComment = [unplacedComment, composer.text].compactMap(\.self).joined(separator: "\n\n")
        composer.cancel()
    }
}
