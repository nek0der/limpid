// ReviewDiffSelection.swift
// Limpid — the one place that decides which of the two selections is shown.

import Foundation

/// What the reader has selected in a diff: a run of lines, picked in the
/// gutter or with the keyboard, or text, dragged over code.
///
/// The two are ways of pointing at code, and only one is on screen at a time,
/// because copy, open and comment each act on what is highlighted. Held as two
/// separate values, every path that changed one had to remember to clear the
/// other, and each path that forgot left both highlighted with the actions
/// split between them. Every change goes through this type instead.
///
/// The one exception is a run an open composer keeps: its highlight is what
/// shows which lines the comment is for, so text dragged meanwhile sits beside
/// it until the composer closes. Whether one is open is the composer's to
/// say, so callers pass it in rather than this holding a copy.
struct ReviewDiffSelection: Equatable {
    private(set) var lines = ReviewSelection()
    private(set) var text = ReviewTextSelection()

    /// Changes the line run. Pointing at lines lets go of any text.
    mutating func updateLines(_ change: (inout ReviewSelection) -> Void) {
        change(&lines)
        if !lines.isEmpty {
            text.clear()
        }
    }

    /// Replaces the text. Text lets go of the line run unless an open composer
    /// keeps it. An empty selection — the press that starts a drag — leaves
    /// the run alone until the release says whether it was a drag.
    mutating func selectText(_ selection: ReviewTextSelection, keepingLines: Bool = false) {
        text = selection
        if !selection.isEmpty, !keepingLines {
            lines = ReviewSelection()
        }
    }

    /// A press on code that did not become a drag. Code is for reading and
    /// copying; lines are picked in the gutter. Returns whether the run went.
    @discardableResult
    mutating func pressCode(keepingLines: Bool = false) -> Bool {
        text.clear()
        guard !keepingLines else { return false }
        lines = ReviewSelection()
        return true
    }

    /// Once the composer closes, text dragged while it was open is the newer
    /// of the two and stays.
    mutating func composerDidClose() {
        if !text.isEmpty {
            lines = ReviewSelection()
        }
    }

    /// Turns dragged text into the run of lines it covers, for the keys that
    /// act on lines: `c` comments on what was dragged over and `j` steps on
    /// from it rather than from the top of the file. The run stops where the
    /// block it starts in does, as one extended with the keyboard would. The
    /// run keeps the drag's direction, so `k` after an upward drag goes on
    /// upward from where the drag ended. A run a composer keeps is what those
    /// keys act on, so beside one the text only goes.
    mutating func takeTextAsLines(rows: [ReviewRow], diffLines: [ReviewLine]) {
        guard let range = text.rowRange, let anchor = text.anchor, let head = text.head else { return }
        text.clear()
        guard lines.isEmpty else { return }
        let side = anchor.side
        let rowsFromAnchor = head.rowIndex < anchor.rowIndex ? Array(range.reversed()) : Array(range)
        let lineIDs = rowsFromAnchor.compactMap { row in
            rows.indices.contains(row) ? rows[row].commentableLineID(on: side) : nil
        }
        guard let first = lineIDs.first else { return }
        lines.select(first, on: side)
        for lineID in lineIDs.dropFirst() where ReviewRunBounds.canExtend(diffLines, from: first, to: lineID) {
            lines.extend(to: lineID)
        }
    }

    /// Re-resolves the text after cards or expanded context move the rows,
    /// dropping it if an endpoint disappeared.
    mutating func rebaseText(in rows: [ReviewRow]) {
        text = text.rebased(in: rows) ?? ReviewTextSelection()
    }

    /// Drops the text alone, for a layout switch that redraws every column.
    mutating func clearText() {
        text.clear()
    }

    /// Drops both, for a new file or a refresh.
    mutating func clear() {
        lines = ReviewSelection()
        text.clear()
    }
}
