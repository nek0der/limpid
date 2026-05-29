// FakeGitInspector.swift
// Scriptable `GitInspecting` for conflict-detection tests. Returns
// pre-set `git status` entries per worktree root so the watcher /
// detector can be driven without shelling out to real git. Distinct
// from `FakeGit` (Support/FakeGit.swift), which fakes the worktree-CRUD
// `GitRunning` surface.
//
// `OSAllocatedUnfairLock` (not `NSLock`) because Swift 6 forbids
// `NSLock` from async contexts; its `withLock` is async-safe.

import Foundation
import os
@testable import Limpid

final class FakeGitInspector: GitInspecting, Sendable {
    private struct State {
        var entriesByRoot: [String: [GitStatusEntry]] = [:]
        var statusCallCount = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Script the entries `status(at:)` returns for a given root.
    func setEntries(_ entries: [GitStatusEntry], for root: URL) {
        state.withLock { $0.entriesByRoot[root.standardizedFileURL.path] = entries }
    }

    /// How many times `status(at:)` has been called — lets a test
    /// assert the watcher actually re-queried git.
    var statusCallCount: Int {
        state.withLock { $0.statusCallCount }
    }

    func status(at root: URL) async throws -> [GitStatusEntry] {
        state.withLock {
            $0.statusCallCount += 1
            return $0.entriesByRoot[root.standardizedFileURL.path] ?? []
        }
    }
}
