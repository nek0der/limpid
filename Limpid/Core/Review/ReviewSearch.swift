// ReviewSearch.swift
// Limpid — finding text inside the diff on screen.

import Foundation

/// One place the query was found: the line, and the column it was found in.
struct ReviewSearchHit: Equatable {
    let lineID: Int
    /// `nil` in the unified layout, which has one column to land in.
    let side: ReviewSide?
    /// Whether the cursor can rest on this line. A match inside an unfolded
    /// region, or on a `\ No newline at end of file` marker, is worth scrolling
    /// to and not worth selecting: the rest of the surface refuses to comment
    /// there, and a cursor parked on one drew an add marker that could not be
    /// pressed. Carried on the hit so the check is one comparison rather than a
    /// scan of every row on every keystroke.
    let isCommentable: Bool
}

/// The find bar's state.
///
/// The index is kept here rather than derived from the selection: a reader who
/// moves the cursor with `j` after searching has not changed which match is
/// next, and recomputing it from wherever the cursor landed would jump them
/// somewhere they did not ask to go.
struct ReviewSearch: Equatable {
    var query = ""
    var isPresented = false
    var index = 0

    var isActive: Bool {
        isPresented && !query.isEmpty
    }

    /// The match to move to, wrapping in either direction. Wrapping rather
    /// than stopping: a diff is read in a loop, and a Find Next that goes dead
    /// at the last hit reads as the search having broken.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Every row the query appears in, in the order they are drawn.
    ///
    /// Over the rendered rows rather than the patch, so a line the reader
    /// unfolded is searched like any other and one hidden inside a fold is
    /// not — the find bar answers for what is on screen.
    static func hits(in rows: [ReviewRow], query: String) -> [ReviewSearchHit] {
        guard !query.isEmpty else { return [] }
        var result: [ReviewSearchHit] = []
        for row in rows {
            switch row.kind {
            case let .splitCode(pair):
                // Each column is its own hit: the same query can appear on
                // both sides of one row, and landing on the wrong one puts the
                // cursor in the column the reader is not reading.
                // A context line is the same line drawn in both columns. It is
                // one place in the file, so it is one match: counting it twice
                // stopped Find Next on it a second time without moving.
                if let old = pair.old, let new = pair.new, old.id == new.id {
                    if matches(old.text, query) {
                        result.append(ReviewSearchHit(
                            lineID: old.id,
                            side: ReviewSide.covering(old),
                            isCommentable: old.isCommentable
                        ))
                    }
                    continue
                }
                if let old = pair.old, matches(old.text, query) {
                    result.append(ReviewSearchHit(lineID: old.id, side: .old, isCommentable: old.isCommentable))
                }
                if let new = pair.new, matches(new.text, query) {
                    result.append(ReviewSearchHit(lineID: new.id, side: .new, isCommentable: new.isCommentable))
                }
            case .composer:
                // The composer draws the line it is attached to a second
                // time. Counting that would stop Find Next twice on one line,
                // and the second stop would be inside a text field.
                continue
            default:
                guard let line = row.anchorLine, row.texts.contains(where: { matches($0, query) }) else { continue }
                result.append(ReviewSearchHit(lineID: line.id, side: nil, isCommentable: line.isCommentable))
            }
        }
        return result
    }

    /// We highlight the first occurrence because navigation counts matching lines.
    /// Case and diacritic handling must agree with the row lookup above.
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return [] }
        return [range]
    }

    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
