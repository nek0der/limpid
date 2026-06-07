// WorktreeErrors.swift
// Limpid — typed errors raised by the worktree CRUD pipelines in
// `WindowSession+Worktree.swift`. Kept in its own file so the
// async-pipeline code can stay focused on the happy path; UI alert
// surfaces (`worktreeOperationError` state in the sidebar) decode
// these via `LocalizedError.errorDescription`.

import Foundation

enum CreateWorktreeError: Error, LocalizedError {
    case projectNotFound
    case missingBranchName
    case pathAlreadyExists(URL)
    case gitFailed(stderr: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            String(localized: "Project not found.")
        case .missingBranchName:
            String(localized: "Enter a branch name for the new worktree.")
        case let .pathAlreadyExists(url):
            String(localized: "A folder already exists at \(url.path).")
        case let .gitFailed(stderr):
            stderr.isEmpty
                ? String(localized: "git worktree add failed.")
                : stderr
        }
    }
}

enum DeleteWorktreeError: Error, LocalizedError {
    case projectNotFound
    case worktreeNotFound
    case dirtyNeedsForce
    case gitFailed(stderr: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            String(localized: "Project not found.")
        case .worktreeNotFound:
            String(localized: "Worktree not found.")
        case .dirtyNeedsForce:
            String(localized: "Worktree has uncommitted changes. Retry with Force to delete anyway.")
        case let .gitFailed(stderr):
            stderr.isEmpty
                ? String(localized: "git worktree remove failed.")
                : stderr
        }
    }
}
