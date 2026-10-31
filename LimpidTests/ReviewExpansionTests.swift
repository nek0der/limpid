// ReviewExpansionTests.swift
// Limpid — unfolding the unchanged lines a unified diff leaves out, and finding text in what is on screen.

import Foundation
import Testing
@testable import Limpid

struct ReviewExpansionTests {
    private static let patch = """
    @@ -20,3 +20,4 @@
     context one
    -removed
    +added
    +also added
     context two
    @@ -60,2 +61,2 @@
     context three
    -old
    +new
    """

    private static let source = (1...100).map { "line \($0)" }

    private func file() -> ReviewFile {
        ReviewFile(path: "a.txt", layer: .unstaged, status: .modified)
    }

    /// Where the gaps in a patch are, and what unfolding one puts back.
    ///
    /// The invariant under all of it is that the patch does not move: a
    /// comment is anchored to a row id and a fingerprint the next `git diff`
    /// has to reproduce, and neither may depend on how much of the file the
    /// reader happened to open.
    @Test func gapsUnfoldWithoutMovingThePatch() throws {
        let lines = try ReviewDiffParser.parse(Self.patch)
        let source = Self.source
        let gaps = ReviewExpansionPlan.gaps(in: lines, sourceCount: source.count)
        try #require(gaps.count == 3, "Expected a gap before, between and after the hunks: \(gaps.count)")
        // Everything above the first hunk.
        #expect(gaps[0].range == 1...19, "Leading gap: \(gaps[0].range)")
        #expect(gaps[0].delta == 0, "Leading gap has no offset yet")
        // The first hunk added a line, so the sides have drifted by one below it.
        #expect(gaps[1].range == 24...60, "Middle gap: \(gaps[1].range)")
        #expect(gaps[1].delta == -1, "Middle gap offset: \(gaps[1].delta)")
        #expect(gaps[2].range == 63...100, "Trailing gap: \(gaps[2].range)")
        #expect(gaps[2].nextHunkID == nil, "The trailing gap has no hunk after it")
        // The ends of the file open one way each; the middle opens both.
        let closed = ReviewExpansionPlan.apply(to: lines, gaps: gaps, spans: [:], source: source)
        #expect(closed.lines == lines, "Nothing unfolded must leave the patch alone")
        try #require(closed.expanders.count == 3, "Every gap offers a control")
        #expect(!closed.expanders[0].canExpandDown, "The top of the file has no hunk above it")
        #expect(closed.expanders[1].canExpandUp && closed.expanders[1].canExpandDown, "A middle gap opens both ways")
        #expect(!closed.expanders[2].canExpandUp, "The end of the file has no hunk below it")
        // Unfolding upward puts the lines immediately above the hunk back.
        let up = ReviewExpansionPlan.apply(
            to: lines,
            gaps: gaps,
            spans: [1: ReviewGapSpan(above: 3, below: 0)],
            source: source
        )
        let unfolded = up.lines.filter(\.isExpansion)
        #expect(unfolded.map(\.newLine) == [58, 59, 60], "Unfolded upward: \(unfolded.map(\.newLine))")
        #expect(unfolded.map(\.oldLine) == [57, 58, 59], "Old numbering follows the gap's offset")
        #expect(unfolded.map(\.text) == ["line 58", "line 59", "line 60"], "Unfolded text comes from the file")
        #expect(unfolded.allSatisfy { !$0.isCommentable }, "An unfolded line must not accept a comment")
        #expect(
            up.lines.filter { !$0.isExpansion } == lines,
            "Unfolding must not touch the lines a comment is anchored to"
        )
        let upControl = try #require(up.expanders.first { $0.gap == 1 }, "The gap still offers a control")
        #expect(upControl.hidden == 34, "The control counts what is still folded")
        // Ahead of the lines the upward end revealed, not ahead of the hunk.
        // What is still folded lies between the two ends, and a control drawn
        // past the revealed lines said 34 lines were hidden between two that
        // are next to each other.
        #expect(
            upControl.beforeLineID == ReviewExpansionPlan.idBase + 58,
            "The control sits past what it revealed: \(String(describing: upControl.beforeLineID))"
        )
        // Both ends of one gap, asked for past what it holds, meet rather than
        // overlapping: a line drawn twice is a line the reader cannot trust.
        let met = ReviewExpansionPlan.apply(
            to: lines,
            gaps: gaps,
            spans: [1: ReviewGapSpan(above: 30, below: 30)],
            source: source
        )
        let middle = met.lines.filter(\.isExpansion).compactMap(\.newLine)
        #expect(middle == Array(24...60), "A gap opened from both ends: \(middle.count) lines")
        // A gap with nothing left folded keeps a control, at the head of what
        // it unfolded, or a reader who opened a file has no way back.
        let opened = try #require(met.expanders.first { $0.gap == 1 }, "A fully unfolded gap offers no way back")
        #expect(opened.hidden == 0 && opened.canCollapse, "The control does not offer to fold the gap again")
        // Ahead of the first line it revealed, not down beside the hunk: a
        // reader who opened a whole gap is at the top of it.
        #expect(
            opened.beforeLineID == ReviewExpansionPlan.idBase + 24,
            "The fold control is not at the head of what it unfolded"
        )
        // A gap whose file has shrunk under it keeps its numbering rather than
        // shifting every line below the missing one.
        let short = ReviewExpansionPlan.apply(
            to: lines,
            gaps: gaps,
            spans: [2: ReviewGapSpan(above: 0, below: 2)],
            source: Array(source.prefix(63))
        )
        let beyond = short.lines.filter { $0.isExpansion && $0.newLine == 64 }
        #expect(beyond.first?.text.isEmpty == true, "A line past the end of the file reads as empty")
        // A hunk that starts at line one leaves no gap above it.
        let fromTop = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        #expect(
            ReviewExpansionPlan.gaps(in: fromTop, sourceCount: 1).isEmpty,
            "A single-line file has nothing folded"
        )
        // `nil` is how both callers say the file's contents could not be read.
        // Nothing can be unfolded then — not the trailing run, whose size only
        // the file knows, and not the interior ones either, since there are no
        // lines to put there. Offering them drew a control that named a number
        // of hidden lines and did nothing when pressed.
        #expect(
            ReviewExpansionPlan.gaps(in: lines, sourceCount: nil).isEmpty,
            "Gaps were offered for a file that could not be read"
        )
    }

    /// What the find bar answers for.
    ///
    /// The rendered rows, not the patch: a line the reader unfolded is part of
    /// what is on screen and has to be findable, and one still folded away is
    /// not — a count that included it would send Find Next somewhere there is
    /// nothing to see.
    @Test func findAnswersForTheRowsOnScreen() throws {
        let lines = try ReviewDiffParser.parse(Self.patch)
        let source = Self.source
        let folded = ReviewRowBuilder.rows(
            expanded: ReviewDiff(file: file(), fingerprint: "f", lines: lines),
            comments: [],
            composerLineID: nil,
            source: source
        )
        #expect(ReviewSearch.hits(in: folded, query: "").isEmpty, "An empty query matches nothing")
        #expect(ReviewSearch.hits(in: folded, query: "ADDED").count == 2, "The search is case-insensitive")
        #expect(ReviewSearch.hits(in: folded, query: "line 30").isEmpty, "A folded line is not on screen")
        let unfolded = ReviewRowBuilder.rows(
            expanded: ReviewDiff(file: file(), fingerprint: "f", lines: lines),
            comments: [],
            composerLineID: nil,
            source: source,
            gapSpans: [1: ReviewGapSpan(above: 0, below: 40)]
        )
        #expect(ReviewSearch.hits(in: unfolded, query: "line 30").count == 1, "An unfolded line is searchable")
        let hit = try #require(ReviewSearch.hits(in: unfolded, query: "line 30").first, "Hit missing")
        #expect(hit.lineID == ReviewExpansionPlan.idBase + 30, "The hit names the line it was found on")
        // A context line is drawn in both columns of the split layout, but it
        // is one line of the file: Find Next stopping on it twice moved
        // nothing the second time.
        let split = ReviewRowBuilder.rows(
            expanded: ReviewDiff(file: file(), fingerprint: "f", lines: lines),
            comments: [],
            composerLineID: nil,
            layout: .sideBySide,
            source: source
        )
        let sided = ReviewSearch.hits(in: split, query: "context one")
        #expect(sided.count == 1, "A context line is one place to land: \(sided.count)")
        // A removed line and an added one are two lines drawn in one row, and
        // each still answers for its own column — the fold above keys on the
        // line's identity, not on what it says.
        #expect(
            ReviewSearch.hits(in: split, query: "removed").map(\.side) == [.old],
            "A removed line belongs to the old column alone"
        )
        #expect(
            ReviewSearch.hits(in: split, query: "also added").map(\.side) == [.new],
            "An added line belongs to the new column alone"
        )
        // Stepping wraps in both directions, and an empty result never moves.
        #expect(ReviewSearch.step(2, by: 1, count: 3) == 0, "Find Next does not wrap")
        #expect(ReviewSearch.step(0, by: -1, count: 3) == 2, "Find Previous does not wrap")
        #expect(ReviewSearch.step(4, by: 1, count: 0) == 0, "Stepping with nothing found must stay put")
        // The highlight marks every occurrence on a line, and marks the same
        // text the count was taken from.
        #expect(ReviewSearch.ranges(in: "one two one", query: "one").count == 1, "One mark per matching line")
        #expect(ReviewSearch.ranges(in: "abc", query: "").isEmpty, "An empty query marks nothing")
    }
}
