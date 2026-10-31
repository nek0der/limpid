// ReviewHunkCommentTests.swift
// Weir — the run a hunk header's "Comment" covers.

import Foundation
import Testing
@testable import Weir

struct ReviewHunkCommentTests {
    /// Two hunks: context, a removed and an added line, context; then a
    /// hunk that only removes.
    private static let patch = """
    diff --git a/f.swift b/f.swift
    --- a/f.swift
    +++ b/f.swift
    @@ -1,3 +1,3 @@
     one
    -two
    +TWO
     three
    @@ -10,3 +10,2 @@
     ten
    -eleven
     twelve
    """

    private static func lines() throws -> [ReviewLine] {
        try ReviewDiffParser.parse(patch)
    }

    private static func header(_ index: Int, in lines: [ReviewLine]) throws -> ReviewLine {
        try #require(lines.filter { $0.kind == .hunk }.dropFirst(index).first)
    }

    @Test func unified_coversTheChangedLines_withoutTheContextAround() throws {
        let lines = try Self.lines()
        let run = try #require(ReviewHunkRun.run(ofHunk: Self.header(0, in: lines), in: lines, layout: .unified))
        let covered = lines.filter { $0.id >= run.start && $0.id <= run.end }.map(\.text)
        #expect(covered == ["two", "TWO"])
        #expect(run.side == nil)
    }

    @Test func sideBySide_takesTheNewColumn_whereTheHunkAdded_elseTheOld() throws {
        let lines = try Self.lines()
        let mixed = try #require(ReviewHunkRun.run(ofHunk: Self.header(0, in: lines), in: lines, layout: .sideBySide))
        #expect(mixed.side == .new)
        #expect(lines.first { $0.id == mixed.start }?.text == "TWO")
        let removal = try #require(ReviewHunkRun.run(ofHunk: Self.header(1, in: lines), in: lines, layout: .sideBySide))
        #expect(removal.side == .old)
        #expect(lines.first { $0.id == removal.start }?.text == "eleven")
        #expect(removal.start == removal.end)
    }

    /// Each header names its own hunk, never the one before it.
    @Test func aRun_staysInsideItsHunk() throws {
        let lines = try Self.lines()
        let run = try #require(ReviewHunkRun.run(ofHunk: Self.header(1, in: lines), in: lines, layout: .unified))
        #expect(lines.filter { $0.id >= run.start && $0.id <= run.end }.allSatisfy { $0.hunkIndex == 1 })
    }

    /// A hunk of context alone is taken whole; a line that is not a hunk
    /// header gives no run, and neither does a hunk whose lines are all
    /// expanded context.
    @Test func contextAlone_isTakenWhole_andExpansionIsNot() throws {
        var lines = try ReviewDiffParser.parse("""
        diff --git a/f b/f
        @@ -1,2 +1,2 @@
         a
         b
        """)
        let header = try Self.header(0, in: lines)
        let whole = try #require(ReviewHunkRun.run(ofHunk: header, in: lines, layout: .unified))
        #expect(lines.filter { $0.id >= whole.start && $0.id <= whole.end }.map(\.text) == ["a", "b"])
        #expect(ReviewHunkRun.run(ofHunk: lines[lines.count - 1], in: lines, layout: .unified) == nil)
        for index in lines.indices where lines[index].kind == .context {
            lines[index].isExpansion = true
        }
        #expect(ReviewHunkRun.run(ofHunk: header, in: lines, layout: .unified) == nil)
        #expect(ReviewHunkRun.commentableHeaders(in: lines).isEmpty)
    }

    @Test func everyHeaderWithLines_isCommentable_andHasARunInEitherLayout() throws {
        let lines = try Self.lines()
        let headers = lines.filter { $0.kind == .hunk }
        #expect(ReviewHunkRun.commentableHeaders(in: lines) == Set(headers.map(\.id)))
        for header in headers {
            for layout in ReviewDiffLayout.allCases {
                #expect(ReviewHunkRun.run(ofHunk: header, in: lines, layout: layout) != nil)
            }
        }
    }

    /// Context between two changes is part of the run; side by side, a hunk
    /// that only adds is commented on in the new column.
    @Test func contextBetweenChanges_isInTheRun_andAnAdditionTakesTheNewColumn() throws {
        let lines = try ReviewDiffParser.parse("""
        diff --git a/f b/f
        @@ -1,2 +1,2 @@
        -a
         between
        +b
        @@ -10,1 +10,2 @@
         x
        +y
        """)
        let headers = lines.filter { $0.kind == .hunk }
        let mixed = try #require(ReviewHunkRun.run(ofHunk: headers[0], in: lines, layout: .unified))
        #expect(lines.filter { $0.id >= mixed.start && $0.id <= mixed.end }.map(\.text) == ["a", "between", "b"])
        let addition = try #require(ReviewHunkRun.run(ofHunk: headers[1], in: lines, layout: .sideBySide))
        #expect(addition.side == .new)
        #expect(lines.first { $0.id == addition.start }?.text == "y")
    }
}
