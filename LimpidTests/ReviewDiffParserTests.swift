// ReviewDiffParserTests.swift
// Limpid — reading Git's patch into review lines: what it refuses, how far it reads, and the runs a comment can span.

import Foundation
import Testing
@testable import Limpid

struct ReviewDiffParserTests {
    @Test(arguments: [
        "@@ -1,3 +1,3 @@\n x\n@@ -9,1 +9,1 @@\n-a\n+b\n",
        "@@ -1,1 +1,1 @@\n?bad\n",
        "\\ No newline at end of file\n"
    ])
    func malformedBoundariesAreRefused(_ patch: String) {
        #expect(throws: ReviewError.invalidDiff) { try ReviewDiffParser.parse(patch) }
    }

    @Test func parserBoundsTheRowCount() {
        let count = ReviewDiffParser.maxRows + 1
        let patch = "@@ -1,\(count) +1,\(count) @@\n" + String(repeating: " x\n", count: count)
        #expect(throws: ReviewError.tooLarge) { try ReviewDiffParser.parse(patch) }
    }

    /// A line whose content starts with a combining mark is still a line.
    ///
    /// The marker Git writes is one scalar; the mark that follows it joins to
    /// it into a single grapheme, so the marker is read as a scalar, not as
    /// the first `Character`. Read as a `Character` it would match neither
    /// `+` nor `-`, and the whole file would be refused with `invalidDiff`.
    @Test func aLineStartingWithACombiningMarkIsParsed() throws {
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-\u{0301}old\n+\u{0301}new")
        #expect(lines.count == 3)
        let removed = try #require(lines.first { $0.kind == .removed })
        let added = try #require(lines.first { $0.kind == .added })
        // The mark belongs to the content, not to the marker: dropping the
        // first `Character` would have taken it with the marker.
        #expect(removed.text == "\u{0301}old")
        #expect(added.text == "\u{0301}new")
        #expect(removed.oldLine == 1)
        #expect(added.newLine == 1)
    }

    /// A comment names a span of line numbers, and a span is only true of a run
    /// that is contiguous in the file. Two hunks sit one row apart on screen
    /// and hundreds of lines apart in the file, so a run that crossed the `@@`
    /// between them would tell the agent to read everything in between.
    @Test func aRunCannotReachFromOneHunkIntoTheNext() throws {
        let patch = """
        @@ -10,1 +10,2 @@
        -oldA
        +newA
        +newA2
        @@ -500,1 +500,1 @@
        -oldB
        +newB
        """
        let lines = try ReviewDiffParser.parse(patch)
        let hunks = lines.filter(\.isCommentable).map(\.hunkIndex)
        #expect(hunks == [0, 0, 0, 1, 1])
        let first = try #require(lines.first { $0.isCommentable && $0.hunkIndex == 0 })
        let last = try #require(lines.last { $0.isCommentable && $0.hunkIndex == 0 })
        let across = try #require(lines.first { $0.isCommentable && $0.hunkIndex == 1 })
        #expect(ReviewRunBounds.canExtend(lines, from: first.id, to: last.id))
        #expect(!ReviewRunBounds.canExtend(lines, from: first.id, to: across.id))
        // Backwards is the same run seen from the other end.
        #expect(!ReviewRunBounds.canExtend(lines, from: across.id, to: first.id))
        // A run that has not started anywhere has nothing to be held inside.
        #expect(ReviewRunBounds.canExtend(lines, from: nil, to: across.id))
        // The split layout draws the same lines in two columns, and the rule
        // has to answer for both of them.
        let split = ReviewRowBuilder.rows(
            expanded: ReviewDiff(
                file: ReviewFile(path: "a.swift", layer: .unstaged, status: .modified),
                fingerprint: "f",
                lines: lines
            ),
            comments: [],
            composerLineID: nil,
            layout: .sideBySide
        )
        let pairs = split.compactMap { row -> ReviewSplitPair? in
            if case let .splitCode(pair) = row.kind {
                return pair
            }
            return nil
        }
        #expect(!pairs.isEmpty)
        for pair in pairs where pair.old != nil && pair.new != nil {
            #expect(pair.old?.hunkIndex == pair.new?.hunkIndex)
        }
        let newLines = pairs.compactMap(\.new)
        let firstNew = try #require(newLines.first { $0.hunkIndex == 0 })
        let lastNew = try #require(newLines.last { $0.hunkIndex == 0 })
        #expect(firstNew.id != lastNew.id)
        #expect(ReviewRunBounds.canExtend(newLines, from: firstNew.id, to: lastNew.id))
        let acrossNew = try #require(newLines.first { $0.hunkIndex == 1 })
        #expect(!ReviewRunBounds.canExtend(newLines, from: firstNew.id, to: acrossNew.id))
    }
}
