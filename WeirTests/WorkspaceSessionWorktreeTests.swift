// WorkspaceSessionWorktreeTests.swift
// Weir — exercises WorkspaceSession+Worktree create / delete pipelines against a scripted `FakeGit`.
//
// Patterns to copy from these tests:
//   - Inject `git: FakeGit` to `createGitWorktree` / `deleteGitWorktree`.
//   - Set `nextCreateResult` / `nextRemoveResult` before the call to
//     script success or a specific stderr.
//   - Assert on the resulting WorkspaceSession state (project.worktrees
//     count, removed-pane ids, etc.), not on log output.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession +Worktree pipelines")
@MainActor
struct WorkspaceSessionWorktreeTests {

    // MARK: - Create — happy path

    @Test("createGitWorktree: success attaches a worktree row to the project")
    func createGitWorktree_whenGitSucceeds_attachesWorktreeRow() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit() // default = success

        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature-x",
            openTab: false,
            git: git
        )

        let updated = try #require(session.projects.first { $0.id == project.id })
        #expect(updated.worktrees.contains { $0.id == wt.id })
        #expect(wt.label == "feature-x")
        #expect(git.createCalls.count == 1)
    }

    @Test("createGitWorktree: makes the new branch from the base, then adds the worktree on it")
    func createGitWorktree_withNewBranchName_forwardsBranchToGit() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        _ = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature-y",
            openTab: false,
            git: git
        )
        let branch = try #require(git.branchCalls.first)
        #expect(branch.name == "feature-y")
        #expect(branch.startPoint == "main")
        let call = try #require(git.createCalls.first)
        #expect(call.newBranchName == nil)
        #expect(call.baseBranch == "feature-y")
    }

    @Test("createGitWorktree: omits the branch name when the input is whitespace")
    func createGitWorktree_whenNewBranchNameIsBlank_passesNilToGit() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        _ = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "   ",
            openTab: false,
            git: git
        )
        let call = try #require(git.createCalls.first)
        #expect(call.newBranchName == nil)
        #expect(git.branchCalls.isEmpty)
    }

    // MARK: - Create — errors

    /// A `git worktree add` past its deadline is a timeout, not git's own
    /// failure (its message: `WorktreeErrorsTests`). What it had made of the
    /// worktree is removed, so a retry does not stop on a folder that is
    /// already there; the branch made for it stays.
    @Test func createGitWorktree_whenGitRunsPastItsDeadline_removesWhatItMade() async {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        git.nextCreateError = .timedOut(seconds: 600)
        git.leavesFolderOnError = true
        let path = WorktreeFixture.freshPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let thrown = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: project.id,
                path: path,
                baseBranch: "main",
                newBranchName: "feature-t",
                openTab: false,
                git: git
            )
        }
        guard case let .timedOut(seconds, branch, leftover)? = thrown else {
            Issue.record("expected a timeout, got \(String(describing: thrown))")
            return
        }
        #expect(seconds == 600)
        #expect(branch == "feature-t")
        #expect(leftover == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(git.removeCalls.map(\.force) == [true])
        #expect(git.removeCalls.first?.path == path)
        #expect(git.pruneCalls == [project.rootURL])
    }

    /// Past its deadline, git left something running that outlived
    /// SIGKILL: the folder is kept, so a retry stops on it rather than
    /// making a worktree there that process could still write into.
    @Test func createGitWorktree_whenGitLeavesProcessesRunning_keepsTheFolder() async {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        git.nextCreateError = .timedOut(seconds: 600, hasProcessesLeft: true)
        git.leavesFolderOnError = true
        let path = WorktreeFixture.freshPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let thrown = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: project.id,
                path: path,
                baseBranch: "main",
                newBranchName: "feature-t",
                openTab: false,
                git: git
            )
        }
        guard case let .timedOut(_, branch, leftover)? = thrown else {
            Issue.record("expected a timeout, got \(String(describing: thrown))")
            return
        }
        #expect(branch == "feature-t")
        #expect(leftover == path)
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(git.removeCalls.isEmpty)
    }

    @Test("createGitWorktree: unknown project id throws projectNotFound")
    func createGitWorktree_withUnknownProject_throwsProjectNotFound() async {
        let session = WorkspaceSession()
        let error = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: UUID(),
                path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                baseBranch: "main",
                newBranchName: nil,
                openTab: false,
                git: FakeGit()
            )
        }
        guard case .projectNotFound? = error else {
            Issue.record("expected .projectNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test("createGitWorktree: existing path on disk throws pathAlreadyExists without calling git")
    func createGitWorktree_whenPathExists_throwsAndDoesNotInvokeGit() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        // Create the directory first so the guard fires.
        let collidingPath = WorktreeFixture.freshPath()
        try FileManager.default.createDirectory(at: collidingPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: collidingPath) }
        let git = FakeGit()

        let error = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: project.id,
                path: collidingPath,
                baseBranch: "main",
                newBranchName: nil,
                openTab: false,
                git: git
            )
        }
        if case let .pathAlreadyExists(path)? = error {
            #expect(path == collidingPath)
        } else {
            Issue.record("expected .pathAlreadyExists, got \(String(describing: error))")
        }
        #expect(git.createCalls.isEmpty)
    }

    @Test("createGitWorktree: git failure surfaces stderr through gitFailed")
    func createGitWorktree_whenGitFails_throwsGitFailedWithStderr() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        git.nextCreateResult = .failure("fatal: invalid reference: bogus")

        let error = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: project.id,
                path: WorktreeFixture.freshPath(),
                baseBranch: "bogus",
                newBranchName: nil,
                openTab: false,
                git: git
            )
        }
        let unwrapped = try #require(error)
        guard case let .gitFailed(stderr) = unwrapped else {
            Issue.record("expected .gitFailed, got \(unwrapped)")
            return
        }
        #expect(stderr == "fatal: invalid reference: bogus")
    }

    // MARK: - Delete — happy path

    @Test("deleteGitWorktree: success drops the row and returns the freed pane ids")
    func deleteGitWorktree_whenGitSucceeds_dropsRow() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature-z",
            openTab: false,
            git: git
        )

        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: wt.id))

        // Reset for the delete leg.
        git.nextRemoveResult = .success()
        let freed = try await session.deleteGitWorktree(
            projectID: project.id,
            worktreeID: wt.id,
            force: false,
            git: git
        )

        let updated = try #require(session.projects.first { $0.id == project.id })
        #expect(!updated.worktrees.contains { $0.id == wt.id })
        #expect(!freed.isEmpty)
        #expect(Set(freed) == Set(tab.splitTree.allLeafIDs()))
    }

    // MARK: - Delete — errors

    @Test("deleteGitWorktree: unknown project id throws projectNotFound")
    func deleteGitWorktree_withUnknownProject_throwsProjectNotFound() async {
        let session = WorkspaceSession()
        let error = await WorktreeFixture.failure(DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(
                projectID: UUID(),
                worktreeID: UUID(),
                force: false,
                git: FakeGit()
            )
        }
        guard case .projectNotFound? = error else {
            Issue.record("expected .projectNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test("deleteGitWorktree: unknown worktree id throws worktreeNotFound")
    func deleteGitWorktree_withUnknownWorktree_throwsWorktreeNotFound() async {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let error = await WorktreeFixture.failure(DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(
                projectID: project.id,
                worktreeID: UUID(),
                force: false,
                git: FakeGit()
            )
        }
        guard case .worktreeNotFound? = error else {
            Issue.record("expected .worktreeNotFound, got \(String(describing: error))")
            return
        }
    }

    /// How a removal git refused comes out.
    enum RemovalOutcome: Equatable, Sendable {
        case dirtyNeedsForce
        case submodulesNeedForce
        case gitFailed(String)
        /// No error, and the row is gone.
        case rowDropped
    }

    @Test("deleteGitWorktree: git's refusal decides the error, or drops the row of a folder git no longer knows", arguments: [
        ("fatal: '/p' contains modified or untracked files, use --force", RemovalOutcome.dirtyNeedsForce),
        ("error: working tree is locked", .dirtyNeedsForce),
        ("use --force to delete", .dirtyNeedsForce),
        ("fatal: working trees containing submodules cannot be moved or removed", .submodulesNeedForce),
        ("fatal: permission denied", .gitFailed("fatal: permission denied")),
        ("fatal: '/p' is not a working tree", .rowDropped)
    ])
    func deleteGitWorktree_whenGitRefuses_readsItsWords(stderr: String, expected: RemovalOutcome) async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: git
        )
        git.nextRemoveResult = .failure(stderr)

        let error = await WorktreeFixture.failure(DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(projectID: project.id, worktreeID: wt.id, force: false, git: git)
        }

        let isRowKept = session.project(project.id)?.worktrees.contains { $0.id == wt.id } == true
        let outcome: RemovalOutcome? = switch error {
        case .dirtyNeedsForce?: .dirtyNeedsForce
        case .submodulesNeedForce?: .submodulesNeedForce
        case let .gitFailed(stderr)?: .gitFailed(stderr)
        case nil where !isRowKept: .rowDropped
        default: nil
        }
        #expect(outcome == expected, "\(String(describing: error))")
    }

    @Test("deleteGitWorktree: force retry is forwarded to git")
    func deleteGitWorktree_withForce_forwardsForceToGit() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: git
        )

        _ = try await session.deleteGitWorktree(
            projectID: project.id,
            worktreeID: wt.id,
            force: true,
            git: git
        )

        let call = try #require(git.removeCalls.first)
        #expect(call.force)
    }

    // MARK: - Admission

    @Test("createGitWorktree: the row it adds is Weir's")
    func createGitWorktree_admitsTheRowAsCreated() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: FakeGit()
        )
        #expect(session.worktree(projectID: project.id, worktreeID: wt.id)?.admission == .created)
    }

    /// A row kept for the same folder, hidden after its folder went missing,
    /// is taken over rather than doubled when the worktree is made again.
    @Test("createGitWorktree: a row already kept at the same folder is raised to Weir's, not doubled")
    func createGitWorktree_atAKeptRowsFolder_raisesThatRow() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let path = WorktreeFixture.freshPath()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let kept = WorktreeFixture.make(workingDirectory: path, isHidden: true, isMissing: true, admission: .discovered)
        session.projects[index].worktrees.append(kept)

        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: path,
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: FakeGit()
        )

        let rows = try #require(session.project(project.id)).worktrees
        #expect(wt.id == kept.id)
        #expect(rows.count == 1)
        #expect(rows.first?.admission == .created)
        #expect(rows.first?.isHidden == false)
    }

    /// The person choosing a row, or opening a tab in it, admits a row Git
    /// only reported, and one an older file held with no admission.
    @Test("the person's choice of a row, or a tab they open in it, admits it as opened", arguments: [
        WorktreeAdmission?.some(.discovered), nil
    ])
    func thePersonsChoice_admitsTheRow(admission: WorktreeAdmission?) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let chosen = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)
        let tabbed = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)

        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: chosen.id), in: session.primaryWindowID, intent: .person)
        session.openTab(
            container: .worktree(projectID: project.id, worktreeID: tabbed.id),
            in: session.primaryWindowID,
            intent: .person,
            selects: false
        )

        #expect(session.worktree(projectID: project.id, worktreeID: chosen.id)?.admission == .opened)
        #expect(session.worktree(projectID: project.id, worktreeID: tabbed.id)?.admission == .opened)
    }

    /// Only the person opens a row: a selection that moves the window on, or
    /// work finishing behind them, leaves it among the other worktrees.
    @Test("a selection the person did not make admits nothing", arguments: [SelectionIntent.repair, .behind])
    func aSelectionNotThePersons_admitsNothing(intent: SelectionIntent) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let container = ContainerID.worktree(projectID: project.id, worktreeID: row.id)

        session.setActiveContainer(container, in: session.primaryWindowID, intent: intent)
        session.openTab(container: container, in: session.primaryWindowID, intent: intent, selects: false)

        #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == .discovered)
    }

    /// The person opening a row Weir made leaves it Weir's.
    @Test("the person's choice leaves a row Weir made as Weir's")
    func thePersonsChoice_keepsACreatedRow() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: row.id), in: session.primaryWindowID, intent: .person)
        #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == .created)
    }

    /// Move to Other Worktrees puts a row among the other worktrees and says
    /// what it was, which Undo puts back; a row already there is left.
    @Test("releaseWorktree: a row Weir made or the person opened goes back among the other worktrees", arguments: [
        WorktreeAdmission?.some(.created), .some(.opened), nil
    ])
    func releaseWorktree_movesTheRowAmongTheOthers(admission: WorktreeAdmission?) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)

        let release = try #require(session.releaseWorktree(projectID: project.id, worktreeID: row.id))

        #expect(release.previous == admission)
        #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == .discovered)
        // Undo puts back what it was, a row not admitted yet included.
        session.readmitWorktree(projectID: project.id, worktreeID: row.id, as: release.previous)
        #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == admission)
    }

    @Test("releaseWorktree: a row already among the other worktrees, or one the session does not have, is left")
    func releaseWorktree_ofADiscoveredOrAbsentRow_changesNothing() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        #expect(session.releaseWorktree(projectID: project.id, worktreeID: row.id) == nil)
        #expect(session.releaseWorktree(projectID: project.id, worktreeID: UUID()) == nil)
        #expect(session.releaseWorktree(projectID: UUID(), worktreeID: row.id) == nil)
    }

    // MARK: - Per-worktree last-active restoration

    @Test("setActiveContainer restores a worktree's own last-active tab, not the first, after a sibling worktree was visited")
    func setActiveContainer_worktree_restoresOwnLastActiveTab() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let a = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)
        let b = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)

        // Worktree A's active tab settles on its second tab.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: a.id))
        let a2 = session.openTab(container: .worktree(projectID: project.id, worktreeID: a.id))
        // Visiting sibling B leaves A's own last-active tab alone.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: b.id))

        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: a.id))
        #expect(session.primarySelection.activeTabID == a2.id)
    }

    @Test("setActiveContainer restores a project-direct last-active tab after interposing a worktree")
    func setActiveContainer_project_survivesWorktreeDetour() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let wt = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)

        _ = session.openTab(container: .project(project.id))
        let pg2 = session.openTab(container: .project(project.id))
        // Interpose the worktree — activating it must not clobber the
        // project-direct container's own last-active pointer.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: wt.id))

        session.setActiveContainer(.project(project.id))
        #expect(session.primarySelection.activeTabID == pg2.id)
    }

    // MARK: - Drag reorder

    /// A project with three worktrees.
    private func makeSessionWithThreeWorktrees() throws -> (WorkspaceSession, Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        for _ in 0..<3 {
            try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)
        }
        return (session, project)
    }

    private func worktreeIDs(of projectID: UUID, in session: WorkspaceSession) -> [UUID] {
        session.project(projectID)?.worktrees.map(\.id) ?? []
    }

    @Test func droppingOnAWorktreeRow_isANoOp_onlyWhenItChangesNothing() throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        let first = ids[0]
        let third = ids[2]

        #expect(session.isNoOpDrop(of: first, onWorktree: first, projectID: project.id, position: .before))
        #expect(!session.isNoOpDrop(of: third, onWorktree: first, projectID: project.id, position: .before))
        // A worktree never moves to another project's rows.
        #expect(session.isNoOpDrop(of: third, onWorktree: first, projectID: UUID(), position: .before))
    }

    @Test("reorderWorktree(.before) drops the source ahead of the target")
    func reorderWorktree_before_dropsAheadOfTarget() throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        try #require(ids.count == 3)
        session.reorderWorktree(projectID: project.id, sourceID: ids[2], target: ids[0], position: .before)
        #expect(worktreeIDs(of: project.id, in: session) == [ids[2], ids[0], ids[1]])
    }

    @Test("reorderWorktree(.after) drops the source behind the target")
    func reorderWorktree_after_dropsBehindTarget() throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        try #require(ids.count == 3)
        session.reorderWorktree(projectID: project.id, sourceID: ids[0], target: ids[1], position: .after)
        #expect(worktreeIDs(of: project.id, in: session) == [ids[1], ids[0], ids[2]])
    }

    @Test("reorderWorktree is a no-op when the source or target is unknown, or in another project")
    func reorderWorktree_unknownOrForeignID_isNoOp() throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        try #require(ids.count == 3)
        let other = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("other"), suggestedName: "other")
        let foreign = try WorkspaceSessionFixture.appendWorktree(to: other.id, in: session, origin: .userPinned)

        session.reorderWorktree(projectID: project.id, sourceID: UUID(), target: ids[0], position: .before)
        session.reorderWorktree(projectID: project.id, sourceID: ids[0], target: UUID(), position: .after)
        session.reorderWorktree(projectID: project.id, sourceID: foreign.id, target: ids[1], position: .before)
        session.reorderWorktree(projectID: project.id, sourceID: ids[1], target: foreign.id, position: .after)
        session.reorderWorktree(projectID: UUID(), sourceID: ids[2], target: ids[0], position: .before)

        #expect(worktreeIDs(of: project.id, in: session) == ids)
        #expect(worktreeIDs(of: other.id, in: session) == [foreign.id])
    }

    // MARK: - Delete Worktrees

    @Test("deleteGitWorktrees: each is removed cleanly, its row dropped and its panes freed")
    func deleteGitWorktrees_whenGitSucceeds_dropsEveryRow() async throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: ids[0]))
        let git = FakeGit()
        let registry = RecordingSurfaceRegistry()

        let refused = await ContainerActions.deleteGitWorktrees(
            session,
            registry: registry,
            projectID: project.id,
            worktreeIDs: [ids[0], ids[1]],
            force: false,
            git: git
        )

        #expect(refused.isEmpty)
        #expect(worktreeIDs(of: project.id, in: session) == [ids[2]])
        #expect(git.removeCalls.map(\.force) == [false, false])
        #expect(Set(registry.unregisteredIDs) == Set(tab.splitTree.allLeafIDs()))
    }

    @Test("deleteGitWorktrees: one Git would remove only with Force keeps its row and comes back")
    func deleteGitWorktrees_whenGitAsksForForce_keepsTheRowsAndReturnsThem() async throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        let git = FakeGit()
        git.nextRemoveResult = .failure("fatal: '/p' contains modified or untracked files, use --force to delete it")

        let refused = await ContainerActions.deleteGitWorktrees(
            session,
            registry: RecordingSurfaceRegistry(),
            projectID: project.id,
            worktreeIDs: [ids[0], ids[1]],
            force: false,
            git: git
        )

        #expect(refused.map(\.worktreeID) == [ids[0], ids[1]])
        #expect(refused.allSatisfy { refusal in
            if case .dirtyNeedsForce? = refusal.error as? DeleteWorktreeError {
                true
            } else {
                false
            }
        })
        #expect(worktreeIDs(of: project.id, in: session) == ids)

        git.nextRemoveResult = .success()
        let forced = await ContainerActions.deleteGitWorktrees(
            session,
            registry: RecordingSurfaceRegistry(),
            projectID: project.id,
            worktreeIDs: refused.map(\.worktreeID),
            force: true,
            git: git
        )

        #expect(forced.isEmpty)
        #expect(git.removeCalls.map(\.force) == [false, false, true, true])
        #expect(worktreeIDs(of: project.id, in: session) == [ids[2]])
    }

    @Test("The names Git refused are quoted as each language quotes them")
    func refusedNames_areQuotedInTheLanguage() {
        #expect(WorktreeOperationText.lines(["a", "b"], locale: Locale(identifier: "en")) == "\u{201C}a\u{201D}\n\u{201C}b\u{201D}")
        #expect(WorktreeOperationText.lines(["a", "b"], locale: Locale(identifier: "ja")) == "「a」\n「b」")
    }
}
