// PRStatusSyncerLookupTests.swift
// Weir — which pull-request answers the syncer keeps when lookups overlap.
//
// The triggers (launch, the recurring tick, coming back to the app, a
// manual refresh) start independently, and a CLI answers in its own time.
// These pin that an answer reaches the store only while it still describes
// the row: the latest lookup of a container that is still there, asked for
// the branch the row shows.

import Foundation
import Testing
@testable import Weir

/// A fetcher whose every lookup waits until the test answers it, so a test
/// decides the order the answers land in.
private actor ScriptedLookups: PRStatusLookups {
    private var waiting: [CheckedContinuation<PRStatusFetcher.Lookup, Never>] = []
    private(set) var lookupCount = 0
    private(set) var invalidationCount = 0
    private var runningCount = 0
    /// The most lookups that were running at once.
    private(set) var peakRunningCount = 0

    func lookup(workingDirectory _: URL) async -> PRStatusFetcher.Lookup {
        lookupCount += 1
        runningCount += 1
        peakRunningCount = max(peakRunningCount, runningCount)
        // A test that fails while a lookup waits cancels it on the way out;
        // answering then keeps the test from waiting out its time limit.
        let lookup = await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append($0) }
        } onCancel: {
            Task { await self.answerAll(PRStatusFetcher.Lookup(isAnswered: false)) }
        }
        runningCount -= 1
        return lookup
    }

    func invalidate() {
        invalidationCount += 1
    }

    var waitingCount: Int {
        waiting.count
    }

    /// Answer the oldest lookup still waiting.
    func answer(_ lookup: PRStatusFetcher.Lookup) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: lookup)
    }

    private func answerAll(_ lookup: PRStatusFetcher.Lookup) {
        while !waiting.isEmpty {
            waiting.removeFirst().resume(returning: lookup)
        }
    }
}

@MainActor
@Suite("PRStatusSyncer lookups", .timeLimit(.minutes(1)))
struct PRStatusSyncerLookupTests {
    private let session: WorkspaceSession
    private let project: Project
    private let store = PRStatusStore()
    private let lookups = ScriptedLookups()
    private let syncer: PRStatusSyncer

    init() {
        (session, project) = WorkspaceSessionFixture.withProject()
        syncer = PRStatusSyncer(session: session, store: store, fetcher: lookups)
    }

    private var container: ContainerID {
        .project(project.id)
    }

    private func checkOut(_ branch: String) {
        guard let index = session.projects.firstIndex(where: { $0.id == project.id }) else { return }
        session.projects[index].mainBranchName = branch
    }

    private static func answer(
        _ checks: PRChecksConclusion = .success,
        number: Int = 1,
        on head: CheckoutHead = .branch("a")
    ) -> PRStatusFetcher.Lookup {
        PRStatusFetcher.Lookup(
            forge: .gitHub,
            info: PRInfoFixture.make(number: number, checks: checks),
            head: head
        )
    }

    /// Waits for the scripted fetcher to have `count` lookups waiting, or
    /// for the time limit.
    private func waitForLookups(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<2000 where await lookups.waitingCount < count {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await lookups.waitingCount == count, sourceLocation: sourceLocation)
    }

    @Test("a refresh while a lookup runs waits for it, and its own answer is the one kept")
    func refresh_duringLookup_laterAnswerWins() async throws {
        checkOut("a")
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        await syncer.refresh(container: container)
        // The second request asked no CLI of its own while the first ran.
        #expect(await lookups.lookupCount == 1)
        await lookups.answer(Self.answer(.pending))
        try await waitForLookups(1)
        #expect(store.info(for: container)?.checks?.conclusion == .pending)
        await lookups.answer(Self.answer(.success))
        await first
        #expect(store.info(for: container)?.checks?.conclusion == .success)
        #expect(await lookups.peakRunningCount == 1)
    }

