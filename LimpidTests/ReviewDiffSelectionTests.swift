// ReviewDiffSelectionTests.swift
// Limpid — pins that a diff shows either a line run or dragged text, never
// both, except beside a run an open composer keeps.

import Testing
@testable import Limpid

struct ReviewDiffSelectionTests {
    /// Context at 10, then line 11 replaced, then context at 12.
    private let lines = [
        ReviewLine(id: 0, kind: .context, text: "a", oldLine: 10, newLine: 10),
        ReviewLine(id: 1, kind: .removed, text: "b", oldLine: 11, newLine: nil),
        ReviewLine(id: 2, kind: .added, text: "c", oldLine: nil, newLine: 11),
        ReviewLine(id: 3, kind: .context, text: "d", oldLine: 12, newLine: 12)
    ]

    private var rows: [ReviewRow] {
        lines.enumerated().map { ReviewRow(id: $0.offset, kind: .code($0.element)) }
    }

    /// Text dragged over rows 2 and 3, bottom up.
    private var draggedText: ReviewTextSelection {
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 3, lineID: 3, side: nil, utf16Offset: 1),
            to: ReviewTextPosition(rowIndex: 2, lineID: 2, side: nil, utf16Offset: 0)
        )
        return text
    }

    private func selecting(_ lineID: Int) -> ReviewDiffSelection {
        var selection = ReviewDiffSelection()
        selection.updateLines { $0.select(lineID) }
        return selection
    }

    @Test func draggedTextReplacesTheLines() {
        var selection = selecting(0)
        selection.selectText(draggedText)
        #expect(selection.lines.isEmpty)
        #expect(selection.text == draggedText)
    }

    /// The press that starts a drag is empty; whether it lets go of the
    /// lines is for the release to say.
    @Test func pressThatStartsADragKeepsTheLines() {
        var selection = selecting(0)
        let press = ReviewTextPosition(rowIndex: 2, lineID: 2, side: nil, utf16Offset: 0)
        selection.selectText(ReviewTextSelection(anchor: press, head: press))
        #expect(selection.lines.startLineID == 0)
    }

    @Test func linesReplaceTheText() {
        var selection = ReviewDiffSelection()
        selection.selectText(draggedText)
        selection.updateLines { $0.select(0) }
        #expect(selection.lines.startLineID == 0)
        #expect(selection.text.isEmpty)
    }

    @Test func pressOnCodeLetsGoOfBoth() {
        var selection = selecting(0)
        let didRelease = selection.pressCode()
        #expect(didRelease)
        #expect(selection.lines.isEmpty)
        #expect(selection.text.isEmpty)
    }

    /// An open composer keeps its lines highlighted: neither a press on code
    /// nor dragged text lets go of them, and the text sits beside them.
    @Test func keptLinesStayBesideText() {
        var selection = selecting(0)
        let didRelease = selection.pressCode(keepingLines: true)
        #expect(!didRelease)
        selection.selectText(draggedText, keepingLines: true)
        #expect(selection.lines.startLineID == 0)
        #expect(selection.text == draggedText)
    }

    /// Once the composer closes, the text is the newer of the two and stays.
    @Test func closingTheComposerLeavesOnlyTheText() {
        var selection = selecting(0)
        selection.selectText(draggedText, keepingLines: true)
        selection.composerDidClose()
        #expect(selection.lines.isEmpty)
        #expect(selection.text == draggedText)
    }

    @Test func closingTheComposerWithoutTextKeepsTheLines() {
        var selection = selecting(0)
        selection.composerDidClose()
        #expect(selection.lines.startLineID == 0)
    }

    @Test func textBecomesTheLinesItCovers() {
        var selection = ReviewDiffSelection()
        selection.selectText(draggedText)
        selection.takeTextAsLines(rows: rows, diffLines: lines)
        #expect(selection.lines.startLineID == 2)
        #expect(selection.lines.endLineID == 3)
        #expect(selection.text.isEmpty)
    }

    /// Beside kept lines, the line keys act on those lines and the text only
    /// goes.
    @Test func textBesideKeptLinesOnlyGoes() {
        var selection = selecting(0)
        selection.selectText(draggedText, keepingLines: true)
        selection.takeTextAsLines(rows: rows, diffLines: lines)
        #expect(selection.lines.startLineID == 0)
        #expect(selection.lines.endLineID == 0)
        #expect(selection.text.isEmpty)
    }

    /// An upward drag gives an upward run: it starts where the drag started
    /// and moves on from where it ended.
    @Test func upwardDragKeepsItsDirection() {
        var selection = ReviewDiffSelection()
        selection.selectText(draggedText)
        selection.takeTextAsLines(rows: rows, diffLines: lines)
        #expect(selection.lines.anchorLineID == 3)
        #expect(selection.lines.headLineID == 2)
    }

    /// A run stops at the block it starts in, as the keyboard's does.
    @Test func textAcrossTwoHunksStopsAtTheFirst() {
        let hunked = [
            ReviewLine(id: 0, kind: .context, text: "a", oldLine: 10, newLine: 10, hunkIndex: 0),
            ReviewLine(id: 1, kind: .added, text: "b", oldLine: nil, newLine: 11, hunkIndex: 0),
            ReviewLine(id: 2, kind: .context, text: "c", oldLine: 40, newLine: 41, hunkIndex: 1)
        ]
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 0, lineID: 0, side: nil, utf16Offset: 0),
            to: ReviewTextPosition(rowIndex: 2, lineID: 2, side: nil, utf16Offset: 1)
        )
        var selection = ReviewDiffSelection()
        selection.selectText(text)
        selection.takeTextAsLines(
            rows: hunked.enumerated().map { ReviewRow(id: $0.offset, kind: .code($0.element)) },
            diffLines: hunked
        )
        #expect(selection.lines.startLineID == 0)
        #expect(selection.lines.endLineID == 1)
    }
}
