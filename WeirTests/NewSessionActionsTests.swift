// NewSessionActionsTests.swift
// Weir — the new worktree sheet's form as it opens, its fetch, "Create", and ⌥⌘N, without drawing the sheet.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionActionsTests {
    /// A project in a window, and the stores the sheet's actions use, with
    /// Git, the folder, and the settings of their own.
    @MainActor
    final class Fixture {
        let session: WorkspaceSession
        let project: Project
        let windows: WindowRegistry
        let launches: SessionLaunchStore
        let settings: SettingsStore
        let git = FakeGit()
        var facts = NewSessionFacts(localBranches: ["main"], defaultBase: "main", head: "main")
        /// The forge for a pull request source; none unless a suite gives one.
        var pullRequests: (any PullRequestReading)?
        /// How many files the shown row has uncommitted.
        var changedFiles: Int? = 0
        /// This is the day the suggested name is dated by, fixed so that a
        /// run across midnight names the branch by the day it expects.
        let today = Date(timeIntervalSinceReferenceDate: 800_000_000)

        /// This is the suggested name's date part (`BranchNameSuggester`).
        var todayInName: String {
            let parts = Calendar.current.dateComponents([.month, .day], from: today)
            return String(format: "%02d%02d", parts.month ?? 1, parts.day ?? 1)
        }

        init(directory: URL) {
            let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
            self.session = session
            self.project = project
            session.setActiveContainer(.project(project.id))
            windows = WindowRegistry(primary: session.primarySelection)
            launches = SessionLaunchStore(path: { nil }, git: git)
            settings = SettingsStore(directory: directory.appendingPathComponent("settings"))
        }

        var window: ProjectWindowState {
            windows.primary
        }

        var stores: NewSessionStores {
            var stores = NewSessionStores(session: session, launches: launches, settingsStore: settings)
            let facts = facts
            stores.readFacts = { _, _ in facts }
            stores.git = git
            stores.pullRequests = pullRequests
            let changedFiles = changedFiles
            stores.countChanges = { _ in changedFiles }
            stores.folderExists = { _ in false }
            let today = today
            stores.today = { today }
            stores.remembersChoices = true
            return stores
        }

        /// The form as the sheet has it once up: loaded, and the shown
        /// row's changes counted.
        func load() async throws -> NewSessionModel {
            var model = try #require(await NewSessionActions.load(
                NewSessionSheetRequest(projectID: project.id),
                window: window,
                stores: stores
            ))
            await model.setCarryCount(NewSessionActions.countCarryChanges(for: model, stores: stores))
            return model
        }

        func create(_ model: NewSessionModel) async -> NewSessionActions.CreateOutcome {
            await NewSessionActions.create(model, request: NewSessionSheetRequest(projectID: project.id), window: window, stores: stores)
        }

        /// The row the window shows, when it is a worktree of the project.
        var shownWorktree: ContainerID? {
            guard case .worktree = window.selection.activeContainerID else { return nil }
            return window.selection.activeContainerID
        }
    }

    private static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await withTempDir { dir in
            try await body(Fixture(directory: dir))
        }
    }

    @Test func theForm_opensWithWhatTheFolderSays_andTheProjectsRememberedChoices() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts(
                localBranches: ["main", "feat/x"],
                defaultBase: "origin/main",
                head: "main",
                installations: [
                    AgentInstallation(kind: .claude, executable: "/opt/bin/claude"),
                    AgentInstallation(kind: .codex, executable: "/opt/bin/codex")
                ],
                remotes: ["origin"]
            )
            fixture.settings.settings.newSession.remember(
                NewWorktreeChoices(open: .agent(.codex), fetches: true, copiesIgnoredFiles: false, runsSetup: true),
                forProjectAt: fixture.project.rootURL
            )

            let model = try await fixture.load()

            #expect(model.open == .agent(.codex))
            #expect(!model.copiesFiles)
            #expect(model.context.fetchRemote == "origin")
            #expect(model.base?.name == "origin/main")
            #expect(model.context.checkedOutBranches.contains("main"))
            #expect(model.context.installedAgents == [.claude, .codex])
            #expect(model.context.agentExecutables[.codex] == "/opt/bin/codex")
        }
    }

    @Test func theProjectGone_opensNoForm() async throws {
        try await Self.withFixture { fixture in
            let gone = await NewSessionActions.load(
                NewSessionSheetRequest(projectID: UUID()),
                window: fixture.window,
                stores: fixture.stores
            )
            #expect(gone == nil)
        }
    }

    @Test func aWorktreeMade_isSelected_itsLaunchBegins_andTheChoicesAreKept() async throws {
        try await Self.withFixture { fixture in
            var model = try await fixture.load()
            model.open = .shell
            model.setBranchName("feat/try")

            let outcome = await fixture.create(model)

            #expect(outcome == .created(branch: "feat/try"))
            let row = try #require(fixture.shownWorktree)
            // The launch goes on in the row: with no setup, the shell's tab.
            await pollUntil { !fixture.session.tabs(in: row).isEmpty }
            #expect(fixture.session.tabs(in: row).count == 1)
            #expect(fixture.git.branchCalls.map(\.name) == ["feat/try"])
            #expect(fixture.settings.settings.newSession.memory(forProjectAt: fixture.project.rootURL)?.open == "shell")
            #expect(fixture.settings.settings.newSession.lastOpen == "shell")
        }
    }

    /// A sidebar header's ＋ on a project no window shows: the worktree made
    /// switches this window to it, and its launch goes on here.
    @Test func aWorktreeOfAProjectNoWindowShows_switchesThisWindow_andItsLaunchIsHere() async throws {
        try await Self.withFixture { fixture in
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            let request = NewSessionSheetRequest(projectID: other.id)
            var model = try #require(await NewSessionActions.load(request, window: fixture.window, stores: fixture.stores))
            model.open = .shell
            model.setBranchName("feat/other")

            #expect(await NewSessionActions.create(model, request: request, window: fixture.window, stores: fixture.stores)
                == .created(branch: "feat/other"))

            #expect(fixture.window.selection.shownProjectID == other.id)
            let row = fixture.window.selection.activeContainerID
            #expect(row.projectID == other.id && row.worktreeID != nil)
            await pollUntil { !fixture.session.tabs(in: row).isEmpty }
            #expect(fixture.window.selection.activeTabID == fixture.session.tabs(in: row).first?.id)
        }
    }

    /// Another window shows the project by the time the worktree is made:
    /// the selection and the launch go to that window, not the one the
    /// sheet was in.
    @Test func aWorktreeOfAProjectAnotherWindowShows_isSelectedAndLaunchedThere() async throws {
        try await Self.withFixture { fixture in
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            let request = NewSessionSheetRequest(projectID: other.id)
            var model = try #require(await NewSessionActions.load(request, window: fixture.window, stores: fixture.stores))
            model.open = .shell
            model.setBranchName("feat/there")
            let second = fixture.session.addWindow(showing: other.id, layoutFrom: fixture.window.id)

            #expect(await NewSessionActions.create(model, request: request, window: fixture.window, stores: fixture.stores)
                == .created(branch: "feat/there"))

            #expect(fixture.window.selection.shownProjectID == fixture.project.id, "this window stays on its project")
            let row = second.activeContainerID
            #expect(row.projectID == other.id && row.worktreeID != nil)
            await pollUntil { !fixture.session.tabs(in: row).isEmpty }
            #expect(second.activeTabID == fixture.session.tabs(in: row).first?.id)
            #expect(fixture.window.selection.activeTabID != second.activeTabID)
        }
    }

    @Test func nothingToOpen_makesTheRowWithNoTab() async throws {
        try await Self.withFixture { fixture in
            var model = try await fixture.load()
            model.open = .nothing
            #expect(await fixture.create(model) == .created(branch: "task/\(fixture.todayInName)-1"))
            let row = try #require(fixture.shownWorktree)
            #expect(fixture.session.tabs(in: row).isEmpty)
            #expect(fixture.launches.launches.isEmpty)
        }
    }

    /// Git made the branch, then could not add the worktree on it: the
    /// sheet stays open saying so, the retry checks the branch out rather
    /// than making it again, and nothing is remembered from a create that
    /// made no worktree.
    @Test func aWorktreeGitCouldNotAddOnTheBranchItMade_failsWithTheBranch_forTheRetry() async throws {
        try await Self.withFixture { fixture in
            fixture.git.nextCreateResult = .failure("fatal: could not create work tree dir")
            var model = try await fixture.load()
            model.setBranchName("feat/try")

            let outcome = await fixture.create(model)

            guard case let .failed(_, madeBranch) = outcome else {
                Issue.record("the create did not fail: \(outcome)")
                return
            }
            #expect(madeBranch == "feat/try")
            #expect(fixture.settings.settings.newSession.memory(forProjectAt: fixture.project.rootURL) == nil)
            #expect(fixture.settings.settings.newSession.lastOpen == nil)
            #expect(fixture.window.selection.activeContainerID == .project(fixture.project.id))
            model.useMadeBranch("feat/try")
            #expect(model.plan?.newBranch == nil, "the retry checks out the branch made")
        }
    }

    // MARK: - Fetch

    /// The fetch runs before anything is made, takes the base's remote
    /// only, and the new branch starts from the remote's branch it brought
    /// up to date.
    @Test func theFetch_runsFirst_andTheBranchStartsFromTheRemotesBranch() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts(localBranches: ["main"], defaultBase: "main", head: "main", remotes: ["origin", "fork"])
            fixture.git.behind = 2
            var model = try await fixture.load()
            model.setBranchName("feat/fresh")
            model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
            #expect(model.fetchState == .fetched(behind: 2))
            #expect(model.baseLine == .behind(local: "main", count: 2, remote: "origin/main"))

            #expect(await fixture.create(model) == .created(branch: "feat/fresh"))
            #expect(fixture.git.fetchCalls == ["origin"])
            #expect(Array(fixture.git.operations.prefix(3)) == ["fetch", "branch", "worktree add"])
            #expect(fixture.git.branchCalls.first?.startPoint == "origin/main")
        }
    }

    /// The test repositories have no remote: nothing is fetched, and the
    /// base is the local branch as before.
    @Test func noRemote_fetchesNothing_andStartsFromTheLocalBranch() async throws {
        try await Self.withFixture { fixture in
            var model = try await fixture.load()
            #expect(model.fetches)
            #expect(model.fetchRemote == nil)
            #expect(await NewSessionActions.fetch(for: model, stores: fixture.stores) == .none)
            model.setBranchName("feat/local")
            #expect(await fixture.create(model) == .created(branch: "feat/local"))
            #expect(fixture.git.fetchCalls.isEmpty)
            #expect(fixture.git.branchCalls.first?.startPoint == "main")
        }
    }

    /// A fetch that fails, or does not answer in time, does not stop the
    /// worktree: it starts from the local branch, and its bar says so.
    @Test func aFailedFetch_stillMakesTheWorktree_fromTheLocalBranch_withANote() async throws {
        for failure in [GitProcessError.timedOut(seconds: 20), nil] {
            try await Self.withFixture { fixture in
                fixture.facts.remotes = ["origin"]
                if let failure {
                    fixture.git.nextFetchError = failure
                } else {
                    fixture.git.nextFetchResult = .failure("fatal: could not read from remote repository")
                }
                var model = try await fixture.load()
                model.open = .shell
                model.setBranchName("feat/offline")
                model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
                #expect(model.fetchState == .failed)

                #expect(await fixture.create(model) == .created(branch: "feat/offline"))
                #expect(fixture.git.branchCalls.first?.startPoint == "main")
                let row = try #require(fixture.shownWorktree)
                #expect(fixture.launches.launch(in: row)?.notes == [.fetch(.failed(start: "main", isLastFetched: false))])
                #expect(fixture.launches.launch(in: row)?.phase == .done)
            }
        }
    }

    /// A remote whose default is another branch has no `origin/main`: the
    /// fetch ran, so it is not said to have failed, and the worktree
    /// starts from the local `main`.
    @Test func aRemoteWithoutTheBranch_startsFromTheLocalOne_andSaysWhy() async throws {
        try await Self.withFixture { fixture in
            fixture.facts.remotes = ["origin"]
            fixture.git.behind = nil
            var model = try await fixture.load()
            model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
            #expect(model.fetchState == .remoteBranchMissing)
            #expect(model.plan?.start == "main")
            #expect(model.plan?.notes == [.fetch(.remoteBranchMissing(remote: "origin/main", start: "main"))])
        }
    }

    /// The remote deleted the branch, and the tracking branch an earlier
    /// fetch left still resolves: the worktree is not said to start from
    /// the latest on the remote.
    @Test func aBranchTheRemoteDeleted_isMissing_thoughItsTrackingBranchIsLeft() async throws {
        try await Self.withFixture { fixture in
            fixture.facts.remotes = ["origin"]
            fixture.git.behind = 3
            fixture.git.nextFetchResult = .failure("fatal: couldn't find remote ref refs/heads/main")
            var model = try await fixture.load()
            model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
            #expect(model.fetchState == .remoteBranchMissing)
            #expect(model.plan?.start == "main")
        }
    }

    /// A base no fetch changes (the shown worktree's branch) fetches
    /// nothing and waits on nothing.
    @Test func aLocalBase_isNotFetchedFor() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts(localBranches: ["main"], defaultBase: nil, head: "dev", remotes: ["origin"])
            let model = try await fixture.load()
            #expect(!model.needsFetch)
            #expect(await NewSessionActions.fetch(for: model, stores: fixture.stores) == .none)
            #expect(fixture.git.fetchCalls.isEmpty)
        }
    }

    /// ⌥⌘N pressed again while the first runs makes no second worktree:
    /// both would take the same suggested name.
    @Test func createAtOnce_twice_makesOneWorktree() async throws {
        try await Self.withFixture { fixture in
            let stores = fixture.stores
            let window = fixture.window
            async let first = NewSessionActions.createAtOnce(in: window, stores: stores)
            async let second = NewSessionActions.createAtOnce(in: window, stores: stores)
            let outcomes = await [first, second]
            #expect(outcomes.filter {
                if case .created = $0 {
                    true
                } else {
                    false
                }
            }.count == 1)
            #expect(outcomes.contains(.nothing))
            #expect(fixture.git.branchCalls.count == 1)
            #expect(!window.isCreatingWorktreeAtOnce)
        }
    }

    // MARK: - ⌥⌘N

    @Test func createAtOnce_followsTheSameRules_andAnnouncesTheBranch() async throws {
        try await Self.withFixture { fixture in
            fixture.facts.remotes = ["origin"]
            fixture.git.behind = 0
            fixture.settings.settings.newSession.remember(
                NewWorktreeChoices(open: .nothing, fetches: true, copiesIgnoredFiles: true, runsSetup: true),
                forProjectAt: fixture.project.rootURL
            )

            let outcome = await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores)

            #expect(outcome == .created(branch: "task/\(fixture.todayInName)-1"))
            #expect(fixture.git.fetchCalls == ["origin"])
            #expect(fixture.git.branchCalls.first?.startPoint == "origin/main")
            #expect(fixture.window.newSession == nil)
            #expect(fixture.shownWorktree != nil)
        }
    }

    /// ⌥⌘N reads the form before Git starts: a person who moved to another
    /// row during that read is not taken back to the worktree made.
    @Test func createAtOnce_aMoveDuringTheLoad_keepsThePersonWhereTheyWent() async throws {
        try await Self.withFixture { fixture in
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            fixture.session.setActiveContainer(.project(fixture.project.id), in: fixture.window.id, intent: .person)
            var stores = fixture.stores
            let facts = fixture.facts
            let session = fixture.session
            let windowID = fixture.window.id
            stores.readFacts = { _, _ in
                await MainActor.run {
                    session.setActiveContainer(.project(other.id), in: windowID, intent: .person)
                }
                return facts
            }

            let outcome = await NewSessionActions.createAtOnce(in: fixture.window, stores: stores)

            #expect(outcome == .created(branch: "task/\(fixture.todayInName)-1"))
            #expect(fixture.window.selection.activeContainerID == .project(other.id))
            #expect(fixture.session.project(fixture.project.id)?.worktrees.count == 1)
        }
    }

    @Test func createAtOnce_opensTheSheet_whenTheFormMakesNothing_orGitFails() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts()
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .openedSheet)
            #expect(fixture.window.newSession?.failure == nil)
        }
        try await Self.withFixture { fixture in
            fixture.git.nextBranchResult = .failure("fatal: not a valid object name")
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .openedSheet)
            #expect(fixture.window.newSession?.failure != nil)
            // A sheet already up is left as it is.
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .nothing)
        }
        // Under another sheet, the failure the sheet would show comes back
        // to be said, not dropped.
        try await Self.withFixture { fixture in
            fixture.git.nextBranchResult = .failure("fatal: not a valid object name")
            fixture.window.hasAttachedSheet = true
            let outcome = await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores)
            guard case .failedUnshown = outcome else {
                Issue.record("expected the failure back, got \(outcome)")
                return
            }
            #expect(fixture.window.newSession == nil)
        }
    }

    // MARK: - The sheet in its window

    @Test func aSecondRequest_doesNotReplaceTheOpenSheet() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        session.setActiveContainer(.project(project.id))
        let window = ProjectWindowState(selection: session.primarySelection)
        SupervisionWindowActions.newSession(in: window, session: session)
        let open = window.newSession
        #expect(open != nil)
        if let open {
            window.newWorktreeSheet.appeared(open.id)
        }
        SupervisionWindowActions.newSession(in: window, session: session)
        #expect(window.newSession == open)
    }
}