    @Test("a turn's end looks the row up without re-reading the forge")
    func aTurnsEnd_looksTheRowUp() async throws {
        syncer.turnEnded(in: container)
        try await waitForLookups(1)
        await lookups.answer(Self.answer(number: 7))
        for _ in 0..<2000 where store.info(for: container) == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.info(for: container)?.number == 7)
        #expect(await lookups.invalidationCount == 0)
    }

    @Test("two refreshes while a lookup runs ask for one more lookup, not two")
    func refresh_twiceDuringLookup_coalescesToOneFollowUp() async throws {
        checkOut("a")
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        await syncer.refresh(container: container)
        await syncer.refresh(container: container)
        await lookups.answer(Self.answer(.pending))
        try await waitForLookups(1)
        await lookups.answer(Self.answer(.success))
        await first
        #expect(await lookups.lookupCount == 2)
        // Each manual lookup re-read the forge, the follow-up included.
        #expect(await lookups.invalidationCount == 2)
    }

    @Test("an answer for the branch the checkout left clears the row instead of showing either branch's request")
    func refresh_branchSwitchedDuringLookup_clearsRow() async throws {
        checkOut("a")
        store.update(container: container, info: PRInfoFixture.make(number: 7), forge: .gitHub)
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        checkOut("b")
        await lookups.answer(Self.answer(number: 1, on: .branch("a")))
        await first
        #expect(store.info(for: container) == nil)
        #expect(store.forge(for: container) == nil)
        // Asking again before the row's branch moves would get the same
        // mismatch, so nothing more is launched.
        await syncer.recheckLeftBranches()
        #expect(await lookups.lookupCount == 1)
    }

    @Test("a row whose Git is behind its checkout is asked again only once its branch moves")
    func refresh_branchDisagrees_waitsForRowToMove() async throws {
        checkOut("a")
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        await lookups.answer(Self.answer(on: .branch("b")))
        await first
        #expect(store.info(for: container) == nil)
        // Wakes while the row still shows the old branch launch nothing.
        await syncer.recheckLeftBranches()
        await syncer.recheckLeftBranches()
        #expect(await lookups.lookupCount == 1)
        // Git is read again for the row, and the wake asks once more.
        checkOut("b")
        async let wake: Void = syncer.recheckLeftBranches()
        try await waitForLookups(1)
        await lookups.answer(Self.answer(number: 5, on: .branch("b")))
        await wake
        #expect(store.info(for: container)?.number == 5)
    }

    @Test("a switch with no lookup running clears the previous branch's request on the next wake")
    func recheck_branchSwitchedBetweenLookups_clearsAndAsksAgain() async throws {
        checkOut("a")
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        await lookups.answer(Self.answer(number: 1, on: .branch("a")))
        await first
        #expect(store.info(for: container)?.number == 1)
        checkOut("b")
        async let wake: Void = syncer.recheckLeftBranches()
        try await waitForLookups(1)
        #expect(store.info(for: container) == nil)
        await lookups.answer(Self.answer(number: 2, on: .branch("b")))
        await wake
        #expect(store.info(for: container)?.number == 2)
    }

    @Test("an answer for the branch the row shows is kept")
    func refresh_sameBranch_keepsAnswer() async throws {
        checkOut("b")
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        await lookups.answer(Self.answer(number: 3, on: .branch("b")))
        await first
        #expect(store.info(for: container)?.number == 3)
        #expect(store.forge(for: container) == .gitHub)
    }

    @Test("an answer that lands after the row was pruned does not put it back, and starts nothing more")
    func refresh_rowPrunedDuringLookup_doesNotReinsert() async throws {
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        async let first: Void = syncer.refresh(container: row)
        try await waitForLookups(1)
        // A follow-up is asked for, then the row goes away before it runs.
        await syncer.refresh(container: row)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].worktrees.removeAll { $0.id == worktree.id }
        syncer.forgetGoneRows()
        await lookups.answer(Self.answer())
        await first
        #expect(store.info(for: row) == nil)
        #expect(store.forge(for: row) == nil)
        #expect(await lookups.lookupCount == 1)
    }

    @Test("an answer for a row pruned and brought back while it ran is not kept")
    func refresh_rowPrunedAndRestoredDuringLookup_dropsAnswer() async throws {
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        async let first: Void = syncer.refresh(container: row)
        try await waitForLookups(1)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].worktrees.removeAll { $0.id == worktree.id }
        syncer.forgetGoneRows()
        // The same worktree is reported again, under the same identity.
        session.projects[index].worktrees.append(worktree)
        await lookups.answer(Self.answer())
        await first
        #expect(store.info(for: row) == nil)
    }

    @Test("a detached row keeps an answer asked for a detached HEAD")
    func refresh_detachedRow_keepsDetachedAnswer() async throws {
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].mainHeadSHA = "abc1234"
        #expect(PRStatusSyncer.head(of: container, in: session) == .detached)
        async let first: Void = syncer.refresh(container: container)
        try await waitForLookups(1)
        await lookups.answer(PRStatusFetcher.Lookup(forge: .gitHub, head: .detached))
        await first
        #expect(store.forge(for: container) == .gitHub)
    }

    @Test("a worktree row's branch is read from its Git ref")
    func head_worktreeRow_readsGitRef() throws {
        var worktree = WorktreeFixture.make()
        worktree.gitRef = GitRef(branchName: "feature", headSHA: "abc1234")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].worktrees.append(worktree)
        let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        #expect(PRStatusSyncer.head(of: row, in: session) == .branch("feature"))
        session.projects[index].worktrees[0].gitRef = GitRef(headSHA: "abc1234")
        #expect(PRStatusSyncer.head(of: row, in: session) == .detached)
    }

    @Test("a row whose branch is not read yet keeps any answer")
    func head_unknownRow_admitsAnswer() {
        #expect(PRStatusSyncer.head(of: container, in: session) == .unknown)
        #expect(CheckoutHead.unknown.admits(.branch("a")))
        #expect(CheckoutHead.branch("a").admits(.unknown))
        #expect(!CheckoutHead.branch("a").admits(.detached))
        #expect(!CheckoutHead.detached.admits(.branch("a")))
    }
}
