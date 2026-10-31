// UncommittedCarryRules.swift
// Weir — when a worktree's uncommitted changes can be carried into a new one, and how Git's answers about them read.

import Foundation

/// Why a worktree's uncommitted changes are not carried. Each is
/// found before anything is made or touched, so the worktree they are in
/// stays exactly as it was.
package enum UncommittedCarryRefusal: Error, Equatable, Sendable {
    /// The branch has no commit yet: there is nothing to put the changes on.
    case noCommit
    /// A merge, rebase, cherry-pick, or revert is under way: its state is
    /// the person's to finish, not ours to move.
    case operationInProgress
    /// The index holds conflicts to resolve.
    case unmergedPaths
    /// A sparse checkout or a split index: the working tree or the index
    /// is not the whole of what Git knows, which the carry reads it as.
    case unsupportedCheckout
    /// A file is marked skip-worktree or assume-unchanged, or added with
    /// `git add -N`: only the index holds that, and taking the changes away
    /// puts a new index in its place.
    case indexOnlyState
    /// A tracked file at this path is a folder now, with files Git ignores
    /// in it: going back to the file would remove them, and they are
    /// carried nowhere.
    case ignoredFilesInTheWay(String)
    /// A submodule's pointer, or a repository inside the worktree, changes:
    /// its own changes are its own repository's, which a tree cannot hold.
    case submodules
    /// The changes do not apply on the new worktree's start: these paths
    /// conflict.
    case conflicts([String])
    /// Git is older than 2.40, which `merge-tree --merge-base` needs.
    case unsupportedGit
    /// Git failed otherwise; its own words.
    case git(String)
}

/// The rules the carry follows, apart from running Git, so each reads on
/// its own and a test drives it with Git's output as text.
package enum UncommittedCarryRules {
    /// The first reason the worktree's state stops the carry, before its
    /// changes are read.
    package static func refusal(
        hasCommit: Bool,
        isOperationInProgress: Bool,
        usesSparseCheckout: Bool,
        usesSplitIndex: Bool
    ) -> UncommittedCarryRefusal? {
        if !hasCommit {
            return .noCommit
        }
        if isOperationInProgress {
            return .operationInProgress
        }
        if usesSparseCheckout || usesSplitIndex {
            return .unsupportedCheckout
        }
        return nil
    }

    /// The files under way of a merge, rebase, cherry-pick, or revert, each
    /// a path in the worktree's Git folder that Git keeps while it runs.
    package static let operationMarkers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"]

    /// Whether `git ls-files -v` shows state only the index holds: its tag
    /// in lower case for assume-unchanged, `S` for skip-worktree; and an
    /// intent-to-add entry, which `write-tree` leaves out, as more entries
    /// in the index than in the tree written from it.
    package static func hasIndexOnlyState(tags: [Character], indexEntries: Int, treeEntries: Int) -> Bool {
        tags.contains { $0.isLowercase || $0 == "S" } || indexEntries > treeEntries
    }

    /// How many files `git status --porcelain=v1 -z` lists, counted as the
    /// sidebar counts them: one per entry, a rename or a copy counting once
    /// although the path it came from follows it.
    package static func changedFileCount(porcelain: String) -> Int {
        var count = 0
        var fields = porcelain.split(separator: "\0", omittingEmptySubsequences: true)[...]
        while let entry = fields.popFirst() {
            count += 1
            // `XY path`: a rename or copy in either column names its source
            // in the next field.
            let status = entry.prefix(2)
            if status.contains("R") || status.contains("C") {
                _ = fields.popFirst()
            }
        }
        return count
    }

    /// Whether `git diff-tree -r -z` (its raw form) changes a gitlink: a
    /// submodule's pointer, or a repository inside the worktree that
    /// `git add` would take as one.
    package static func touchesGitlinks(rawDiff: String) -> Bool {
        // Each change is `:<old mode> <new mode> <old> <new> <status>`, then
        // its path in a field of its own.
        rawDiff.split(separator: "\0").contains { field in
            field.hasPrefix(":") && field.dropFirst().split(separator: " ").prefix(2).contains("160000")
        }
    }

    /// The conflicted paths in what `git merge-tree --write-tree
    /// --name-only --no-messages` printed when it found conflicts: the
    /// lines after the tree's, up to the first blank one.
    package static func conflictPaths(mergeTreeOutput: String) -> [String] {
        let lines = mergeTreeOutput.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        var paths: [String] = []
        for line in lines {
            if line.isEmpty {
                break
            }
            if !paths.contains(String(line)) {
                paths.append(String(line))
            }
        }
        return paths
    }

    /// Whether `git merge-tree` failed because it does not know an option
    /// we gave it, as a Git before 2.40 says of `--merge-base`: its usage
    /// exit, or its own words.
    package static func isUnknownOption(exitCode: Int32, stderr: String) -> Bool {
        exitCode == 129 || stderr.localizedCaseInsensitiveContains("unknown option")
    }
}
