// ReviewSourceCheck.swift
// Limpid — whether a file's whole text, read for unfolding, is the version its diff shows.

import Foundation

/// The whole text of a file is read after its diff, for unfolding, and can
/// be another version: newer, or the same file as a clean filter (`ident`,
/// LFS, a notebook stripper) shows it to the diff and not on disk. Unfolding
/// it would put lines of one version between the hunks of another, so it is
/// not offered then. Whether the file changed is the diff's fingerprint's
/// to say, not this.
enum ReviewSourceCheck {
    /// Every line the diff shows of the new side is in `source` at its line
    /// number, as written (both are read through `ReviewDiffParser.lines`).
    static func matches(_ source: [String], diff: ReviewDiff) -> Bool {
        diff.lines.allSatisfy { line in
            guard !line.isExpansion, line.kind == .context || line.kind == .added, let number = line.newLine else { return true }
            return source.indices.contains(number - 1) && source[number - 1] == line.text
        }
    }

    /// `source` where it is the diff's version, else nothing to unfold.
    static func unfoldable(_ source: [String], for diff: ReviewDiff) -> [String] {
        matches(source, diff: diff) ? source : []
    }
}
