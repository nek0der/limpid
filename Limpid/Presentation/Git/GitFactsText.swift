// GitFactsText.swift
// Limpid — a session's Git facts in words: the chips, and the sidebar row's second line at rest.

import Foundation

enum GitFactsText {
    /// "3 Commits": commits the default branch does not have.
    static func commitsChip(_ count: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "\(count) Commits",
            comment: "Worktree header chip and sidebar row: commits on the branch that the default branch does not have"
        ).resolved(in: locale)
    }

    /// "2 Uncommitted": files changed and not committed.
    static func uncommittedChip(_ files: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "\(files) Uncommitted",
            comment: "Worktree header chip and sidebar row: files changed and not committed"
        ).resolved(in: locale)
    }

    /// What a chip counts, which stays its identity as the count changes.
    enum ChipKind: String {
        case commits
        case uncommitted
    }

    struct Chip: Equatable {
        let kind: ChipKind
        let text: String
    }

    /// The chips after the pull request's, in the order the header shows
    /// them: commits, then uncommitted files. None for a count of 0.
    /// No commits chip on the default branch (`GitFacts.proposedCommits`),
    /// nor once the request is merged: a squash merge leaves the branch's
    /// commits off the default branch, and counting them would read as work
    /// still to propose.
    static func chips(_ facts: GitFacts?, isPullRequestMerged: Bool, locale: Locale) -> [Chip] {
        guard let facts else { return [] }
        var chips: [Chip] = []
        if !isPullRequestMerged, facts.proposedCommits > 0 {
            chips.append(Chip(kind: .commits, text: commitsChip(facts.proposedCommits, locale: locale)))
        }
        if facts.uncommittedFiles > 0 {
            chips.append(Chip(kind: .uncommitted, text: uncommittedChip(facts.uncommittedFiles, locale: locale)))
        }
        return chips
    }
}
