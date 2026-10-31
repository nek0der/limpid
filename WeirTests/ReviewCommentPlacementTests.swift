// ReviewCommentPlacementTests.swift
// Weir — where a comment sits: its run of lines, the split layout, the row list, and the composer.

import Foundation
import Testing
@testable import Weir

struct ReviewCommentPlacementTests {
    /// A comment can cover a run of lines. The run has to reach the prompt, the
    /// gutter, and the row under which the comment is drawn.
    @Test func commentCoversARunOfLinesEndToEnd() throws {
        var selection = ReviewSelection()
        #expect(selection.isEmpty, "New selection is empty")
        selection.select(5)
        #expect(selection.contains(5) && !selection.contains(6), "Single line")
        selection.extend(to: 8)
        #expect(selection.startLineID == 5 && selection.endLineID == 8, "Extended downward")
        selection.extend(to: 2)
        #expect(selection.startLineID == 2 && selection.endLineID == 5, "Extending past the anchor turns the run around")
        selection.select(9)
        #expect(selection.startLineID == 9 && selection.endLineID == 9, "Selecting collapses the run")

        let file = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let comment = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 3, oldLine: 10, newLine: 12),
            end: ReviewAnchor(lineID: 6, oldLine: nil, newLine: 15),
            code: "a\nb", body: "Extract this."
        )
        #expect(Array(comment.lineIDs) == [3, 4, 5, 6], "Run covers its lines")
        #expect(comment.oldSpan == "10" && comment.newSpan == "12-15", "One-sided run reads as a single number")
        let prompt = try ReviewPromptBuilder.build(
            root: URL(fileURLWithPath: "/tmp/x"),
            comments: [comment],
            locale: Locale(identifier: "en")
        ).text
        #expect(prompt.contains("lines=\"12-15\" side=\"new\""), "Prompt carries the run")
        let counts = ReviewRowBuilder.lineCommentCounts(comments: [comment], fileID: file.id)
        #expect(counts[3] == 1 && counts[5] == 1 && counts[6] == 1, "Gutter marks every line of the run")
        #expect(counts[7] == nil, "Gutter marks nothing past the run")
    }

    /// The split layout is a second view of one parsed diff. Nothing about the
    /// lines changes — the ids a comment is anchored by are the same — so the
    /// things worth pinning down are the pairing itself and the property the
    /// selection depends on: a column's visible run is the unified id range
    /// filtered by which side has a position.
    @Test func sideBySidePairsTheSameLinesTheUnifiedLayoutShows() throws {
        let lines = try ReviewDiffParser.parse("@@ -1,5 +1,4 @@\n ctx\n-a\n-b\n-c\n+x\n+y\n tail\n")
        let elements = ReviewSideBySideBuilder.elements(for: lines)
        let startsWithTheHunk = if case .hunk = elements.first {
            true
        } else {
            false
        }
        #expect(startsWithTheHunk, "The hunk header is still a row of its own")
        let pairs = elements.compactMap { element -> ReviewSplitPair? in
            guard case let .pair(pair) = element else { return nil }
            return pair
        }
        try #require(pairs.count == 5, "One row per context line and per replaced line")
        #expect(pairs[0].old?.id == pairs[0].new?.id, "A context line is one line drawn in both columns")
        #expect(pairs[1].old?.text == "a" && pairs[1].new?.text == "x", "Changes pair by position")
        #expect(pairs[2].old?.text == "b" && pairs[2].new?.text == "y", "Changes pair by position")
        #expect(pairs[3].old?.text == "c" && pairs[3].new == nil, "The longer column runs on against a placeholder")
        #expect(pairs[4].old?.id == pairs[4].new?.id, "The block ends at the next context line")

        // The property the selection rests on. Without it a run started in one
        // column would have to be stored as an explicit set of ids.
        for side in ReviewSide.allCases {
            let visible = pairs.compactMap { $0.line(on: side) }.map(\.id)
            let first = try #require(visible.first, "A column drew nothing")
            let last = try #require(visible.last, "A column drew nothing")
            let filtered = lines
                .filter { $0.id >= first && $0.id <= last && side.position(of: $0) != nil }
                .map(\.id)
            #expect(visible == filtered, "A column's run is the id range filtered by side")
        }
        var selection = ReviewSelection()
        selection.select(pairs[0].new?.id, on: .new)
        selection.extend(to: pairs[2].new?.id ?? -1)
        #expect(
            pairs[1].new.map { selection.contains($0.id, on: .new) } == true,
            "The column the run was started in is highlighted"
        )
        #expect(
            pairs[1].old.map { selection.contains($0.id, on: .old) } == false,
            "The other column is not"
        )

        // `\ No newline at end of file` annotates the line above it. Paired as
        // a line of its own it would sit opposite unrelated code.
        let marked = try ReviewDiffParser.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n")
        let markedPairs = ReviewSideBySideBuilder.elements(for: marked).compactMap { element -> ReviewSplitPair? in
            guard case let .pair(pair) = element else { return nil }
            return pair
        }
        try #require(markedPairs.count == 2, "The marker is a row, not a line")
        #expect(
            markedPairs[0].old?.text == "a" && markedPairs[0].new?.text == "b",
            "The marker did not push its line out of its pair"
        )
        #expect(
            markedPairs[1].old?.kind == .marker && markedPairs[1].new == nil,
            "The marker stays on the side it annotates"
        )

        for (patch, side) in [("@@ -0,0 +1,2 @@\n+x\n+y\n", ReviewSide.new), ("@@ -1,2 +0,0 @@\n-a\n-b\n", .old)] {
            let onlyPairs = try ReviewSideBySideBuilder
                .elements(for: ReviewDiffParser.parse(patch))
                .compactMap { element -> ReviewSplitPair? in
                    guard case let .pair(pair) = element else { return nil }
                    return pair
                }
            #expect(onlyPairs.count == 2, "A one-sided block is two rows")
            #expect(
                onlyPairs.allSatisfy { $0.line(on: side) != nil && $0.line(on: side.other) == nil },
                "A one-sided block draws placeholders opposite it"
            )
        }

        // A comment is written against a line, not against a layout: it comes
        // back under the same line whichever way the diff is being read.
        let file = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let diff = ReviewDiff(file: file, fingerprint: "f", lines: lines)
        let start = try #require(pairs[1].new?.id, "New-side run missing")
        let end = try #require(pairs[2].new?.id, "New-side run missing")
        let comment = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: start, oldLine: nil, newLine: 2),
            end: ReviewAnchor(lineID: end, oldLine: nil, newLine: 3),
            side: .new, code: "x\ny", body: "The new side only."
        )
        for layout in ReviewDiffLayout.allCases {
            let rows = ReviewRowBuilder.rows(
                expanded: diff, comments: [comment], composerLineID: nil, layout: layout
            )
            let found = rows.firstIndex { row in
                if case .comment = row.kind {
                    return true
                }
                return false
            }
            let index = try #require(found, "The comment is missing in \(layout.rawValue)")
            #expect(
                index > 0 && rows[index - 1].contains(lineID: comment.lastLineID),
                "The card sits under the row that draws the run's last line"
            )
        }
    }

    /// The rendered list is no longer the parsed diff: Git's file metadata is
    /// dropped, comments sit under their line, and the composer opens in place.
    @Test func rowListDropsFileMetadataAndPlacesCommentsOnTheirLine() throws {
        let file = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let other = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        let lines = try ReviewDiffParser.parse("diff --git a/a b/a\nindex 1..2 100644\n@@ -1 +1 @@\n-a\n+b\n")
        let diff = ReviewDiff(file: file, fingerprint: "f", lines: lines)
        let removed = try #require(lines.first { $0.kind == .removed }, "Removed line")
        let comment = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: removed.id, oldLine: removed.oldLine, newLine: nil), code: removed.text, body: "Explain this."
        )
        let built = ReviewRowBuilder.rows(
            expanded: diff, comments: [comment], composerLineID: removed.id
        )
        // One hunk separator, both code lines, the comment and the composer.
        // The two metadata lines contribute nothing, the file's name is a fixed
        // bar above the scroll, and the other changed file belongs to the rail.
        try #require(built.count == 5, "Row count: \(built.count)")
        #expect(
            !built.contains { ($0.line?.text ?? "").hasPrefix("diff --git") || ($0.line?.text ?? "").hasPrefix("index ") },
            "File metadata is not rendered"
        )
        let kinds = built.map(\.kind)
        let isInOrder = if case .hunk = kinds[0], case .code = kinds[1], case .comment = kinds[2],
                           case .composer = kinds[3], case .code = kinds[4]
        {
            true
        } else {
            false
        }
        #expect(isInOrder, "Row order")
        #expect(
            ReviewRowBuilder.lineCommentCounts(comments: [comment], fileID: file.id) == [removed.id: 1],
            "Gutter counts are keyed by line"
        )
        #expect(
            ReviewRowBuilder.lineCommentCounts(comments: [comment], fileID: other.id).isEmpty,
            "Counts do not leak across files"
        )
    }

    /// An abandoned edit used to survive into the next added comment, which
    /// then overwrote the comment that had been under edit.
    @Test func composerDoesNotCarryAnAbandonedEditIntoTheNextComment() {
        let file = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let existing = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 4, oldLine: 4, newLine: nil),
            code: "let a = 1", body: "The original comment."
        )
        var state = ReviewComposerState()
        #expect(!state.isOpen, "Starts closed")

        state.edit(existing)
        #expect(state.lineID == existing.lineID, "Edit anchors to the comment's line")
        #expect(state.editingCommentID == existing.id && state.text == existing.body, "Edit target")

        state.cancel()
        #expect(!state.isOpen && state.editingCommentID == nil && state.text.isEmpty, "Cancel clears the edit")

        state.edit(existing)
        state.compose(start: 9, end: 9, side: nil)
        #expect(state.editingCommentID == nil, "Opening on another line drops the edit target")
        #expect(state.lineID == 9 && state.text.isEmpty, "Opening starts empty")

        // The same line as the edited comment must still be an add, not an edit.
        state.edit(existing)
        state.compose(start: existing.lineID, end: existing.lineID, side: nil)
        #expect(state.editingCommentID == nil, "Reopening the same line is an add")

        // A run keeps both ends, whichever direction it was selected in.
        state.compose(start: 12, end: 8, side: nil)
        #expect(state.startLineID == 8 && state.lineID == 12, "Composer normalizes the run it covers")

        // Extending the selection with the composer open grows what it covers
        // rather than throwing away what has been typed.
        state.text = "half written"
        state.retarget(start: 8, end: 20, side: nil)
        #expect(state.lineID == 20 && state.text == "half written", "Extending lost the draft")
        // An existing comment's run is its own; editing does not follow.
        state.edit(existing)
        state.retarget(start: 1, end: 99, side: nil)
        #expect(state.lineID == existing.lastLineID, "Editing followed the selection")
    }
}
