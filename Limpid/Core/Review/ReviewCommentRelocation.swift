// ReviewCommentRelocation.swift
// Limpid — finds where a comment's quoted lines sit in another comparison, so it can move there.

import Foundation

/// Places a comment in another scope's diff by the code it quotes.
///
/// Moving a comment into a scope cannot rest on its fingerprint: the
/// fingerprint hashes the patch of the comparison it was written in, and a
/// different comparison (a fixed range of turns, where it was written
/// against "This turn") never produces the same patch, even over the same
/// code. What can be checked is the thing the comment is about: the lines it
/// quotes, each with its kind (added, removed, unchanged), appear in the
/// target's diff, together and in order. Only once, so the reader's choice
/// cannot land on the wrong copy of a repeated block.
enum ReviewCommentRelocation {
    /// Where `comment`'s quoted lines land in `diff`, or why they do not:
    /// nowhere, or in more than one place, which are different answers for
    /// the reader (write it again, or there is no telling which copy).
    enum Placement: Equatable {
        case placed(ReviewComment)
        case notFound
        case repeated
    }

    /// `comment` re-anchored on `diff`, in `scopeID`, with the target's
    /// fingerprint, when its quoted lines are there exactly once. A comment
    /// whose excerpt was cut short (`ReviewSession.excerpt`) covers the lines
    /// it kept.
    ///
    /// A comment taken in one column of the side-by-side layout quotes the
    /// lines that column draws, which are not next to each other in the
    /// unified order wherever the other column's lines sit between them (a
    /// context line, a removed one, an added one): it is looked for in that
    /// column's lines.
    static func placement(of comment: ReviewComment, in diff: ReviewDiff, scopeID: String) -> Placement {
        let texts = comment.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let markers = comment.codeMarkers.map(Array.init)
        let lines = comment.side.map { side in diff.lines.filter { ReviewSide.covers($0, on: side) } } ?? diff.lines
        guard !texts.isEmpty, texts.count <= lines.count, markers.map({ $0.count == texts.count }) ?? true else { return .notFound }
        var start: Int?
        for candidate in 0...(lines.count - texts.count) where matches(texts, markers, at: candidate, in: lines) {
            guard start == nil else { return .repeated }
            start = candidate
        }
        guard let start else { return .notFound }
        guard let span = ReviewAnchor.span(of: lines[start..<start + texts.count]) else { return .notFound }
        return .placed(ReviewComment(
            id: comment.id,
            scopeIDs: [scopeID],
            file: diff.file,
            fingerprint: diff.fingerprint,
            anchor: span.anchor,
            end: span.end,
            side: comment.side,
            code: comment.code,
            codeMarkers: comment.codeMarkers,
            body: comment.body,
            insertedAt: comment.insertedAt,
            resolvedAt: comment.resolvedAt
        ))
    }

    /// Whether the quote is at `start`, within one changed block: a column's
    /// lines leave out the blocks' headers, so the end of one block and the
    /// start of the next sit side by side there, and a comment never spans
    /// two (`ReviewSession.commentRun`).
    private static func matches(_ texts: [String], _ markers: [Character]?, at start: Int, in lines: [ReviewLine]) -> Bool {
        let hunkIndex = lines[start].hunkIndex
        for (offset, text) in texts.enumerated() {
            let line = lines[start + offset]
            guard line.isCommentable, line.text == text, line.hunkIndex == hunkIndex else { return false }
            if let markers, markers[offset] != line.kind.marker {
                return false
            }
        }
        return true
    }

    /// Whether the lines `comment` quotes from the new side (added and
    /// unchanged ones) are still in `current`, the file as it is now, at the
    /// line the comment names. A fixed range's diff never moves, so
    /// a match there says nothing about the code an agent would be asked to
    /// change today; and the prompt sends the comment's line numbers, so the
    /// code being somewhere else in the file would point the agent at the
    /// wrong lines. A comment on removed lines alone quotes nothing that
    /// should still be there, and passes.
    static func quotesCurrentCode(_ comment: ReviewComment, current: [String]) -> Bool {
        let texts = comment.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let markers = comment.codeMarkers.map(Array.init)
        let newSide = texts.indices.filter { markers?[safe: $0] != "-" }.map { texts[$0] }
        guard !newSide.isEmpty else { return true }
        // The first new-side line of the run is the one `anchor.newLine` names.
        guard let line = comment.anchor.newLine, line >= 1 else { return false }
        let start = line - 1
        guard start + newSide.count <= current.count else { return false }
        return newSide.indices.allSatisfy { current[start + $0] == newSide[$0] }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
