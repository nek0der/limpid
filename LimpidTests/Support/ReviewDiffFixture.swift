// ReviewDiffFixture.swift
// Limpid — a file's diff from a patch, and a comment being written on it, for the review suites.

import Foundation
import Testing
@testable import Limpid

enum ReviewDiffFixture {
    /// One line changed: the diff a test reads when what it is about is
    /// not the lines.
    static let oneLinePatch = "@@ -1,1 +1,1 @@\n-old\n+new"

    /// `file`'s diff, parsed from `patch`, as the repository answered it
    /// with `fingerprint`.
    static func diff(of file: ReviewFile, fingerprint: String, patch: String = oneLinePatch) throws -> ReviewDiff {
        try ReviewDiff(file: file, fingerprint: fingerprint, lines: ReviewDiffParser.parse(patch))
    }

    /// `file`'s diff rewriting its first `lines` lines, one hunk of every
    /// old line removed and a new one added; fingerprinted by its path
    /// unless `fingerprint` says otherwise. For the stack's tests, where a
    /// file's height is what its line count decides.
    static func rewritten(_ file: ReviewFile, lines: Int = 1, fingerprint: String? = nil) throws -> ReviewDiff {
        let removed = (0..<lines).map { "-old \($0)" }
        let added = (0..<lines).map { "+new \($0)" }
        let patch = (["@@ -1,\(lines) +1,\(lines) @@"] + removed + added).joined(separator: "\n")
        return try ReviewDiff(file: file, fingerprint: fingerprint ?? file.path, lines: ReviewDiffParser.parse(patch))
    }

    /// A new comment being written on the lines of `diff` that `isOn`
    /// picks, in `side`'s column.
    static func composer(
        on diff: ReviewDiff,
        side: ReviewSide? = nil,
        where isOn: (ReviewLine) -> Bool = { $0.kind == .added },
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ReviewComposerState {
        let lines = diff.lines.filter(isOn)
        let first = try #require(lines.first, sourceLocation: sourceLocation)
        let last = try #require(lines.last, sourceLocation: sourceLocation)
        var composer = ReviewComposerState()
        composer.compose(start: first.id, end: last.id, side: side)
        composer.text = "Why this?"
        return composer
    }
}
