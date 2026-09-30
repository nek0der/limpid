// ReviewOpenInEditorTests.swift
// Limpid — pins which line Review's open action sends to the editor, so it
// is always the one the reader sees highlighted or the file's first change.

import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct ReviewOpenInEditorTests {
    /// Context at 10, then line 11 replaced, then context at 12.
    private let lines = [
        ReviewLine(id: 0, kind: .context, text: "a", oldLine: 10, newLine: 10),
        ReviewLine(id: 1, kind: .removed, text: "b", oldLine: 11, newLine: nil),
        ReviewLine(id: 2, kind: .added, text: "c", oldLine: nil, newLine: 11),
        ReviewLine(id: 3, kind: .context, text: "d", oldLine: 12, newLine: 12)
    ]

    private final class Opened {
        var line: Int?
    }

    /// The selection behind a live binding, for the paths that write it.
    private final class Live {
        var selection = ReviewDiffSelection()
        var composeCount = 0
    }

    private func makeTable(
        selecting ids: [Int],
        text: ReviewTextSelection = ReviewTextSelection(),
        opened: Opened,
        live: Live? = nil
    ) -> ReviewDiffTable {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        var selection = ReviewDiffSelection()
        selection.selectText(text)
        if let first = ids.first {
            selection.updateLines { lines in
                lines.select(first)
                if let last = ids.last, last != first {
                    lines.extend(to: last)
                }
            }
        }
        return ReviewDiffTable(
            rows: lines.enumerated().map { ReviewRow(id: $0.offset, kind: .code($0.element)) },
            diffLines: lines, intralineHighlights: ReviewIntralineHighlights(),
            contentKey: "open", widthKey: "open", layout: .unified,
            files: [file], lineCommentCounts: [:], numberWidth: 26, expandedFileID: file.id, contentIdentity: file.id,
            selection: live.map { live in Binding(get: { live.selection }, set: { live.selection = $0 }) }
                ?? .constant(selection),
            composerLineID: nil, composerStartLine: nil,
            composerIsEditing: false, composerText: .constant(""),
            onSelectFile: { _ in }, onCompose: { live?.composeCount += 1 },
            onCancelCompose: {}, onCommit: {}, onInsert: {}, onToggleTerminal: {},
            search: ReviewSearch(), onCloseSearch: {}, searchTargetLineID: nil, language: nil,
            onToggleViewed: {}, fileApplication: .macOSDefault, onOpenLine: { opened.line = $0 },
            onExpand: { _, _ in }, onResolve: { _ in }, onEdit: { _ in }, onDelete: { _ in },
            isOverlayPresented: false, onCloseOverlay: {}, onClose: {}
        )
    }

    /// The key never does nothing: with no selection it opens the first
    /// change, here a removal, which lands where the replacement starts.
    @Test func keyWithNothingSelectedOpensTheFirstChange() {
        let opened = Opened()
        makeTable(selecting: [], opened: opened).makeCoordinator().openInEditor(clickedRow: nil)
        #expect(opened.line == 11)
    }

    @Test func keyOpensTheTopOfTheSelection() {
        let opened = Opened()
        makeTable(selecting: [3, 2], opened: opened).makeCoordinator().openInEditor(clickedRow: nil)
        #expect(opened.line == 11)
    }

    /// A right-click inside the selection acts on the selection, like every
    /// other item in the menu.
    @Test func clickInsideTheSelectionOpensItsTop() {
        let opened = Opened()
        makeTable(selecting: [2, 3], opened: opened).makeCoordinator().openInEditor(clickedRow: 3)
        #expect(opened.line == 11)
    }

    /// Outside the selection — a line that could not be selected — the
    /// clicked line is the target.
    @Test func clickOutsideTheSelectionOpensTheClickedLine() {
        let opened = Opened()
        makeTable(selecting: [3], opened: opened).makeCoordinator().openInEditor(clickedRow: 0)
        #expect(opened.line == 10)
    }

    /// The menu names the line, so a removal's new place is visible before
    /// the editor opens.
    @Test func titleNamesTheLineAndTheApp() {
        let coordinator = makeTable(selecting: [1], opened: Opened()).makeCoordinator()
        // Compared through the same builder because the test host may run in
        // either language; what is pinned is the line, 11.
        #expect(
            coordinator.openInEditorTitle(clickedRow: 1)
                == FileApplicationResolution.macOSDefault.openLineActionTitle(line: 11)
        )
    }

    /// Text dragged over rows 2 and 3.
    private var draggedText: ReviewTextSelection {
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 3, lineID: 3, side: nil, utf16Offset: 1),
            to: ReviewTextPosition(rowIndex: 2, lineID: 2, side: nil, utf16Offset: 0)
        )
        return text
    }

    @Test func draggedTextSpansItsRowsTopFirst() {
        #expect(draggedText.rowRange == 2...3)
        #expect(ReviewTextSelection().rowRange == nil)
    }

    /// With only dragged text, the key opens its top rather than the file's
    /// first change.
    @Test func keyOpensTheTopOfDraggedText() {
        let opened = Opened()
        makeTable(selecting: [], text: draggedText, opened: opened).makeCoordinator().openInEditor(clickedRow: nil)
        #expect(opened.line == 11)
        let later = Opened()
        var belowTheChange = ReviewTextSelection()
        belowTheChange.select(
            from: ReviewTextPosition(rowIndex: 3, lineID: 3, side: nil, utf16Offset: 0),
            to: ReviewTextPosition(rowIndex: 3, lineID: 3, side: nil, utf16Offset: 1)
        )
        makeTable(selecting: [], text: belowTheChange, opened: later).makeCoordinator().openInEditor(clickedRow: nil)
        #expect(later.line == 12)
    }

    /// A right-click inside dragged text opens its top, the same line the
    /// key opens, rather than the line under the pointer.
    @Test func clickInsideDraggedTextOpensItsTop() {
        let opened = Opened()
        makeTable(selecting: [], text: draggedText, opened: opened).makeCoordinator().openInEditor(clickedRow: 3)
        #expect(opened.line == 11)
    }

    /// The comment key comments on the lines the dragged text covers, in
    /// one press.
    @Test func commentKeyTakesTheDraggedLines() {
        let live = Live()
        live.selection.selectText(draggedText)
        let coordinator = makeTable(selecting: [], opened: Opened(), live: live).makeCoordinator()
        #expect(coordinator.handle(.comment))
        #expect(live.selection.lines.startLineID == 2)
        #expect(live.selection.lines.endLineID == 3)
        #expect(live.selection.text.isEmpty)
        #expect(live.composeCount == 1)
    }

    /// `j` after a drag steps on from the dragged lines, not from the top.
    @Test func nextLineAfterADragStepsFromIt() {
        let live = Live()
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 0, lineID: 0, side: nil, utf16Offset: 0),
            to: ReviewTextPosition(rowIndex: 1, lineID: 1, side: nil, utf16Offset: 1)
        )
        live.selection.selectText(text)
        let coordinator = makeTable(selecting: [], opened: Opened(), live: live).makeCoordinator()
        #expect(coordinator.handle(.nextLine))
        #expect(live.selection.lines.startLineID == 2)
        #expect(live.selection.lines.endLineID == 2)
        #expect(live.selection.text.isEmpty)
    }

    /// `k` after an upward drag goes on upward from where the drag ended,
    /// past the top of what was dragged.
    @Test func previousLineAfterAnUpwardDragGoesAboveIt() {
        let live = Live()
        live.selection.selectText(draggedText)
        let coordinator = makeTable(selecting: [], opened: Opened(), live: live).makeCoordinator()
        #expect(coordinator.handle(.previousLine))
        #expect(live.selection.lines.startLineID == 1)
        #expect(live.selection.lines.endLineID == 1)
    }

    /// The arrows are the line keys, so they move the same way `j` / `k` do.
    @Test func arrowsAreTheLineKeys() throws {
        func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> ReviewTableKey? {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers.union([.numericPad, .function]),
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
            ))
            return ReviewTableKey(event: event)
        }
        #expect(try key(125) == .nextLine)
        #expect(try key(126) == .previousLine)
        #expect(try key(125, .shift) == .extendNextLine)
        #expect(try key(126, .shift) == .extendPreviousLine)
        #expect(try key(125, .command) == nil)
        #expect(try key(123) == nil)
    }
}
