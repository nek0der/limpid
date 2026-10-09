// WorktreeErrors.swift
// Limpid — typed errors raised by the worktree CRUD pipelines in
// `WindowSession+Worktree.swift`. Kept in its own file so the
// async-pipeline code can stay focused on the happy path; UI alert
// surfaces (`worktreeOperationError` state in the sidebar) keep the
// error and draw its `message` in the window's locale.

import Foundation

// Each error's catalog text comes from a plain, non-optional `switch` over
// literals: the string catalog's extraction reads those, and misses a
// literal handed to `.localized(...)` inside a conditional expression.

enum CreateWorktreeError: LimpidLocalizedError {
    case projectNotFound
    case missingBranchName
    case pathAlreadyExists(URL)
    case gitFailed(stderr: String)

    /// git's own stderr when it said something, else our sentence.
    var message: DisplayText {
        if case let .gitFailed(stderr) = self, !stderr.isEmpty {
            return .verbatim(stderr)
        }
        return .localized(text)
    }

    private var text: LocalizedStringResource {
        switch self {
        case .projectNotFound: "Project not found."
        case .missingBranchName: "Enter a branch name for the new worktree."
        case let .pathAlreadyExists(url): "A folder already exists at \(url.path)."
        case .gitFailed: "git worktree add failed."
        }
    }
}

enum DeleteWorktreeError: LimpidLocalizedError {
    case projectNotFound
    case worktreeNotFound
    case dirtyNeedsForce
    case submodulesNeedForce
    case gitFailed(stderr: String)

    /// git's own stderr when it said something, else our sentence.
    var message: DisplayText {
        if case let .gitFailed(stderr) = self, !stderr.isEmpty {
            return .verbatim(stderr)
        }
        return .localized(text)
    }

    private var text: LocalizedStringResource {
        switch self {
        case .projectNotFound: "Project not found."
        case .worktreeNotFound: "Worktree not found."
        case .dirtyNeedsForce: "Worktree has uncommitted changes. Retry with Force to delete anyway."
        case .submodulesNeedForce: "Worktree contains initialized submodules. Retry with Force to delete anyway."
        case .gitFailed: "git worktree remove failed."
        }
    }
}
