// WorktreeFixture.swift
// Weir — one builder for the throwaway `Worktree` values that
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
@testable import Weir
@testable import WeirDomain

enum WorktreeFixture {
    static func make(
        label: String = "wt",
        workingDirectory: URL? = nil,
        origin: WorktreeOrigin = .gitWorktree,
        isHidden: Bool = false,
        isMissing: Bool = false,
        admission: WorktreeAdmission? = nil
    ) -> Worktree {
        Worktree(
            label: label,
            workingDirectory: workingDirectory ?? freshPath(),
            origin: origin,
            isHidden: isHidden,
            missingSince: isMissing ? Date(timeIntervalSince1970: 0) : nil,
            admission: admission
        )
    }

    /// A folder for a worktree that does not exist yet, under the temporary
    /// directory, so a creation's "path already exists" guard never fires
    /// for the path a test means to succeed.
    static func freshPath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("weir-worktree-\(UUID().uuidString)")
    }
}
