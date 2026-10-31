// FakePullRequests.swift
// Weir — scripted `PullRequestReading` for the new worktree sheet's pull request source, with no gh or glab.

import Foundation
import os
@testable import Weir

/// Answers what a suite scripts: the availability, each number's lookup,
/// and the open requests; records the numbers asked.
final class FakePullRequests: PullRequestReading, Sendable {
    private struct State {
        var availability: PullRequestAvailability = .available(.fixture)
        var lookups: [Int: PullRequestLookup] = [:]
        var open: [PullRequestHead] = []
        var asked: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var availability: PullRequestAvailability {
        get { state.withLock { $0.availability } }
        set { state.withLock { $0.availability = newValue } }
    }

    /// The open requests the menu lists.
    var open: [PullRequestHead] {
        get { state.withLock { $0.open } }
        set { state.withLock { $0.open = newValue } }
    }

    /// The numbers looked up, in order.
    var asked: [Int] {
        state.withLock { $0.asked }
    }

    /// What looking up `head.number` finds.
    func add(_ head: PullRequestHead) {
        state.withLock { $0.lookups[head.number] = .found(head) }
    }

    func script(_ number: Int, _ lookup: PullRequestLookup) {
        state.withLock { $0.lookups[number] = lookup }
    }

    func availability(repoRoot: URL) async -> PullRequestAvailability {
        availability
    }

    func pullRequest(_ number: Int, in repository: PullRequestRepository, repoRoot: URL) async -> PullRequestLookup {
        state.withLock {
            $0.asked.append(number)
            return $0.lookups[number] ?? .notFound(number)
        }
    }

    func openPullRequests(in repository: PullRequestRepository, repoRoot: URL) async -> [PullRequestHead] {
        open
    }
}

extension PullRequestRepository {
    /// GitHub's `acme/app`, fetched from `origin`.
    static let fixture = PullRequestRepository(forge: .gitHub, remote: "origin", repository: "github.com/acme/app")
}

extension PullRequestHead {
    /// A request for a suite: open, from the repository itself unless
    /// `forkOwner` says a fork.
    static func fixture(
        _ number: Int,
        branch: String = "feat/from-pr",
        commit: String? = nil,
        state: PRState = .open,
        forkOwner: String? = nil
    ) -> PullRequestHead {
        PullRequestHead(
            number: number,
            title: "Request \(number)",
            state: state,
            headBranch: branch,
            headCommit: commit,
            forkOwner: forkOwner
        )
    }
}
