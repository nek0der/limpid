// ReviewAnchor+Span.swift
// Weir — where a comment's run of lines starts and ends, by row and by each side's line numbers.

import Foundation

extension ReviewAnchor {
    /// Returns the anchor and end of a comment on `lines`, in the order
    /// given. The end is `nil` for a single line, and the result is `nil`
    /// for no lines. A run
    /// can start on an added line and end on a removed one, so each side
    /// takes its own first and last numbered line. Which lines make the run
    /// (one column's, one changed block's) is the caller's to decide.
    static func span<C: BidirectionalCollection>(of lines: C) -> (anchor: Self, end: Self?)? where C.Element == ReviewLine {
        guard let first = lines.first, let last = lines.last else { return nil }
        let anchor = ReviewAnchor(
            lineID: first.id,
            oldLine: lines.first { $0.oldLine != nil }?.oldLine,
            newLine: lines.first { $0.newLine != nil }?.newLine
        )
        guard lines.count > 1 else { return (anchor, nil) }
        let end = ReviewAnchor(
            lineID: last.id,
            oldLine: lines.last { $0.oldLine != nil }?.oldLine,
            newLine: lines.last { $0.newLine != nil }?.newLine
        )
        return (anchor, end)
    }
}
