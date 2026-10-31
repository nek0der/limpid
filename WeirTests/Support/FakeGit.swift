// FakeGit.swift
// Weir — scripted `GitRunning` fake for worktree pipeline tests.

import Foundation
import os
@testable import Weir

/// Scriptable, observable fake of `GitRunning`, the narrow Git surface the
/// worktree pipeline, the new worktree sheet, and the session launch
/// consume. Failures are returned as
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
        var nextCreateError: GitProcessError?
        var leavesFolderOnError = false
        var pruneCalls: [URL] = []
        var nextRemoveResult: GitResult = .init(exitCode: 0, stdout: "", stderr: "")
        var branchCalls: [BranchCall] = []
        var nextBranchResult: GitResult = .init(exitCode: 0, stdout: "", stderr: "")
        var createsDirectoryOnSuccess = false
        var fetchCalls: [String] = []
        var nextFetchResult: GitResult = .init(exitCode: 0, stdout: "", stderr: "")
        var nextFetchError: GitProcessError?
        var ignored: [String] = []
        var nextListIgnoredError: GitProcessError?
        var behind: Int?
        var operations: [String] = []
        var fetchRefCalls: [String] = []
        var nextFetchedRef = FetchedRef(
            result: .init(exitCode: 0, stdout: "", stderr: ""),
            commit: "0000000000000000000000000000000000000001"
        )
    }

    /// What the next `fetchRef(...)` brings. Default is a success at a
    /// made-up commit.
    var nextFetchedRef: FetchedRef {
        get { state.withLock { $0.nextFetchedRef } }
        set { state.withLock { $0.nextFetchedRef = newValue } }
    }

    /// Each `fetchRef(...)` as `<remote> <ref>`, in order.
    var fetchRefCalls: [String] {
        state.withLock { $0.fetchRefCalls }
    }

    /// Next result returned from `fetch(...)`. Default is a success.
    var nextFetchResult: GitResult {
        get { state.withLock { $0.nextFetchResult } }
        set { state.withLock { $0.nextFetchResult = newValue } }
    }

    /// Thrown from the next `fetch(...)` instead of a result: a remote that
    /// did not answer in time.
    var nextFetchError: GitProcessError? {
        get { state.withLock { $0.nextFetchError } }
        set { state.withLock { $0.nextFetchError = newValue } }
    }

    /// The remotes fetched, in order.
    var fetchCalls: [String] {
        state.withLock { $0.fetchCalls }
    }

    /// What `listIgnored(...)` returns.
    var ignored: [String] {
        get { state.withLock { $0.ignored } }
        set { state.withLock { $0.ignored = newValue } }
    }

    /// This is thrown from `listIgnored(...)` instead of the list, as when
    /// Git could not list the folder's ignored files.
    var nextListIgnoredError: GitProcessError? {
        get { state.withLock { $0.nextListIgnoredError } }
        set { state.withLock { $0.nextListIgnoredError = newValue } }
    }

    /// What `commitsBehind(...)` returns.
    var behind: Int? {
        get { state.withLock { $0.behind } }
        set { state.withLock { $0.behind = newValue } }
    }

    /// The calls whose order the suites check, by name (`fetch`,
    /// `fetch ref`, `branch`, `worktree add`, `ls-files`), in the order they
    /// came. Prune, remove, and `commitsBehind` are not recorded here.
    var operations: [String] {
        state.withLock { $0.operations }
    }

    struct BranchCall {
        let repoRoot: URL
        let name: String
        let startPoint: String
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Next result returned from `createWorktree(...)`. Default is a success.
    var nextCreateResult: GitResult {
        get { state.withLock { $0.nextCreateResult } }
        set { state.withLock { $0.nextCreateResult = newValue } }
    }

    /// Thrown from the next `createWorktree(...)` instead of a result, as
    /// `GitProcess` throws a run past its deadline.
    var nextCreateError: GitProcessError? {
        get { state.withLock { $0.nextCreateError } }
        set { state.withLock { $0.nextCreateError = newValue } }
    }

    /// Whether a create that throws leaves its folder behind, as a
    /// `git worktree add` stopped part way does.
    var leavesFolderOnError: Bool {
        get { state.withLock { $0.leavesFolderOnError } }
        set { state.withLock { $0.leavesFolderOnError = newValue } }
    }

    var pruneCalls: [URL] {
        state.withLock { $0.pruneCalls }
    }

    /// Next result returned from `removeWorktree(...)`. Default is a success.
    var nextRemoveResult: GitResult {
        get { state.withLock { $0.nextRemoveResult } }
        set { state.withLock { $0.nextRemoveResult = newValue } }
    }

    /// Next result returned from `createBranch(...)`. Default is a success.
    var nextBranchResult: GitResult {
        get { state.withLock { $0.nextBranchResult } }
        set { state.withLock { $0.nextBranchResult = newValue } }
    }

    var branchCalls: [BranchCall] {
        state.withLock { $0.branchCalls }
    }

    /// Whether a successful create makes the worktree's folder, so setup
    /// steps have somewhere to run.
    var createsDirectoryOnSuccess: Bool {
        get { state.withLock { $0.createsDirectoryOnSuccess } }
        set { state.withLock { $0.createsDirectoryOnSuccess = newValue } }
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
        let (result, error, leavesFolder) = state.withLock {
            $0.createCalls.append(.init(
                repoRoot: repoRoot,
                path: path,
                baseBranch: baseBranch,
                newBranchName: newBranchName
            ))
            $0.operations.append("worktree add")
            return ($0.nextCreateResult, $0.nextCreateError, $0.leavesFolderOnError)
        }
        if let error {
            if leavesFolder {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data("half".utf8).write(to: path.appendingPathComponent("checked-out.txt"))
            }
            throw error
        }
        if result.succeeded, createsDirectoryOnSuccess {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        return result
    }

    func createBranch(repoRoot: URL, name: String, startPoint: String) async throws -> GitResult {
        state.withLock {
            $0.branchCalls.append(.init(repoRoot: repoRoot, name: name, startPoint: startPoint))
            $0.operations.append("branch")
            return $0.nextBranchResult
        }
    }

    func pruneWorktrees(repoRoot: URL) async throws -> GitResult {
        state.withLock {
            $0.pruneCalls.append(repoRoot)
            return .success()
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

    func fetch(repoRoot: URL, remote: String, branch: String) async throws -> GitResult {
        let (result, error) = state.withLock {
            $0.fetchCalls.append(remote)
            $0.operations.append("fetch")
            return ($0.nextFetchResult, $0.nextFetchError)
        }
        if let error {
            throw error
        }
        return result
    }

    func fetchRef(repoRoot: URL, remote: String, ref: String) async throws -> FetchedRef {
        state.withLock {
            $0.fetchRefCalls.append("\(remote) \(ref)")
            $0.operations.append("fetch ref")
            return $0.nextFetchedRef
        }
    }

    func listIgnored(repoRoot: URL) async throws -> [String] {
        let (ignored, error) = state.withLock {
            $0.operations.append("ls-files")
            return ($0.ignored, $0.nextListIgnoredError)
        }
        if let error {
            throw error
        }
        return ignored
    }

    func commitsBehind(repoRoot: URL, local: String, upstream: String) async -> Int? {
        state.withLock { $0.behind }
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
