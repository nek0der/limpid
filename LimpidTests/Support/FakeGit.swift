// FakeGit.swift
// Limpid — scripted `GitRunning` fake for worktree pipeline tests.

import Foundation
import os
@testable import Limpid

/// Scriptable, observable fake of the narrow Git surface
/// `WindowSession+Worktree` consumes. Failures are returned as
/// non-zero-exit `GitResult` rather than thrown errors so tests can
/// exercise the same code paths real `git` invocations take.
///
/// Swift 6 forbids `NSLock` from async contexts; we use
/// `OSAllocatedUnfairLock` whose `withLock` API is async-safe.
final class FakeGit: GitRunning, Sendable {
    struct CreateCall {
        let repoRoot: URL
        let path: URL
        let baseBranch: String
        let newBranchName: String?
    }

    struct RemoveCall {
        let repoRoot: URL
        let path: URL
        let force: Bool
    }

    private struct State {
        var createCalls: [CreateCall] = []
        var removeCalls: [RemoveCall] = []
        var nextCreateResult: GitResult = .init(exitCode: 0, stdout: "", stderr: "")
        var nextRemoveResult: GitResult = .init(exitCode: 0, stdout: "", stderr: "")
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Next result returned from `createWorktree(...)`. Default is a success.
    var nextCreateResult: GitResult {
        get { state.withLock { $0.nextCreateResult } }
        set { state.withLock { $0.nextCreateResult = newValue } }
    }

    /// Next result returned from `removeWorktree(...)`. Default is a success.
    var nextRemoveResult: GitResult {
        get { state.withLock { $0.nextRemoveResult } }
        set { state.withLock { $0.nextRemoveResult = newValue } }
    }

    var createCalls: [CreateCall] {
        state.withLock { $0.createCalls }
    }

    var removeCalls: [RemoveCall] {
        state.withLock { $0.removeCalls }
    }

    func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String?
    ) async throws -> GitResult {
        state.withLock {
            $0.createCalls.append(.init(
                repoRoot: repoRoot,
                path: path,
                baseBranch: baseBranch,
                newBranchName: newBranchName
            ))
            return $0.nextCreateResult
        }
    }

    func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult {
        state.withLock {
            $0.removeCalls.append(.init(repoRoot: repoRoot, path: path, force: force))
            return $0.nextRemoveResult
        }
    }
}

// MARK: - Convenience constructors

extension GitResult {
    static func success() -> GitResult {
        .init(exitCode: 0, stdout: "", stderr: "")
    }

    static func failure(_ stderr: String, exitCode: Int32 = 128) -> GitResult {
        .init(exitCode: exitCode, stdout: "", stderr: stderr)
    }
}
