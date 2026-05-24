// GitRunning.swift
// Narrow protocol over the GitProcess operations the worktree CRUD
// pipeline calls. Letting WindowSession+Worktree take an injectable
// `any GitRunning` lets the unit tests script success / failure cases
// without shelling out to a real `git`, which is what unlocks
// coverage on the 400+ LOC of worktree mutation logic.
//
// The production implementation is `LiveGit`, which simply forwards
// to the existing static methods on `GitProcess`. The test target
// supplies `FakeGit` (in LimpidTests/Support/) that returns whatever
// `GitResult` was scripted for the case under test.

import Foundation

protocol GitRunning: Sendable {
    func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String?
    ) async throws -> GitResult

    func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult
}

/// Production implementation — thin wrapper that forwards to the
/// existing `GitProcess` static API. Kept as a struct (not `enum`)
/// so it can be stored as `any GitRunning` and value-copied freely.
struct LiveGit: GitRunning {
    func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String?
    ) async throws -> GitResult {
        try await GitProcess.createWorktree(
            repoRoot: repoRoot,
            path: path,
            baseBranch: baseBranch,
            newBranchName: newBranchName
        )
    }

    func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult {
        try await GitProcess.removeWorktree(
            repoRoot: repoRoot,
            path: path,
            force: force
        )
    }
}
