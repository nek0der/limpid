// NewSessionCarryTests.swift
// Limpid — the new worktree sheet's carry of the shown worktree's uncommitted changes: its rules, its checkbox, and Create with real git.

import Foundation
import Testing
@testable import Limpid

struct UncommittedCarryRulesTests {
    @Test func theFirstRefusal_inOrder() {
        #expect(UncommittedCarryRules.refusal(hasCommit: false, isOperationInProgress: true, usesSparseCheckout: true, usesSplitIndex: true)
            == .noCommit)
        #expect(UncommittedCarryRules.refusal(hasCommit: true, isOperationInProgress: true, usesSparseCheckout: true, usesSplitIndex: false)
            == .operationInProgress)
        #expect(UncommittedCarryRules.refusal(
            hasCommit: true,
            isOperationInProgress: false,
            usesSparseCheckout: false,
            usesSplitIndex: true
        )
            == .unsupportedCheckout)
        #expect(UncommittedCarryRules.refusal(
            hasCommit: true,
            isOperationInProgress: false,
            usesSparseCheckout: false,
            usesSplitIndex: false
        )
            == nil)
    }

    @Test func theCount_takesARenameAsOneFile() {
        #expect(UncommittedCarryRules.changedFileCount(porcelain: "") == 0)
        #expect(UncommittedCarryRules.changedFileCount(porcelain: "MM a.txt\0R  new.txt\0old.txt\0?? n.txt\0 D gone\0") == 4)
        #expect(UncommittedCarryRules.changedFileCount(porcelain: " C copy\0from\0") == 1)
    }

    @Test func aGitlink_isFoundOnEitherSide() {
        let regular = ":100644 100644 aaa bbb M\0a.txt\0"
        #expect(!UncommittedCarryRules.touchesGitlinks(rawDiff: regular))
        #expect(UncommittedCarryRules.touchesGitlinks(rawDiff: regular + ":000000 160000 000 ccc A\0vendor/inner\0"))
        #expect(UncommittedCarryRules.touchesGitlinks(rawDiff: ":160000 160000 ddd eee M\0sub\0"))
        // A path that reads like a mode is a path.
        #expect(!UncommittedCarryRules.touchesGitlinks(rawDiff: ":100644 100644 aaa bbb M\0160000\0"))
    }

    @Test func theConflictedPaths_areTheLinesAfterTheTree() {
        #expect(UncommittedCarryRules.conflictPaths(mergeTreeOutput: "abc123\na.txt\nb.txt\na.txt\n\nmessages") == ["a.txt", "b.txt"])
        #expect(UncommittedCarryRules.conflictPaths(mergeTreeOutput: "abc123\n").isEmpty)
    }

    @Test func anOldGit_isToldApart() {
        #expect(UncommittedCarryRules.isUnknownOption(exitCode: 129, stderr: ""))
        #expect(UncommittedCarryRules.isUnknownOption(exitCode: 1, stderr: "error: unknown option `merge-base'"))
        #expect(!UncommittedCarryRules.isUnknownOption(exitCode: 128, stderr: "fatal: bad object"))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionCarryTests {
    private typealias Fixture = NewSessionActionsTests.Fixture

    // MARK: - The checkbox

    @Test func theFolderShown_withChanges_canBeCarried_andIsOffUntilAskedFor() async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.changedFiles = 3
            var model = try await fixture.load()
            let source = try #require(model.context.carrySource)
            #expect(source.root == fixture.project.rootURL)
            #expect(source.name == "main")
            #expect(model.canCarryChanges)
            #expect(model.plan?.carry == nil, "off until asked for")
            model.carriesChanges = true
            #expect(model.plan?.carry == source)
            #expect(model.carryLine(locale: Locale(identifier: "en")) == "3 Uncommitted · If anything fails, main is left unchanged.")
            #expect(model.choices == NewSessionModel.initialChoices(
                fixture.settings.settings.newSession,
                forProjectAt: fixture.project.rootURL,
                installed: model.context.installedAgents
            ), "the carry is not among the choices kept")
        }
    }

    @Test func aRowWithNothingToCarry_isOff_andSaysSo() async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.changedFiles = 0
            var model = try await fixture.load()
            model.carriesChanges = true
            #expect(!model.canCarryChanges)
            #expect(model.plan?.carry == nil)
            #expect(model.carryLine(locale: Locale(identifier: "ja")) == "未コミットの変更はありません")
        }
    }

    /// A header's ＋ on another project: the window shows no row of it, so
    /// nothing of this window's row goes into that project's worktree.
    @Test func anotherProjectsSheet_carriesNothing() async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.changedFiles = 3
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            let model = try #require(await NewSessionActions.load(
                NewSessionSheetRequest(projectID: other.id),
                window: fixture.window,
                stores: fixture.stores
            ))
            #expect(model.context.carrySource == nil)
            #expect(!model.canCarryChanges)
        }
    }

    // MARK: - Create, with real git

    /// A repository's project in a window, its stores with real git, and
    /// the form, asked to carry, with nothing to open or set up.
    @MainActor
    private struct Form {
        let session: WorkspaceSession
        let windows: WindowRegistry
        let stores: NewSessionStores
        var model: NewSessionModel
        let request: NewSessionSheetRequest

        func create() async -> NewSessionActions.CreateOutcome {
            await NewSessionActions.create(model, request: request, window: windows.primary, stores: stores)
        }
    }

    private static func form(_ repo: TempGitRepo, settings: URL) async throws -> Form {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "repo")
        session.setActiveContainer(.project(project.id))
        let windows = WindowRegistry(primary: session.primarySelection)
        var stores = NewSessionStores(
            session: session,
            launches: SessionLaunchStore(path: { nil }),
            settingsStore: SettingsStore(directory: settings)
        )
        stores.readFacts = { root, _ in await NewSessionFacts.readGit(root: root) }
        stores.remembersChoices = false
        let request = NewSessionSheetRequest(projectID: project.id)
        var model = try #require(await NewSessionActions.load(request, window: windows.primary, stores: stores))
        await model.setCarryCount(NewSessionActions.countCarryChanges(for: model, stores: stores))
        model.open = .nothing
        model.runsSetup = false
        model.fetches = false
        model.carriesChanges = true
        return Form(session: session, windows: windows, stores: stores, model: model, request: request)
    }

    @Test func create_movesTheChangesIntoTheNewWorktree() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try Data("one\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        try await repo.git(["add", "a.txt"])
        try await repo.git(["commit", "-q", "-m", "a"])
        try Data("two\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        try Data("new\n".utf8).write(to: repo.url.appendingPathComponent("b.txt"))

        try await withTempDir { dir in
            var form = try await Self.form(repo, settings: dir)
            #expect(form.model.context.carrySource?.changedFiles == 2)
            form.model.setBranchName("feat/moved")

            #expect(await form.create() == .created(branch: "feat/moved"))

            let project = form.session.project(form.request.projectID)
            let worktree = try #require(project?.worktrees.first { $0.gitRef?.branchName == "feat/moved" })
            #expect(try String(contentsOf: worktree.workingDirectory.appendingPathComponent("a.txt"), encoding: .utf8) == "two\n")
            #expect(try String(contentsOf: worktree.workingDirectory.appendingPathComponent("b.txt"), encoding: .utf8) == "new\n")
            #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
            // A move that went as asked leaves no note to close.
            #expect(form.stores.launches.launches[worktree.id]?.notes.isEmpty ?? true)
        }
    }

    /// Changes that conflict with the start stop Create on the sheet:
    /// nothing is made, no branch, and the source keeps every change.
    @Test func create_withChangesThatConflict_makesNothing_andLeavesTheSource() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try Data("one\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        try await repo.git(["add", "a.txt"])
        try await repo.git(["commit", "-q", "-m", "a"])
        // A branch whose commit changes the same line, checked out nowhere.
        let theirs = try await repo.addLinkedWorktree(branch: "theirs-wt")
        try Data("theirs\n".utf8).write(to: theirs.appendingPathComponent("a.txt"))
        try await TempGitRepo.git(["commit", "-q", "-am", "theirs"], in: theirs)
        try await repo.git(["branch", "theirs-copy", "theirs-wt"])
        try Data("mine\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        let before = try await repo.git(["status", "--porcelain"])

        try await withTempDir { dir in
            var form = try await Self.form(repo, settings: dir)
            form.model.source = .existingBranch
            form.model.existingBranch = "theirs-copy"

            let outcome = await form.create()

            guard case let .failed(message, madeBranch) = outcome else {
                Issue.record("the create did not fail: \(outcome)")
                return
            }
            #expect(madeBranch == nil)
            let said = message.resolved(in: Locale(identifier: "en"))
            #expect(said.contains("a.txt") && said.contains("main is unchanged"))
            #expect(form.session.project(form.request.projectID)?.worktrees.contains { $0.gitRef?.branchName == "theirs-copy" } == false)
            #expect(try await repo.git(["status", "--porcelain"]) == before)
            #expect(try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8) == "mine\n")
        }
    }
}
