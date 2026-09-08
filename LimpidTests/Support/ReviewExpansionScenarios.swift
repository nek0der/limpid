// ReviewExpansionScenarios.swift
// Limpid — unfolding the unchanged lines a unified diff leaves out.
//
// Its own file for the same reason as the lifecycle scenarios: the enum they
// extend had grown past what one type body should hold.

import Foundation
@testable import Limpid

extension ReviewValidationScenarios {
    /// Where the gaps in a patch are, and what unfolding one puts back.
    ///
    /// The invariant under all of it is that the patch does not move: a
    /// comment is anchored to a row id and a fingerprint the next `git diff`
    /// has to reproduce, and neither may depend on how much of the file the
    /// reader happened to open.
    static func expansion() throws {
        let patch = """
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
        let lines = try ReviewDiffParser.parse(patch)
        let source = (1...100).map { "line \($0)" }
        let gaps = ReviewExpansionPlan.gaps(in: lines, sourceCount: source.count)
        try require(gaps.count == 3, "Expected a gap before, between and after the hunks: \(gaps.count)")
        // Everything above the first hunk.
        try require(gaps[0].range == 1...19, "Leading gap: \(gaps[0].range)")
        try require(gaps[0].delta == 0, "Leading gap has no offset yet")
        // The first hunk added a line, so the sides have drifted by one below it.
        try require(gaps[1].range == 24...60, "Middle gap: \(gaps[1].range)")
        try require(gaps[1].delta == -1, "Middle gap offset: \(gaps[1].delta)")
        try require(gaps[2].range == 63...100, "Trailing gap: \(gaps[2].range)")
        try require(gaps[2].nextHunkID == nil, "The trailing gap has no hunk after it")
        // The ends of the file open one way each; the middle opens both.
        let closed = ReviewExpansionPlan.apply(to: lines, gaps: gaps, spans: [:], source: source)
        try require(closed.lines == lines, "Nothing unfolded must leave the patch alone")
        try require(closed.expanders.count == 3, "Every gap offers a control")
        try require(!closed.expanders[0].canExpandDown, "The top of the file has no hunk above it")
        try require(closed.expanders[1].canExpandUp && closed.expanders[1].canExpandDown, "A middle gap opens both ways")
        try require(!closed.expanders[2].canExpandUp, "The end of the file has no hunk below it")
        // Unfolding upward puts the lines immediately above the hunk back.
        let up = ReviewExpansionPlan.apply(
            to: lines,
            gaps: gaps,
            spans: [1: ReviewGapSpan(above: 3, below: 0)],
            source: source
        )
        let unfolded = up.lines.filter(\.isExpansion)
        try require(unfolded.map(\.newLine) == [58, 59, 60], "Unfolded upward: \(unfolded.map(\.newLine))")
        try require(unfolded.map(\.oldLine) == [57, 58, 59], "Old numbering follows the gap's offset")
        try require(unfolded.map(\.text) == ["line 58", "line 59", "line 60"], "Unfolded text comes from the file")
        try require(unfolded.allSatisfy { !$0.isCommentable }, "An unfolded line must not accept a comment")
        try require(
            up.lines.filter { !$0.isExpansion } == lines,
            "Unfolding must not touch the lines a comment is anchored to"
        )
        let upControl = try require(up.expanders.first { $0.gap == 1 }, "The gap still offers a control")
        try require(upControl.hidden == 34, "The control counts what is still folded")
        // Ahead of the lines the upward end revealed, not ahead of the hunk.
        // What is still folded lies between the two ends, and a control drawn
        // past the revealed lines said 34 lines were hidden between two that
        // are next to each other.
        try require(
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
        try require(middle == Array(24...60), "A gap opened from both ends: \(middle.count) lines")
        // A gap with nothing left folded keeps a control, at the head of what
        // it unfolded, or a reader who opened a file has no way back.
        let opened = try require(met.expanders.first { $0.gap == 1 }, "A fully unfolded gap offers no way back")
        try require(opened.hidden == 0 && opened.canCollapse, "The control does not offer to fold the gap again")
        // Ahead of the first line it revealed, not down beside the hunk: a
        // reader who opened a whole gap is at the top of it.
        try require(
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
        try require(beyond.first?.text.isEmpty == true, "A line past the end of the file reads as empty")
        // A hunk that starts at line one leaves no gap above it.
        let fromTop = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        try require(
            ReviewExpansionPlan.gaps(in: fromTop, sourceCount: 1).isEmpty,
            "A single-line file has nothing folded"
        )
        try searchInsideTheDiff(lines: lines, source: source, gaps: gaps)
        // `nil` is how both callers say the file's contents could not be read.
        // Nothing can be unfolded then — not the trailing run, whose size only
        // the file knows, and not the interior ones either, since there are no
        // lines to put there. Offering them drew a control that named a number
        // of hidden lines and did nothing when pressed.
        try require(
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
    private static func searchInsideTheDiff(lines: [ReviewLine], source: [String], gaps: [ReviewGap]) throws {
        let folded = ReviewRowBuilder.rows(
            expanded: ReviewDiff(file: file(), fingerprint: "f", lines: lines),
            comments: [],
            composerLineID: nil,
            source: source
        )
        try require(ReviewSearch.hits(in: folded, query: "").isEmpty, "An empty query matches nothing")
        try require(ReviewSearch.hits(in: folded, query: "ADDED").count == 2, "The search is case-insensitive")
        try require(ReviewSearch.hits(in: folded, query: "line 30").isEmpty, "A folded line is not on screen")
        let unfolded = ReviewRowBuilder.rows(
            expanded: ReviewDiff(file: file(), fingerprint: "f", lines: lines),
            comments: [],
            composerLineID: nil,
            source: source,
            gapSpans: [1: ReviewGapSpan(above: 0, below: 40)]
        )
        try require(ReviewSearch.hits(in: unfolded, query: "line 30").count == 1, "An unfolded line is searchable")
        let hit = try require(ReviewSearch.hits(in: unfolded, query: "line 30").first, "Hit missing")
        try require(hit.lineID == ReviewExpansionPlan.idBase + 30, "The hit names the line it was found on")
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
        try require(sided.count == 1, "A context line is one place to land: \(sided.count)")
        // A removed line and an added one are two lines drawn in one row, and
        // each still answers for its own column — the fold above keys on the
        // line's identity, not on what it says.
        try require(
            ReviewSearch.hits(in: split, query: "removed").map(\.side) == [.old],
            "A removed line belongs to the old column alone"
        )
        try require(
            ReviewSearch.hits(in: split, query: "also added").map(\.side) == [.new],
            "An added line belongs to the new column alone"
        )
        // Stepping wraps in both directions, and an empty result never moves.
        try require(ReviewSearch.step(2, by: 1, count: 3) == 0, "Find Next does not wrap")
        try require(ReviewSearch.step(0, by: -1, count: 3) == 2, "Find Previous does not wrap")
        try require(ReviewSearch.step(4, by: 1, count: 0) == 0, "Stepping with nothing found must stay put")
        // The highlight marks every occurrence on a line, and marks the same
        // text the count was taken from.
        try require(ReviewSearch.ranges(in: "one two one", query: "one").count == 1, "One mark per matching line")
        try require(ReviewSearch.ranges(in: "abc", query: "").isEmpty, "An empty query marks nothing")
    }

    /// What the lexer colors, and what it deliberately does not.
    static func syntax() throws {
        let swift = try require(ReviewSyntax.language(for: "a/b/File.swift"), "Swift is not recognized")
        // A keyword is a whole word: `information` starts with `in` and is
        // left alone. `class` is colored wherever it appears — the lexer reads
        // one line at a time and does not look back at the `.` before it, so a
        // member with a keyword's name is colored like the keyword.
        let words = ReviewSyntax.tokens(in: "let information = value.class", language: swift)
        try require(words.count == 2, "Expected `let` and `class`: \(words.count)")
        try require(words.allSatisfy { $0.kind == .keyword }, "Both are keywords")
        let line = "let name = \"text\" // let"
        let mixed = ReviewSyntax.tokens(in: line, language: swift)
        try require(mixed.map(\.kind) == [.keyword, .string, .comment], "Kinds: \(mixed.map(\.kind))")
        // The comment runs to the end of the line, and the keyword inside it
        // is part of the comment rather than a keyword of its own.
        try require(String(line[mixed[2].range]) == "// let", "Comment: \(String(line[mixed[2].range]))")
        try require(String(line[mixed[1].range]) == "\"text\"", "The quotes belong to the string")
        // An escaped quote does not end the string, and one that never closes
        // ends with the line: a diff cuts lines wherever the change did.
        let escaped = ReviewSyntax.tokens(in: "\"a\\\"b\" x", language: swift)
        try require(escaped.first.map { String("\"a\\\"b\" x"[$0.range]) } == "\"a\\\"b\"", "Escapes end the string early")
        let open = ReviewSyntax.tokens(in: "\"unterminated", language: swift)
        try require(open.count == 1 && open[0].kind == .string, "An unterminated string is still a string")
        // Numbers, but not the digits inside a name.
        try require(ReviewSyntax.tokens(in: "x = 42", language: swift).contains { $0.kind == .number }, "42 is a number")
        try require(
            !ReviewSyntax.tokens(in: "utf8 = utf8", language: swift).contains { $0.kind == .number },
            "The 8 in utf8 is part of the word"
        )
        // Swift's attributes and directives are open-ended, so they are read
        // off the sigil rather than from a list.
        try require(
            ReviewSyntax.tokens(in: "@MainActor func run()", language: swift).count(where: { $0.kind == .keyword }) == 2,
            "An attribute is a keyword"
        )
        // A shell reads `$` the same way, and comments with `#`.
        let shell = try require(ReviewSyntax.language(for: "run.sh"), "Shell is not recognized")
        let script = ReviewSyntax.tokens(in: "echo $HOME # done", language: shell)
        try require(script.map(\.kind) == [.keyword, .comment], "Shell kinds: \(script.map(\.kind))")
        // A file we do not know is drawn plain rather than guessed at.
        try require(ReviewSyntax.language(for: "notes.unknownext") == nil, "An unknown extension has no language")
        try require(ReviewSyntax.tokens(in: "", language: swift).isEmpty, "An empty line has nothing to color")
        // A character `isNumber` calls a number but no literal is written
        // with. A token that started on one used to be empty, and the scan
        // that never moved past it hung the thread that was drawing the line.
        try require(ReviewSyntax.tokens(in: "* ② step", language: swift).isEmpty, "A numeral that is not a digit")
        try require(ReviewSyntax.tokens(in: "½ ٣ Ⅳ", language: swift).isEmpty, "Numerals from other scripts")
    }

    private static func file() -> ReviewFile {
        ReviewFile(path: "a.txt", layer: .unstaged, status: .modified)
    }
}
