// ReviewIntralineDiffTests.swift
// Limpid — verifies bounded, Unicode-safe character highlighting.

import AppKit
import Foundation
import Testing
@testable import Limpid

struct ReviewIntralineDiffTests {
    @Test func changedMiddleProducesOnlyItsExactRanges() {
        let highlights = compute(old: "prefix-old-suffix", new: "prefix-new-suffix")

        #expect(text(in: "prefix-old-suffix", ranges: highlights[1]) == ["old"])
        #expect(text(in: "prefix-new-suffix", ranges: highlights[2]) == ["new"])
    }

    @Test func separatedChangesRemainSeparateRanges() {
        let highlights = compute(old: "aXbYc", new: "aUbVc")

        #expect(text(in: "aXbYc", ranges: highlights[1]) == ["X", "Y"])
        #expect(text(in: "aUbVc", ranges: highlights[2]) == ["U", "V"])
    }

    @Test func unrelatedAndOversizedLinesFallBackToLineHighlighting() {
        #expect(compute(old: "abc", new: "xyz").rangesByLineID.isEmpty)
        #expect(compute(
            old: "latestSource = await git.source(selected, root: root)",
            new: "let intralinePairs = ReviewIntralineDiff.pairs(for: latestDiff?.lines ?? [])"
        ).rangesByLineID.isEmpty)
        let common = "prefix-"
        let oversized = String(repeating: "a", count: ReviewIntralineDiff.maxUTF16UnitsPerLine + 1)
        #expect(compute(old: common + oversized, new: common + "b").rangesByLineID.isEmpty)
        let oversizedGrapheme = "x" + String(
            repeating: "\u{301}",
            count: ReviewIntralineDiff.maxUTF16UnitsPerLine + 1
        )
        #expect(compute(old: oversizedGrapheme, new: oversizedGrapheme + "y").rangesByLineID.isEmpty)
        let overPairBudget = Int(Double(ReviewIntralineDiff.maxPairWork).squareRoot()) + 1
        #expect(compute(
            old: common + String(repeating: "a", count: overPairBudget),
            new: common + String(repeating: "b", count: overPairBudget)
        ).rangesByLineID.isEmpty)
    }

    @Test func canonicalUnicodeChangeStaysVisibleAndOnGraphemeBoundaries() {
        let old = "x\u{e9}y"
        let new = "xe\u{301}y"
        let highlights = compute(old: old, new: new)

        #expect(text(in: old, ranges: highlights[1]) == ["é"])
        #expect(text(in: new, ranges: highlights[2]) == ["é"])
        for (value, ranges) in [(old, highlights[1]), (new, highlights[2])] {
            let string = value as NSString
            for range in ranges {
                #expect(string.rangeOfComposedCharacterSequences(for: range) == range)
            }
        }
    }

    @MainActor
    @Test func existingSplitPairsAreTheOnlyLinesCompared() {
        let lines = [
            ReviewLine(id: 0, kind: .hunk, text: "@@ -1 +1 @@", oldLine: nil, newLine: nil),
            ReviewLine(id: 1, kind: .removed, text: "old one", oldLine: 1, newLine: nil),
            ReviewLine(id: 2, kind: .removed, text: "old two", oldLine: 2, newLine: nil),
            ReviewLine(id: 3, kind: .added, text: "new one", oldLine: nil, newLine: 1),
            ReviewLine(id: 4, kind: .added, text: "new two", oldLine: nil, newLine: 2),
            ReviewLine(id: 5, kind: .context, text: "same", oldLine: 3, newLine: 3)
        ]

        let pairs = ReviewIntralineDiff.pairs(for: lines)

        #expect(pairs.count == 2)
        #expect(pairs[0].oldLineID == 1)
        #expect(pairs[0].newLineID == 3)
        #expect(pairs[1].oldLineID == 2)
        #expect(pairs[1].newLineID == 4)
    }

    @MainActor
    @Test func searchAndTextSelectionOverrideIntralineBackground() throws {
        let styled = try #require(ReviewRowPainter.styled(
            "abc",
            language: nil,
            match: "b",
            attributes: ReviewRowPainter.attributes(
                font: ReviewRowMetrics.font,
                color: .labelColor,
                alignment: .left,
                truncates: false
            ),
            intralineRanges: [NSRange(location: 0, length: 3)],
            intralineKind: .added,
            selectedRange: NSRange(location: 2, length: 1)
        ))

        let intraline = try #require(styled.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let search = try #require(styled.attribute(.backgroundColor, at: 1, effectiveRange: nil) as? NSColor)
        let selection = try #require(styled.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? NSColor)
        #expect(!intraline.isEqual(search))
        #expect(search.isEqual(NSColor.findHighlightColor))
        #expect(selection.isEqual(NSColor.selectedTextBackgroundColor))
    }

    private func compute(old: String, new: String) -> ReviewIntralineHighlights {
        ReviewIntralineDiff.compute([
            ReviewIntralinePair(oldLineID: 1, oldText: old, newLineID: 2, newText: new)
        ])
    }

    private func text(in value: String, ranges: [NSRange]) -> [String] {
        let string = value as NSString
        return ranges.map { string.substring(with: $0) }
    }
}
