// ReviewStackFixture.swift
// Weir — stacked diffs as the review tab builds them, for the tests of the stack and the table that draws it.

import Foundation
@testable import Weir

/// The review draws every file under its header, so a table test that
/// is about one file's rows still draws them as the stack does: the file's
/// header at row 0, and `rows` from row 1.
enum ReviewStackFixture {
    static func open(
        _ file: ReviewFile,
        rows: [ReviewRow],
        lines: [ReviewLine],
        counts: [Int: Int] = [:]
    ) -> ReviewStack {
        var input = ReviewStackBuilder.Input(files: [file], slots: [file.id: 0])
        input.open = ReviewDiff(file: file, fingerprint: file.path, lines: lines)
        input.openRows = rows
        input.openCounts = counts
        // The open file is the only one listed: no other file's rows are
        // ever asked for.
        return ReviewStackBuilder.build(input) { _, _, _ in ReviewStackPiece(rows: []) }
    }

    /// Each file's place in `files`, as the stack slots them.
    static func slots(_ files: [ReviewFile]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.id, $0) })
    }

    /// `files` stacked as the review tab builds them: `open` drawn from its
    /// rows (its entry's diff, else one rewritten line), the others from
    /// what has been read of them, `entries`, or from a read that `failed`
    /// with its message.
    static func stack(
        _ files: [ReviewFile],
        open: ReviewFile?,
        entries: [ReviewFile: ReviewDiff],
        failed: [ReviewFile: LocalizedStringResource] = [:],
        viewed: Set<String> = [],
        unfolded: Set<String> = []
    ) throws -> ReviewStack {
        var input = ReviewStackBuilder.Input(files: files, slots: slots(files))
        input.viewed = viewed
        input.unfolded = unfolded
        if let open {
            let diff = try entries[open] ?? ReviewDiffFixture.rewritten(open)
            input.open = diff
            input.openRows = ReviewRowBuilder.rows(expanded: diff, comments: [], composerLineID: nil)
        }
        var read = Dictionary(uniqueKeysWithValues: entries.filter { $0.key != open }
            .map { ($0.key.id, ReviewStackEntry.loaded($0.value)) })
        for (file, message) in failed {
            read[file.id] = .failed(message)
        }
        input.entries = read
        return ReviewStackBuilder.build(input) { _, diff, offset in
            ReviewStackPiece.closed(diff, offset: offset, comments: [], staleCommentIDs: [], layout: .unified)
        }
    }
}
