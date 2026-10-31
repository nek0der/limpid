// ReviewComposerFollow.swift
// Weir — where a comment being written goes as the open file's diff, or the line selection, changes under it.

import Foundation

/// The one rule for a comment being written when the open file's diff
/// changes under it (`ReviewSession.composer`), whether the review stayed on
/// screen or came back after its window showed another project: the diff
/// is read again (a refresh of the work tree, a review that comes back),
/// or another file opens. Typed text is never dropped unseen.
enum ReviewComposerFollow {
    enum Outcome: Equatable {
        /// Nothing to do: no text, or the same diff.
        case kept
        /// The same comment on the same code, where the new diff has it.
        case moved(ReviewComposerState)
        /// Its text goes to the review's banner, to copy or throw away
        /// (`ReviewSession.setComposerAside`), and the composer closes.
        case setAside
        /// An existing comment opened to rewrite, its text unchanged: it
        /// closes, as nothing typed would be lost.
        case closed
    }

    /// Where `composer` goes as the open diff changes from `old` to `new`.
    /// `editedBody` is the saved text of the comment the composer rewrites,
    /// when it rewrites one.
    ///
    /// A new comment on the same file is placed on the code it quotes, by
    /// the rule a comment from an earlier review is moved by
    /// (`ReviewCommentRelocation`), so it never lands on other code under the
    /// same line numbers. It quotes the whole run, so the run comes back
    /// whole whatever its size; the cut a saved comment's quote gets
    /// (`ReviewSession.excerpt`) is for what is sent. Anywhere else it is
    /// set aside: another file, a quote no longer there or there twice, or
    /// no diff at all. So is an existing comment being rewritten with new
    /// text: the comment itself stays on the code it was written on, out of
    /// date, as it always has, and moving only its new text would save it
    /// somewhere the screen did not show. Opened and left as it was, it
    /// just closes.
    static func outcome(
        of composer: ReviewComposerState,
        from old: ReviewDiff?,
        to new: ReviewDiff?,
        editedBody: String? = nil
    ) -> Outcome {
        guard composer.hasUnsavedText, key(old) != key(new) else { return .kept }
        if composer.editingCommentID != nil {
            return isUnchangedEdit(composer, savedBody: editedBody) ? .closed : .setAside
        }
        guard let old, let new, old.file.id == new.file.id,
              let start = composer.startLineID, let end = composer.lineID
        else { return .setAside }
        let run = ReviewSession.commentRun(of: old.lines.filter { $0.id >= start && $0.id <= end }, side: composer.side)
        guard let first = run.first else { return .setAside }
        let quote = ReviewComment(
            file: old.file,
            fingerprint: old.fingerprint,
            anchor: ReviewAnchor(lineID: first.id, oldLine: first.oldLine, newLine: first.newLine),
            side: composer.side,
            code: run.map(\.text).joined(separator: "\n"),
            codeMarkers: String(run.map(\.kind.marker)),
            body: composer.text
        )
        guard case let .placed(placed) = ReviewCommentRelocation.placement(of: quote, in: new, scopeID: "") else {
            return .setAside
        }
        var moved = composer
        moved.move(start: placed.lineID, end: placed.lastLineID)
        return .moved(moved)
    }

    /// Whether `composer` rewrites a saved comment, `savedBody`, into the
    /// same text: nothing typed would be lost.
    static func isUnchangedEdit(_ composer: ReviewComposerState, savedBody: String?) -> Bool {
        guard composer.editingCommentID != nil, let savedBody else { return false }
        return savedBody.trimmingCharacters(in: .whitespacesAndNewlines)
            == composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a diff is to the composer: its file and its content.
    private static func key(_ diff: ReviewDiff?) -> String? {
        diff.map { $0.file.id + "|" + $0.fingerprint }
    }
}

/// What a change of the line selection does to the composer
/// (`ReviewWorkspaceView`): the run a comment is written on follows the
/// selection only while the selection is being extended from that run.
enum ReviewComposerSelection {
    enum Change: Equatable {
        /// The composer stays as it is.
        case keep
        /// It covers the new run.
        case retarget
        /// It closes: nothing typed is lost.
        case cancel
    }

    /// The change for a selection going from `old` to `new`, with
    /// `holdsText` when the composer holds text the person would lose
    /// (`ReviewSession.composerHoldsUnsavedText`).
    ///
    /// Without such text, a run still being extended (the same anchor)
    /// carries the composer along, and a click elsewhere is the reader
    /// leaving: the composer closes, unless it rewrites a saved comment, or
    /// was opened for this run in the same keystroke (`c` on dragged text).
    /// With it, the composer never moves to lines it was not written on:
    /// only a run extended from exactly the composer's own carries it, and
    /// a click elsewhere, or an extension from there, leaves it where it is,
    /// as a file is not opened over it either.
    static func change(
        of composer: ReviewComposerState,
        holdsText: Bool,
        from old: ReviewSelection,
        to new: ReviewSelection
    ) -> Change {
        guard let start = new.startLineID, let end = new.endLineID else { return .keep }
        let isSameAnchor = old.anchorLineID == new.anchorLineID
        if holdsText {
            let wasOnComposer = old.startLineID == composer.startLineID && old.endLineID == composer.lineID
            return composer.editingCommentID == nil && isSameAnchor && wasOnComposer ? .retarget : .keep
        }
        let isComposingNewRun = composer.startLineID == start && composer.lineID == end
        if !isSameAnchor, composer.editingCommentID == nil, !isComposingNewRun {
            return .cancel
        }
        return .retarget
    }
}
