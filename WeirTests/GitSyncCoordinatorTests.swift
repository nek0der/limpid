// GitSyncCoordinatorTests.swift
// Weir — which `git worktree list` the sidebar ends up showing when syncs overlap.

import Foundation
import os
import Testing
@testable import Weir
@testable import WeirDomain

/// What `GitSyncCoordinatorTests.ChangingRepository` holds: its worktrees,
/// and the listings begun and done.
private struct ChangingRepositoryState {
    var worktrees: [GitWorktreeInfo]
    var started = 0
    var finished = 0
}

@MainActor
struct GitSyncCoordinatorTests {
    /// A repository whose listing changes while a listing runs: each
    /// listing describes it as it was when that listing began, and one that
    /// began while it still held a worktree answers only when `answerLate`
    /// says. The late one is not cut short by cancellation, as `git` is not.
    private final class ChangingRepository: Sendable {
        private let state: OSAllocatedUnfairLock<ChangingRepositoryState>
        private let lateAnswer = Gate<Void>()

        init(worktrees: [GitWorktreeInfo]) {
            state = OSAllocatedUnfairLock(initialState: ChangingRepositoryState(worktrees: worktrees))
        }

        var startedCount: Int {
            state.withLock { $0.started }
        }

        var finishedCount: Int {
            state.withLock { $0.finished }
        }

        /// The worktree removed outside Weir.
        func removeEveryWorktree() {
            state.withLock { $0.worktrees = [] }
        }

        /// Lets the listing that still saw a worktree return.
        func answerLate() {
            lateAnswer.open()
        }

        func list(_: URL) async -> [GitWorktreeInfo] {
            let seen = state.withLock { state in
                state.started += 1
                return state.worktrees
            }
            defer { state.withLock { $0.finished += 1 } }
            if !seen.isEmpty {
                await lateAnswer.wait()
            }
            return seen
        }
    }

    /// A listing's entry for `path`: detached when it names no branch.
    private static func listed(_ path: URL, headSHA: String, branch: String?) -> GitWorktreeInfo {
        GitWorktreeInfo(
            path: path,
            headSHA: headSHA,
            branch: branch,
            isDetached: branch == nil,
            isBare: false,
            isLocked: false,
            isPrunable: false
        )
    }