/// The fetch against real Git: a bare repository as `origin`, moved on
/// from another clone, as a teammate's push moves it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionFetchGitTests {
    @Test func aFetchedRemote_isTheBase_andTheWorktreeStartsFromItsNewCommit() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        let pushed = try await repo.advance(bare)

        let facts = await NewSessionFacts.readGit(root: repo.url)
        #expect(facts.remotes == ["origin"])
        #expect(facts.upstreamRemote == "origin")
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "repo")
        let model = NewSessionModel(
            context: .init(
                project: project,
                localBranches: facts.localBranches,
                checkedOutBranches: ["main"],
                defaultBase: facts.defaultBase,
                shownBranch: nil,
                head: facts.head,
                fetchRemote: NewSessionModel.fetchRemote(
                    defaultBase: facts.defaultBase,
                    upstreamRemote: facts.upstreamRemote,
                    remotes: facts.remotes
                ),
                today: Date(),
                folderExists: { FileManager.default.fileExists(atPath: $0.path) }
            ),
            choices: NewWorktreeChoices(open: .nothing, fetches: true, copiesIgnoredFiles: false, runsSetup: false)
        )
        var fetched = model
        let stores = NewSessionStores(session: session, launches: SessionLaunchStore(path: { nil }), settingsStore: SettingsStore(
            directory: repo.url.deletingLastPathComponent().appendingPathComponent("\(repo.url.lastPathComponent)-settings")
        ))
        fetched.fetchState = await NewSessionActions.fetch(for: model, stores: stores)
        #expect(fetched.fetchState == .fetched(behind: 1))
        #expect(fetched.base?.name == "origin/main")

        let plan = try #require(fetched.plan)
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: plan.path,
            baseBranch: plan.start,
            newBranchName: plan.newBranch,
            openTab: false
        )
        #expect(try await TempGitRepo.git(["rev-parse", "HEAD"], in: worktree.workingDirectory) == pushed)
        // The local `main` did not move: the fetch moved only `origin/main`.
        #expect(try await repo.git(["rev-parse", "main"]) != pushed)
    }

    /// A remote that cannot be reached fails the fetch, and nothing waits
    /// on a prompt for it.
    @Test func anUnreachableRemote_failsTheFetch_withoutAPrompt() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.addBareOrigin()
        try await repo.git(["remote", "set-url", "origin", repo.url.appendingPathComponent("gone.git").path])
        let result = try await LiveGit().fetch(repoRoot: repo.url, remote: "origin", branch: "main")
        #expect(!result.succeeded)
        #expect(!LiveGit.isMissingRemoteBranch(result), "the remote did not answer; it did not say the branch is gone")
    }

    /// A branch is deleted on the remote, and an earlier fetch left its
    /// tracking branch here: the fetch of that branch says it is gone, where a
    /// fetch of the whole remote succeeds and leaves the tracking branch.
    @Test func aBranchDeletedOnTheRemote_failsItsFetch_asMissing() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        try await repo.git(["push", "-q", "origin", "main:topic"])
        #expect(try await LiveGit().fetch(repoRoot: repo.url, remote: "origin", branch: "topic").succeeded)
        #expect(try await repo.git(["rev-parse", "--verify", "--quiet", "origin/topic"]).isEmpty == false)
        try await TempGitRepo.git(["branch", "-q", "-D", "topic"], in: bare)

        let result = try await LiveGit().fetch(repoRoot: repo.url, remote: "origin", branch: "topic")

        #expect(LiveGit.isMissingRemoteBranch(result))
        #expect(try await repo.git(["rev-parse", "--verify", "--quiet", "origin/topic"]).isEmpty == false)
    }

    /// The person's own ssh command is kept, with batch mode after it, so
    /// a key or a proxy of theirs still works and nothing is asked.
    @Test func theFetchesSSH_keepsThePersonsCommand_inBatchMode() {
        #expect(LiveGit.batchSSHCommand(environment: nil, configured: nil, hasSSHProgram: false) == "ssh -o BatchMode=yes")
        #expect(LiveGit
            .batchSSHCommand(environment: " ", configured: "ssh -i other\n", hasSSHProgram: false) == "ssh -i other -o BatchMode=yes")
        // A program named by GIT_SSH takes no option; it is left as it is.
        #expect(LiveGit.batchSSHCommand(environment: nil, configured: nil, hasSSHProgram: true) == nil)
    }

    /// Of the person's ssh settings, the one Git itself would use gets batch
    /// mode. Git takes `GIT_SSH_COMMAND`, then `core.sshCommand`, then
    /// `GIT_SSH`.
    @Test func theFetchesSSH_followsGitsOrder_forEachPair() {
        // GIT_SSH_COMMAND before core.sshCommand.
        #expect(LiveGit.batchSSHCommand(environment: "ssh -i ~/.ssh/work", configured: "ssh -i other", hasSSHProgram: false)
            == "ssh -i ~/.ssh/work -o BatchMode=yes")
        // GIT_SSH_COMMAND before GIT_SSH.
        #expect(LiveGit.batchSSHCommand(environment: "ssh -i env", configured: nil, hasSSHProgram: true) == "ssh -i env -o BatchMode=yes")
        // core.sshCommand before GIT_SSH: the configured command gets batch mode.
        #expect(LiveGit.batchSSHCommand(environment: nil, configured: "ssh -i other", hasSSHProgram: true)
            == "ssh -i other -o BatchMode=yes")
        // All three set: the environment's command still comes first.
        #expect(LiveGit.batchSSHCommand(environment: "ssh -i env", configured: "ssh -i other", hasSSHProgram: true)
            == "ssh -i env -o BatchMode=yes")
    }
}
