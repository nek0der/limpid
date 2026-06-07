// WindowSessionWorktreeTests.swift
// Limpid — exercises WindowSession+Worktree create / delete pipelines against a scripted `FakeGit`.
//
// Patterns to copy from these tests:
//   - Inject `git: FakeGit` to `createGitWorktree` / `deleteGitWorktree`.
//   - Set `nextCreateResult` / `nextRemoveResult` before the call to
//     script success or a specific stderr.
//   - Assert on the resulting WindowSession state (project.worktrees
//     count, removed-pane ids, etc.), not on log output.

import Foundation
import Testing
@testable import Limpid

@Suite("WindowSession +Worktree pipelines")
@MainActor
struct WindowSessionWorktreeTests {

    // MARK: - Helpers

    private func makeSessionWithProject() -> (WindowSession, Project) {
        let session = WindowSession()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-wt-\(UUID().uuidString)")
        let project = session.addOrActivateProject(rootURL: root, suggestedName: "demo")
        return (session, project)
    }

    /// Random non-existent path under tmp so the "path already exists"
    /// guard never fires for the happy path.
    private func freshPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-\(UUID().uuidString)")
    }

    /// Attach a worktree row directly (no git), for the pure
    /// last-active-restoration tests below.
    @discardableResult
    private func appendWorktree(to projectID: UUID, in session: WindowSession) throws -> Worktree {
        let wt = Worktree(label: "wt", workingDirectory: freshPath(), origin: .userPinned)
        let idx = try #require(session.projects.firstIndex(where: { $0.id == projectID }))
        session.projects[idx].worktrees.append(wt)
        return wt
    }

    // MARK: - Create — happy path

    @Test("createGitWorktree: success attaches a worktree row to the project")
    func createGitWorktree_whenGitSucceeds_attachesWorktreeRow() async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit() // default = success

        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
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

    @Test("createGitWorktree: passes the new branch name through to git when provided")
    func createGitWorktree_withNewBranchName_forwardsBranchToGit() async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        _ = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
            baseBranch: "main",
            newBranchName: "feature-y",
            openTab: false,
            git: git
        )
        let call = try #require(git.createCalls.first)
        #expect(call.newBranchName == "feature-y")
        #expect(call.baseBranch == "main")
    }

    @Test("createGitWorktree: omits the branch name when the input is whitespace")
    func createGitWorktree_whenNewBranchNameIsBlank_passesNilToGit() async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        _ = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
            baseBranch: "main",
            newBranchName: "   ",
            openTab: false,
            git: git
        )
        let call = try #require(git.createCalls.first)
        #expect(call.newBranchName == nil)
    }

    // MARK: - Create — errors

    @Test("createGitWorktree: unknown project id throws projectNotFound")
    func createGitWorktree_withUnknownProject_throwsProjectNotFound() async {
        let session = WindowSession()
        await #expect(throws: CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: UUID(),
                path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                baseBranch: "main",
                newBranchName: nil,
                openTab: false,
                git: FakeGit()
            )
        }
    }

    @Test("createGitWorktree: existing path on disk throws pathAlreadyExists without calling git")
    func createGitWorktree_whenPathExists_throwsAndDoesNotInvokeGit() async throws {
        let (session, project) = makeSessionWithProject()
        // Create the directory first so the guard fires.
        let collidingPath = freshPath()
        try FileManager.default.createDirectory(at: collidingPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: collidingPath) }
        let git = FakeGit()

        await #expect(throws: CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: project.id,
                path: collidingPath,
                baseBranch: "main",
                newBranchName: nil,
                openTab: false,
                git: git
            )
        }
        #expect(git.createCalls.isEmpty)
    }

    @Test("createGitWorktree: git failure surfaces stderr through gitFailed")
    func createGitWorktree_whenGitFails_throwsGitFailedWithStderr() async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        git.nextCreateResult = .failure("fatal: invalid reference: bogus")

        let error: CreateWorktreeError? = await {
            do {
                _ = try await session.createGitWorktree(
                    projectID: project.id,
                    path: freshPath(),
                    baseBranch: "bogus",
                    newBranchName: nil,
                    openTab: false,
                    git: git
                )
                return nil
            } catch let err as CreateWorktreeError {
                return err
            } catch {
                return nil
            }
        }()
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
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
            baseBranch: "main",
            newBranchName: "feature-z",
            openTab: false,
            git: git
        )

        // Reset for the delete leg.
        git.nextRemoveResult = .success()
        _ = try await session.deleteGitWorktree(
            projectID: project.id,
            worktreeID: wt.id,
            force: false,
            git: git
        )

        let updated = try #require(session.projects.first { $0.id == project.id })
        #expect(!updated.worktrees.contains { $0.id == wt.id })
    }

    // MARK: - Delete — errors

    @Test("deleteGitWorktree: unknown project id throws projectNotFound")
    func deleteGitWorktree_withUnknownProject_throwsProjectNotFound() async {
        let session = WindowSession()
        await #expect(throws: DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(
                projectID: UUID(),
                worktreeID: UUID(),
                force: false,
                git: FakeGit()
            )
        }
    }

    @Test("deleteGitWorktree: unknown worktree id throws worktreeNotFound")
    func deleteGitWorktree_withUnknownWorktree_throwsWorktreeNotFound() async throws {
        let (session, project) = makeSessionWithProject()
        await #expect(throws: DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(
                projectID: project.id,
                worktreeID: UUID(),
                force: false,
                git: FakeGit()
            )
        }
    }

    @Test(
        "deleteGitWorktree: git stderr matching 'modified' / '--force' / 'locked' (without force) throws dirtyNeedsForce",
        arguments: [
            "fatal: '/p' contains modified or untracked files, use --force",
            "error: working tree is locked",
            "use --force to delete"
        ]
    )
    func deleteGitWorktree_dirtyStderr_throwsDirtyNeedsForce(stderr: String) async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: git
        )
        git.nextRemoveResult = .failure(stderr)

        let error: DeleteWorktreeError? = await {
            do {
                _ = try await session.deleteGitWorktree(
                    projectID: project.id,
                    worktreeID: wt.id,
                    force: false,
                    git: git
                )
                return nil
            } catch let err as DeleteWorktreeError {
                return err
            } catch {
                return nil
            }
        }()
        let unwrapped = try #require(error)
        guard case .dirtyNeedsForce = unwrapped else {
            Issue.record("expected .dirtyNeedsForce, got \(unwrapped)")
            return
        }
    }

    @Test("deleteGitWorktree: 'not a working tree' stderr resolves as success (orphan row cleanup)")
    func deleteGitWorktree_whenGitSaysNotAWorkingTree_dropsRowAnyway() async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
            baseBranch: "main",
            newBranchName: "ghost",
            openTab: false,
            git: git
        )
        git.nextRemoveResult = .failure("fatal: '/p' is not a working tree")

        _ = try await session.deleteGitWorktree(
            projectID: project.id,
            worktreeID: wt.id,
            force: false,
            git: git
        )

        let updated = try #require(session.projects.first { $0.id == project.id })
        #expect(!updated.worktrees.contains { $0.id == wt.id })
    }

    @Test("deleteGitWorktree: non-dirty git failure throws gitFailed with stderr")
    func deleteGitWorktree_whenGitFailsForOtherReason_throwsGitFailed() async throws {
        let (session, project) = makeSessionWithProject()
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: freshPath(),
            baseBranch: "main",
            newBranchName: "x",
            openTab: false,
            git: git
        )
        git.nextRemoveResult = .failure("fatal: permission denied")

        let error: DeleteWorktreeError? = await {
            do {
                _ = try await session.deleteGitWorktree(
                    projectID: project.id,
                    worktreeID: wt.id,
                    force: false,
                    git: git
                )
                return nil
            } catch let err as DeleteWorktreeError {
                return err
            } catch {
                return nil
            }
        }()
        let unwrapped = try #require(error)
        guard case let .gitFailed(stderr) = unwrapped else {
            Issue.record("expected .gitFailed, got \(unwrapped)")
            return
        }
        #expect(stderr == "fatal: permission denied")
    }

    // MARK: - Per-worktree last-active restoration (regression)

    @Test("setActiveContainer restores a worktree's own last-active tab, not the first, after a sibling worktree was visited")
    func setActiveContainer_worktree_restoresOwnLastActiveTab() throws {
        let (session, project) = makeSessionWithProject()
        let a = try appendWorktree(to: project.id, in: session)
        let b = try appendWorktree(to: project.id, in: session)

        // Worktree A's active tab settles on its second tab.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: a.id))
        let a2 = session.openTab(container: .worktree(projectID: project.id, worktreeID: a.id))
        // Visiting sibling B used to overwrite the shared project-level
        // pointer, which is exactly what we're guarding against.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: b.id))

        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: a.id))
        #expect(session.activeTabID == a2.id)
    }

    @Test("setActiveContainer restores a project-direct last-active tab after interposing a worktree")
    func setActiveContainer_project_survivesWorktreeDetour() throws {
        let (session, project) = makeSessionWithProject()
        let wt = try appendWorktree(to: project.id, in: session)

        _ = session.openTab(container: .project(project.id))
        let pg2 = session.openTab(container: .project(project.id))
        // Interpose the worktree — activating it must not clobber the
        // project-direct container's own last-active pointer.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: wt.id))

        session.setActiveContainer(.project(project.id))
        #expect(session.activeTabID == pg2.id)
    }
}
