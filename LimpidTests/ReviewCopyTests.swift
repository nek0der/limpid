// ReviewCopyTests.swift
// Limpid — verifies that Review copies code without diff decoration.

import Foundation
import Testing
@testable import Limpid

struct ReviewCopyTests {
    @Test func payloadContainsOnlySelectedCodeFromTheVisibleSide() {
        let lines = [
            ReviewLine(id: 1, kind: .removed, text: "old value", oldLine: 1, newLine: nil),
            ReviewLine(id: 2, kind: .added, text: "new value", oldLine: nil, newLine: 1),
            ReviewLine(id: 3, kind: .context, text: "shared", oldLine: 2, newLine: 2)
        ]
        var unified = ReviewSelection()
        unified.select(1)
        unified.extend(to: 3)
        #expect(ReviewCopyPayload.code(lines: lines, selection: unified, layout: .unified)
            == "old value\nnew value\nshared")

        var split = ReviewSelection()
        split.select(1, on: .old)
        split.extend(to: 3)
        #expect(ReviewCopyPayload.code(lines: lines, selection: split, layout: .sideBySide)
            == "old value\nshared")
    }

    @Test func characterSelectionPreservesPartialBoundariesAndUnicode() {
        let lines = [
            ReviewLine(id: 1, kind: .context, text: "ab😀c", oldLine: 1, newLine: 1),
            ReviewLine(id: 2, kind: .context, text: "middle", oldLine: 2, newLine: 2),
            ReviewLine(id: 3, kind: .context, text: "終わり", oldLine: 3, newLine: 3)
        ]
        let forward = ReviewTextSelection(
            anchor: ReviewTextPosition(rowIndex: 0, lineID: 1, side: nil, utf16Offset: 2),
            head: ReviewTextPosition(rowIndex: 2, lineID: 3, side: nil, utf16Offset: 1)
        )
        let backward = ReviewTextSelection(anchor: forward.head, head: forward.anchor)
        let rows = lines.enumerated().map { ReviewRow(id: $0.offset, kind: .code($0.element)) }

        #expect(ReviewCopyPayload.text(rows: rows, selection: forward) == "😀c\nmiddle\n終")
        #expect(ReviewCopyPayload.text(rows: rows, selection: backward) == "😀c\nmiddle\n終")
    }

    @Test func characterSelectionInSplitLayoutStaysOnItsStartingSide() {
        let lines = [
            ReviewLine(id: 1, kind: .removed, text: "old", oldLine: 1, newLine: nil),
            ReviewLine(id: 2, kind: .added, text: "new", oldLine: nil, newLine: 1),
            ReviewLine(id: 3, kind: .context, text: "shared", oldLine: 2, newLine: 2)
        ]
        let selection = ReviewTextSelection(
            anchor: ReviewTextPosition(rowIndex: 0, lineID: 1, side: .old, utf16Offset: 1),
            head: ReviewTextPosition(rowIndex: 1, lineID: 3, side: .old, utf16Offset: 3)
        )
        let rows: [ReviewRow] = ReviewSideBySideBuilder.elements(for: lines).enumerated().compactMap { index, element in
            guard case let .pair(pair) = element else { return nil }
            return ReviewRow(id: index, kind: .splitCode(pair))
        }

        #expect(ReviewCopyPayload.text(rows: rows, selection: selection) == "ld\nsha")
    }

    @Test func characterSelectionUsesRenderedOrderForExpandedContext() {
        let first = ReviewLine(id: 10, kind: .context, text: "before", oldLine: 1, newLine: 1)
        var expanded = ReviewLine(id: 1_000_002, kind: .context, text: "expanded", oldLine: 2, newLine: 2)
        expanded.isExpansion = true
        let last = ReviewLine(id: 20, kind: .context, text: "after", oldLine: 3, newLine: 3)
        let rows = [
            ReviewRow(id: 0, kind: .code(first)),
            ReviewRow(id: 1, kind: .composer(first)),
            ReviewRow(id: 2, kind: .code(expanded)),
            ReviewRow(id: 3, kind: .code(last))
        ]
        let selection = ReviewTextSelection(
            anchor: ReviewTextPosition(rowIndex: 0, lineID: first.id, side: nil, utf16Offset: 3),
            head: ReviewTextPosition(rowIndex: 3, lineID: last.id, side: nil, utf16Offset: 2)
        )

        #expect(ReviewCopyPayload.text(rows: rows, selection: selection) == "ore\nexpanded\naf")
    }

    @Test func characterSelectionRebasesWhenNonCodeRowsMove() {
        let first = ReviewLine(id: 1, kind: .context, text: "first", oldLine: 1, newLine: 1)
        let last = ReviewLine(id: 2, kind: .context, text: "last", oldLine: 2, newLine: 2)
        let selection = ReviewTextSelection(
            anchor: ReviewTextPosition(rowIndex: 0, lineID: first.id, side: nil, utf16Offset: 1),
            head: ReviewTextPosition(rowIndex: 1, lineID: last.id, side: nil, utf16Offset: 2)
        )
        let movedRows = [
            ReviewRow(id: 0, kind: .code(first)),
            ReviewRow(id: 1, kind: .composer(first)),
            ReviewRow(id: 2, kind: .code(last))
        ]

        let rebased = selection.rebased(in: movedRows)
        #expect(rebased?.anchor?.rowIndex == 0)
        #expect(rebased?.head?.rowIndex == 2)
        #expect(ReviewCopyPayload.text(rows: movedRows, selection: rebased ?? ReviewTextSelection()) == "irst\nla")
    }

    @MainActor
    @Test func pointerLayoutReturnsOnlyComposedCharacterBoundaries() {
        let text = "a\u{301}\u{302}b"
        let boundaries: Set = [0, 3, 4]
        let layout = ReviewCodeTextLayout()

        for x in stride(from: CGFloat.zero, through: 80, by: 0.5) {
            #expect(boundaries.contains(layout.utf16Offset(in: text, x: x, font: ReviewRowMetrics.font)))
        }
    }
}
