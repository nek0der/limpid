// ReviewTextSelection.swift
// Limpid — character-level selection within review code.

import Foundation

/// One insertion point in a rendered diff line.
///
/// TextKit and AppKit express selections as UTF-16 ranges. Keeping the same
/// unit here avoids converting through grapheme counts and accidentally
/// splitting a surrogate pair when the selected text is copied.
struct ReviewTextPosition: Equatable {
    /// Position in the rendered row list. Expanded context uses synthetic line
    /// ids outside patch order, so line ids alone cannot order copied text.
    let rowIndex: Int
    let lineID: Int
    let side: ReviewSide?
    let utf16Offset: Int
}

/// A copy selection independent from `ReviewSelection`, which continues to
/// describe the line range a comment belongs to.
struct ReviewTextSelection: Equatable {
    var anchor: ReviewTextPosition?
    var head: ReviewTextPosition?

    var isEmpty: Bool {
        guard let anchor, let head else { return true }
        return anchor == head
    }

    mutating func select(from anchor: ReviewTextPosition, to head: ReviewTextPosition) {
        guard anchor.side == head.side else {
            self = ReviewTextSelection()
            return
        }
        self.anchor = anchor
        self.head = head
    }

    mutating func clear() {
        self = ReviewTextSelection()
    }

    /// Re-resolves transient row indexes after cards or expanded context alter
    /// the rendered list. File identity and side remain the durable anchors;
    /// if either endpoint disappeared, keeping the range would select other
    /// code that merely inherited its old row index.
    func rebased(in rows: [ReviewRow]) -> ReviewTextSelection? {
        guard let anchor, let head,
              let anchorRow = Self.row(of: anchor, in: rows),
              let headRow = Self.row(of: head, in: rows)
        else { return nil }
        return ReviewTextSelection(
            anchor: ReviewTextPosition(
                rowIndex: anchorRow,
                lineID: anchor.lineID,
                side: anchor.side,
                utf16Offset: anchor.utf16Offset
            ),
            head: ReviewTextPosition(
                rowIndex: headRow,
                lineID: head.lineID,
                side: head.side,
                utf16Offset: head.utf16Offset
            )
        )
    }

    /// The selected UTF-16 range in one line. `nil` means this line is not in
    /// the selection; a zero-length range is retained at a multi-line edge so
    /// copying can preserve the newline the pointer crossed.
    func range(in line: ReviewLine, at rowIndex: Int, on side: ReviewSide?) -> NSRange? {
        guard let anchor, let head, !isEmpty, anchor.side == side, head.side == side else { return nil }
        let (start, end) = Self.ordered(anchor, head)
        guard rowIndex >= start.rowIndex, rowIndex <= end.rowIndex else { return nil }
        let length = (line.text as NSString).length
        if start.rowIndex == end.rowIndex {
            guard line.id == start.lineID, line.id == end.lineID else { return nil }
            let lower = min(max(start.utf16Offset, 0), length)
            let upper = min(max(end.utf16Offset, lower), length)
            return NSRange(location: lower, length: upper - lower)
        }
        if rowIndex == start.rowIndex {
            guard line.id == start.lineID else { return nil }
            let lower = min(max(start.utf16Offset, 0), length)
            return NSRange(location: lower, length: length - lower)
        }
        if rowIndex == end.rowIndex {
            guard line.id == end.lineID else { return nil }
            let upper = min(max(end.utf16Offset, 0), length)
            return NSRange(location: 0, length: upper)
        }
        return NSRange(location: 0, length: length)
    }

    private static func ordered(
        _ first: ReviewTextPosition,
        _ second: ReviewTextPosition
    ) -> (ReviewTextPosition, ReviewTextPosition) {
        if first.rowIndex != second.rowIndex {
            return first.rowIndex < second.rowIndex ? (first, second) : (second, first)
        }
        return first.utf16Offset <= second.utf16Offset ? (first, second) : (second, first)
    }

    private static func row(of position: ReviewTextPosition, in rows: [ReviewRow]) -> Int? {
        rows.indices.first { index in
            switch rows[index].kind {
            case let .code(line):
                position.side == nil && line.id == position.lineID
            case let .splitCode(pair):
                position.side.flatMap { pair.line(on: $0) }?.id == position.lineID
            case .notice, .hunk, .comment, .composer, .expander:
                false
            }
        }
    }
}

extension ReviewCopyPayload {
    /// Exact text between two insertion points. Full intermediate lines and
    /// the newlines crossed by the selection are preserved, while the first
    /// and last line contribute only the selected characters.
    static func text(rows: [ReviewRow], selection: ReviewTextSelection) -> String? {
        guard !selection.isEmpty, let anchor = selection.anchor else { return nil }
        let selected = rows.indices.compactMap { row -> String? in
            let line: ReviewLine? = switch rows[row].kind {
            case let .code(value):
                anchor.side == nil ? value : nil
            case let .splitCode(pair):
                anchor.side.flatMap { pair.line(on: $0) }
            case .notice, .hunk, .comment, .composer, .expander:
                nil
            }
            guard let line, line.isTextSelectable,
                  let range = selection.range(in: line, at: row, on: anchor.side)
            else { return nil }
            return (line.text as NSString).substring(with: range)
        }
        guard !selected.isEmpty else { return nil }
        return selected.joined(separator: "\n")
    }
}

extension ReviewLine {
    /// Code a reader can copy. Expanded context is intentionally included even
    /// though it cannot anchor a comment; hunk and file metadata are not code.
    var isTextSelectable: Bool {
        switch kind {
        case .context, .added, .removed:
            oldLine != nil || newLine != nil
        case .fileHeader, .hunk, .marker:
            false
        }
    }
}
