// ReviewCommentRelocationTests.swift
// Weir — a comment placed in another comparison by the code it quotes, and checked against the code as it is now.

import Foundation
import Testing
@testable import Weir

@Suite("Review comment relocation")
struct ReviewCommentRelocationTests {
    private static let file = ReviewFile(path: "a.swift", layer: .turn, status: .modified)
    private static let target = ReviewFile(path: "a.swift", layer: .turns, status: .modified)

    private static func comment(code: String, markers: String?, newLine: Int? = 40) -> ReviewComment {
        ReviewComment(
            scopeIDs: ["turn:abc"],
            file: file,
            fingerprint: "old",
            anchor: ReviewAnchor(lineID: 9, oldLine: nil, newLine: newLine),
            code: code,
            codeMarkers: markers,
            body: "Why?"
        )
    }

    private static func diff(_ patch: String) throws -> ReviewDiff {
        try ReviewDiff(file: target, fingerprint: "new", lines: ReviewDiffParser.parse(patch))
    }

    @Test func aCommentsQuotedLines_reAnchorWhereTheyAppearOnce() throws {
        let diff = try Self.diff("@@ -1,2 +1,3 @@\n keep\n-old\n+new\n+more")

        guard case let .placed(moved) = ReviewCommentRelocation.placement(
            of: Self.comment(code: "new\nmore", markers: "++"),
            in: diff,
            scopeID: "turns:x"
        ) else {
            Issue.record("the quoted lines are in the diff once")
            return
        }

        #expect(moved.scopeIDs == ["turns:x"])
        #expect(moved.file == Self.target)
        #expect(moved.fingerprint == "new")
        #expect(moved.anchor.newLine == 2)
        #expect(moved.end?.newLine == 3)
        #expect(moved.body == "Why?")
    }

    @Test func linesNotThere_orThereTwice_orOfAnotherKind_doNotMove() throws {
        let twice = try Self.diff("@@ -1,2 +1,4 @@\n+same\n keep\n+same\n keep")
        let removed = try Self.diff("@@ -1,1 +0,0 @@\n-new")

        #expect(try ReviewCommentRelocation.placement(
            of: Self.comment(code: "gone", markers: "+"),
            in: Self.diff("@@ -1 +1 @@\n-a\n+b"),
            scopeID: "s"
        ) == .notFound)
        #expect(ReviewCommentRelocation.placement(of: Self.comment(code: "same", markers: "+"), in: twice, scopeID: "s") == .repeated)
        #expect(ReviewCommentRelocation.placement(of: Self.comment(code: "new", markers: "+"), in: removed, scopeID: "s") == .notFound)
    }

    @Test func aCommentThatCannotBePlaced_saysWhetherItsCodeIsMissingOrRepeated() throws {
        let twice = try Self.diff("@@ -1,2 +1,4 @@\n+same\n keep\n+same\n keep")

        #expect(ReviewCommentRelocation.placement(of: Self.comment(code: "same", markers: "+"), in: twice, scopeID: "s") == .repeated)
        #expect(ReviewCommentRelocation.placement(of: Self.comment(code: "gone", markers: "+"), in: twice, scopeID: "s") == .notFound)
    }

    @Test func theCurrentCode_mustStillHoldTheNewSide_whereTheCommentSaysItIs() {
        // Its first new-side line is line 2 of the file.
        let comment = Self.comment(code: "keep\nold\nnew", markers: " -+", newLine: 2)

        #expect(ReviewCommentRelocation.quotesCurrentCode(comment, current: ["a", "keep", "new", "b"]))
        #expect(!ReviewCommentRelocation.quotesCurrentCode(comment, current: ["keep", "changed"]))
        // The same lines moved down: the prompt would name the wrong lines.
        #expect(!ReviewCommentRelocation.quotesCurrentCode(comment, current: ["x", "y", "keep", "new"]))
        #expect(
            ReviewCommentRelocation.quotesCurrentCode(Self.comment(code: "old", markers: "-", newLine: nil), current: []),
            "removed lines alone"
        )
    }

    /// For a run from an added line to a removed one, each side takes its
    /// own first and last numbered line, and one line has no end.
    @Test func aSpan_takesEachSidesFirstAndLastNumberedLine() throws {
        let lines = [
            ReviewLine(id: 4, kind: .added, text: "a", oldLine: nil, newLine: 20),
            ReviewLine(id: 5, kind: .context, text: "b", oldLine: 18, newLine: 21),
            ReviewLine(id: 6, kind: .removed, text: "c", oldLine: 19, newLine: nil)
        ]

        let span = try #require(ReviewAnchor.span(of: lines))
        #expect(span.anchor == ReviewAnchor(lineID: 4, oldLine: 18, newLine: 20))
        #expect(span.end == ReviewAnchor(lineID: 6, oldLine: 19, newLine: 21))

        let single = try #require(ReviewAnchor.span(of: lines[1...1]))
        #expect(single.anchor == ReviewAnchor(lineID: 5, oldLine: 18, newLine: 21))
        #expect(single.end == nil)
        #expect(ReviewAnchor.span(of: [ReviewLine]()) == nil)
    }
}
