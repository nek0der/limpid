// WorktreeFixture.swift
// Limpid — one builder for the throwaway `Worktree` values that
// several suites need.
//
// Three suites had each grown their own, differing only in which
// fields they let the caller set, which is how the next one ends up
// disagreeing about a default. `PRInfoFixture` exists for the same
// reason.
//
// The path is a fresh tmp URL per call unless the caller pins one:
// nothing here touches disk, but two worktrees that share a path
// would make a test pass for the wrong reason.

import Foundation
@testable import Limpid

enum WorktreeFixture {
    static func make(
        label: String = "wt",
        workingDirectory: URL? = nil,
        origin: WorktreeOrigin = .gitWorktree,
        isHidden: Bool = false,
        isMissing: Bool = false
    ) -> Worktree {
        var worktree = Worktree(
            label: label,
            workingDirectory: workingDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("limpid-worktree-\(UUID().uuidString)"),
            origin: origin,
            isHidden: isHidden
        )
        worktree.isMissing = isMissing
        return worktree
    }
}