    /// A sync started later describes the repository as it is later, so an
    /// earlier one that a later one replaced must not write over it when it
    /// finally returns.
    @Test func aSyncReplacedByALaterOne_doesNotWriteOverIt() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let gone = Self.listed(root.appendingPathComponent("gone"), headSHA: "abc", branch: "gone")
            let repository = ChangingRepository(worktrees: [gone])
            let coordinator = GitSyncCoordinator(session: session) { await repository.list($0) }
            // The first sync's listing is under way, seeing the worktree;
            // then it is removed, and a second sync is asked for.
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) { repository.startedCount >= 1 }
            repository.removeEveryWorktree()

            NotificationCenter.default.post(name: .weirGitSyncRequested, object: project.id)
            // The second listing has answered while the first still waits.
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) {
                repository.startedCount >= 2 && repository.finishedCount >= 1
            }
            repository.answerLate()
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                repository.finishedCount >= 2 && repository.finishedCount == repository.startedCount
            }
            @MainActor func worktrees() -> [Worktree] {
                session.projects.first { $0.id == project.id }?.worktrees ?? []
            }
            // The late listing has returned. Its sync writes on the main
            // actor after that, and nothing marks a write it withheld: the
            // shortest wait that would let it land, ending early if it does.
            await pollUntil(timeout: .milliseconds(200)) { worktrees().contains { $0.origin == .gitWorktree } }
            #expect(worktrees().allSatisfy { $0.origin != .gitWorktree })
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A main folder checked out at a commit has no branch, but is still a
    /// repository: the sync keeps its commit, which the worktree menu reads.
    @Test func aSync_ofADetachedMainCheckout_keepsItsCommit() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let main = Self.listed(root, headSHA: "abc1234", branch: nil)
            let coordinator = GitSyncCoordinator(session: session) { _ in [main] }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                session.projects.first { $0.id == project.id }?.mainHeadSHA != nil
            }
            let synced = try #require(session.projects.first { $0.id == project.id })
            #expect(synced.mainBranchName == nil)
            #expect(synced.mainHeadSHA == "abc1234")
            withExtendedLifetime(coordinator) {}
        }
    }

    // MARK: - Admission

    /// The project's git rows once a sync has listed every one of `paths`.
    private static func syncedRows(
        _ session: WorkspaceSession,
        _ projectID: UUID,
        listing paths: [URL],
        homePath: String = "/Users/someone"
    ) async -> [Worktree] {
        let infos = paths.map { listed($0, headSHA: "abc", branch: $0.lastPathComponent) }
        let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in infos }, homePath: homePath)
        @MainActor func rows() -> [Worktree] {
            session.projects.first { $0.id == projectID }?.worktrees.filter { $0.origin == .gitWorktree } ?? []
        }
        await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
            let synced = rows()
            return synced.count == paths.count && synced.allSatisfy { $0.gitRef?.headSHA == "abc" && $0.admission != nil }
        }
        withExtendedLifetime(coordinator) {}
        return rows()
    }

    /// A worktree a sync finds first was made outside Weir: it is one Git
    /// only reported, wherever it sits, until the person opens it.
    @Test func aWorktreeASyncFindsFirst_isDiscovered() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let rows = await Self.syncedRows(session, project.id, listing: [root.appendingPathComponent("feat-x")])
            #expect(rows.map(\.admission) == [.discovered])
        }
    }

    /// A sync takes each row's branch and HEAD from Git, never its
    /// admission: a row Weir made, or one the person opened, stays so.
    @Test(arguments: [WorktreeAdmission.created, .opened, .discovered])
    func aSync_keepsTheAdmissionARowHas(admission: WorktreeAdmission) async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent(".claude/worktrees/agent-x")
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            session.projects[index].worktrees.append(
                WorktreeFixture.make(workingDirectory: path, admission: admission)
            )
            let rows = await Self.syncedRows(session, project.id, listing: [path])
            #expect(rows.map(\.admission) == [admission])
        }
    }

    /// A sync updates a row in place, so a name the person gave it stays.
    @Test func aSync_keepsTheNameARowWasGiven() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent("feat-x")
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            var row = WorktreeFixture.make(workingDirectory: path, admission: .opened)
            row.displayName = "Release prep"
            session.projects[index].worktrees.append(row)
            let rows = await Self.syncedRows(session, project.id, listing: [path])
            #expect(rows.map(\.displayName) == ["Release prep"])
            #expect(rows.first?.gitRef?.branchName == "feat-x")
        }
    }

    /// A row an older `state.json` holds with no admission is admitted by
    /// its use first: one the person used under `.claude/worktrees/` stays
    /// a working row, and only an agent's unused one waits among the other
    /// worktrees.
    @Test func aSync_admitsARowWithNoAdmission_byItsUseThenItsPath() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            let agents = root.appendingPathComponent(".claude/worktrees")
            var remembered = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("remembered"))
            remembered.lastActiveTabID = UUID()
            let withTab = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("with-tab"))
            let selected = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("selected"))
            let unused = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("unused"))
            let plain = WorktreeFixture.make(workingDirectory: root.appendingPathComponent("plain"))
            let pinned = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("pinned"), origin: .userPinned)
            session.projects[index].worktrees = [remembered, withTab, selected, unused, plain, pinned]
            // The window shows the project; a tab opened, and a row chosen,
            // by anyone but the person admit nothing on their own: the rows
            // are used.
            session.setActiveContainer(.project(project.id))
            session.openTab(
                container: .worktree(projectID: project.id, worktreeID: withTab.id),
                in: session.primaryWindowID,
                intent: .repair,
                selects: false
            )
            session.setActiveContainer(
                .worktree(projectID: project.id, worktreeID: selected.id),
                in: session.primaryWindowID,
                intent: .repair
            )
            #expect(session.holdsSelection(of: .worktree(projectID: project.id, worktreeID: selected.id)))
            #expect(session.worktree(projectID: project.id, worktreeID: selected.id)?.admission == nil)

            let rows = await Self.syncedRows(
                session,
                project.id,
                listing: [remembered, withTab, selected, unused, plain].map(\.workingDirectory)
            )
            let admissions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.admission) })
            #expect(admissions[remembered.id] == .opened)
            #expect(admissions[withTab.id] == .opened)
            #expect(admissions[selected.id] == .opened)
            #expect(admissions[unused.id] == .discovered)
            #expect(admissions[plain.id] == .opened)
            #expect(session.worktree(projectID: project.id, worktreeID: pinned.id)?.admission == .opened)
        }
    }

    /// A row being changed (moved, deleted) is left as the change has it,
    /// as the reconcile leaves it: a sync admits it once the change is done.
    @Test func aSync_leavesARowBeingChangedUnadmitted() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            let row = WorktreeFixture.make(workingDirectory: root.appendingPathComponent(".claude/worktrees/x"))
            session.projects[index].worktrees = [row]
            let listing = Gate<Void>()
            let infos = [Self.listed(row.workingDirectory, headSHA: "abc", branch: "x")]
            let change = Gate<Void>()
            let changing = Task { @MainActor in
                await session.withWorktreeMutationGated(row.id) { await change.wait() }
            }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) {
                session.worktreeMutationsInFlight.contains(row.id)
            }
            let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in
                defer { listing.open() }
                return infos
            }, homePath: "/Users/someone")
            await listing.wait()
            // The listing has returned; its write lands on the main actor
            // after it, so give it the shortest wait that would let it.
            await pollUntil(timeout: .milliseconds(200)) {
                session.worktree(projectID: project.id, worktreeID: row.id)?.admission != nil
            }
            #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == nil)
            change.open()
            await changing.value
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A sync reads one `git worktree list` and nothing per worktree: what
    /// it shows of each comes from that listing. Here the listing says the
    /// worktree is detached while the folder's own `git status` would name
    /// a branch; a sync that ran `git status` in every worktree took the
    /// branch from it, on every activation, for a value nothing reads.
    @Test func aSync_takesEachWorktreeFromTheListingAlone() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let listed = Self.listed(repo.url, headSHA: "abc", branch: nil)
            let coordinator = GitSyncCoordinator(session: session) { _ in [listed] }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                session.projects.first { $0.id == project.id }?.worktrees.contains { $0.origin == .gitWorktree } == true
            }
            let worktree = try #require(session.projects.first { $0.id == project.id }?.worktrees.first { $0.origin == .gitWorktree })
            #expect(worktree.gitRef?.branchName == nil)
            #expect(worktree.gitRef?.headSHA == "abc")
            withExtendedLifetime(coordinator) {}
        }
    }
}
