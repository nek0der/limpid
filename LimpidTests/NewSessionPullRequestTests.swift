// NewSessionPullRequestTests.swift
// Limpid — the new worktree sheet's pull request source: what it offers, the lookup, the fetch of the head, and Create.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionPullRequestTests {
    private typealias Fixture = NewSessionActionsTests.Fixture

    private static func withFixture(
        _ forge: FakePullRequests? = FakePullRequests(),
        _ body: (Fixture, FakePullRequests?) async throws -> Void
    ) async throws {
        try await withTempDir { dir in
            let fixture = Fixture(directory: dir)
            fixture.pullRequests = forge
            try await body(fixture, forge)
        }
    }

    /// The form with the pull request source chosen, the forge asked what
    /// it offers.
    private static func pullRequestForm(_ fixture: Fixture) async throws -> NewSessionModel {
        var model = try await fixture.load()
        await model.setPullRequestAvailability(NewSessionActions.pullRequestAvailability(for: model, stores: fixture.stores))
        model.source = .pullRequest
        model.open = .nothing
        return model
    }

    /// The field set to `number`, and its lookup answered.
    private static func lookUp(_ number: Int, in model: inout NewSessionModel, _ fixture: Fixture) async throws {
        model.setPullRequestText("#\(number)")
        let lookup = try #require(await NewSessionActions.lookUpPullRequest(number, for: model, stores: fixture.stores))
        model.setPullRequestLookup(lookup, for: number)
    }

    // MARK: - What the source offers

    @Test func withNoForge_theSourceIsOff_andSaysWhy() async throws {
        try await Self.withFixture(nil) { fixture, _ in
            let model = try await Self.pullRequestForm(fixture)
            #expect(model.context.pullRequests == .noForge)
            #expect(!model.canChoosePullRequest)
            #expect(model.problem == .pullRequestsUnavailable(.noForge))
            #expect(NewSessionProblemText.pullRequestsUnavailable(.noForge) != nil)
        }
    }

    @Test(arguments: [PullRequestAvailability.toolMissing(.gitHub), .notSignedIn(.gitLab)])
    func aCLIMissingOrSignedOut_turnsTheSourceOff_namingTheCLI(_ availability: PullRequestAvailability) async throws {
        let forge = FakePullRequests()
        forge.availability = availability
        try await Self.withFixture(forge) { fixture, _ in
            let model = try await Self.pullRequestForm(fixture)
            #expect(!model.canChoosePullRequest)
            #expect(model.plan == nil)
            let said = try #require(NewSessionProblemText.pullRequestsUnavailable(availability)).resolved(in: Locale(identifier: "en"))
            #expect(said.contains(availability == .toolMissing(.gitHub) ? "gh" : "glab"))
        }
    }

    /// While the forge is still being asked, the segment can be chosen; the
    /// form makes nothing until it answers.
    @Test func stillChecking_theSourceCanBeChosen_butMakesNothingYet() async throws {
        try await Self.withFixture { fixture, _ in
            var model = try await fixture.load()
            model.source = .pullRequest
            #expect(model.context.pullRequests == .checking)
            #expect(model.canChoosePullRequest)
            #expect(model.plan == nil)
            #expect(NewSessionProblemText.pullRequestsUnavailable(.checking) == nil)
        }
    }

    // MARK: - The lookup

    @Test func aNumberNotThere_saysSo_andMakesNothing() async throws {
        try await Self.withFixture { fixture, forge in
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(404, in: &model, fixture)
            #expect(model.problem == .pullRequestNotFound(404))
            #expect(model.plan == nil)
            #expect(forge?.asked == [404])
        }
    }

    @Test func whileItIsLookedUp_theLineSaysSo_andCreateWaits() async throws {
        try await Self.withFixture { fixture, _ in
            var model = try await Self.pullRequestForm(fixture)
            model.setPullRequestText("12")
            #expect(model.branchLine == .lookingUp(12))
            #expect(model.plan == nil)
        }
    }

    /// An answer for a number the field no longer names is dropped: Create
    /// never makes a worktree of a request the field does not say.
    @Test func anAnswerForANumberNoLongerTyped_isDropped() async throws {
        try await Self.withFixture { fixture, _ in
            var model = try await Self.pullRequestForm(fixture)
            model.setPullRequestText("12")
            model.setPullRequestText("13")
            model.setPullRequestLookup(.found(.fixture(12)), for: 12)
            #expect(model.pullRequest == .lookingUp(13))
            model.setPullRequestText("")
            #expect(model.pullRequest == .none)
        }
    }

    /// A link to another repository's request is not looked up: its number
    /// here would be another request.
    @Test func aLinkToAnotherRepository_isRefused_andNotLookedUp() async throws {
        try await Self.withFixture { fixture, _ in
            var model = try await Self.pullRequestForm(fixture)
            model.setPullRequestText("https://github.com/someone/else/pull/12")
            #expect(model.problem == .pullRequestElsewhere("github.com/someone/else"))
            #expect(model.branchLine == .problem(.pullRequestElsewhere("github.com/someone/else")))
            model.setPullRequestText("https://github.com/acme/app/pull/12")
            #expect(model.pullRequestLinkElsewhere == nil)
            #expect(model.pullRequest == .lookingUp(12))
        }
    }

    /// After a lookup that failed, any edit of the field asks again, the
    /// same number too.
    @Test func anEditAfterAFailedLookup_asksAgain() async throws {
        try await Self.withFixture { fixture, _ in
            var model = try await Self.pullRequestForm(fixture)
            model.setPullRequestText("12")
            model.setPullRequestLookup(.failed("offline"), for: 12)
            #expect(model.problem == .pullRequestLookupFailed(12, "offline"))
            model.setPullRequestText("#12")
            #expect(model.pullRequest == .lookingUp(12))
        }
    }

    @Test func aRequestPickedFromTheMenu_isFoundAtOnce() async throws {
        try await Self.withFixture { fixture, forge in
            forge?.open = [.fixture(5, branch: "feat/five")]
            var model = try await Self.pullRequestForm(fixture)
            model.openPullRequests = await NewSessionActions.openPullRequests(for: model, stores: fixture.stores)
            let picked = try #require(model.openPullRequests.first)
            model.choosePullRequest(picked)
            #expect(model.pullRequestNumber == 5)
            #expect(model.outcome == .pullRequest(number: 5, branch: "feat/five", isExisting: false))
            #expect(forge?.asked.isEmpty == true, "the menu's request needs no lookup")
        }
    }

    // MARK: - Create

    /// The head is fetched from the forge's ref before anything is made,
    /// and the new branch starts at the commit the fetch brought, whatever
    /// the forge said before.
    @Test func create_fetchesTheHeadFirst_andBranchesAtTheFetchedCommit() async throws {
        try await Self.withFixture { fixture, forge in
            forge?.add(.fixture(12, branch: "fix/login", commit: "old"))
            fixture.git.nextFetchedRef = FetchedRef(result: .success(), commit: "fetched")
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(12, in: &model, fixture)
            #expect(model.plan?.pullRequest?.ref == "refs/pull/12/head")

            #expect(await fixture.create(model) == .created(branch: "fix/login"))
            #expect(fixture.git.fetchRefCalls == ["origin refs/pull/12/head"])
            #expect(Array(fixture.git.operations.prefix(3)) == ["fetch ref", "branch", "worktree add"])
            #expect(fixture.git.branchCalls.first?.name == "fix/login")
            #expect(fixture.git.branchCalls.first?.startPoint == "fetched")
            #expect(fixture.git.createCalls.first?.baseBranch == "fix/login")
        }
    }

    /// A fork's request comes through the base repository's own ref: no
    /// remote is added for the fork. Its branch `main` meets the local
    /// `main`, which stays where it is: the request gets `pr/<n>`.
    @Test func aForksRequest_comesFromTheBasesRef_andLeavesTheLocalBranchOfItsName() async throws {
        try await Self.withFixture { fixture, forge in
            fixture.facts.localBranchTips = ["main": "mine"]
            forge?.add(.fixture(7, branch: "main", commit: "theirs", forkOwner: "alice"))
            fixture.git.nextFetchedRef = FetchedRef(result: .success(), commit: "theirs")
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(7, in: &model, fixture)
            #expect(model.pullRequestHeadName == "alice:main")
            #expect(model.baseLine.map { NewSessionModel.baseLineText($0, locale: Locale(identifier: "en")) }
                == "PR #7 · Open · from alice’s fork · Request 7")

            #expect(await fixture.create(model) == .created(branch: "pr/7"))
            #expect(fixture.git.fetchRefCalls == ["origin refs/pull/7/head"])
            #expect(fixture.git.branchCalls.map(\.name) == ["pr/7"])
        }
    }

    /// The fetched commit is the one a local branch of the request's name
    /// is at already: that branch is checked out, nothing made.
    @Test func aLocalBranchAtTheFetchedCommit_isCheckedOut_withNoNewBranch() async throws {
        try await Self.withFixture { fixture, forge in
            fixture.facts.localBranches = ["main", "fix/login"]
            fixture.facts.localBranchTips = ["main": "m", "fix/login": "same"]
            forge?.add(.fixture(12, branch: "fix/login"))
            fixture.git.nextFetchedRef = FetchedRef(result: .success(), commit: "same")
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(12, in: &model, fixture)
            // With no commit from the forge, the sheet expects `pr/12`; the
            // fetch then finds `fix/login` already there.
            #expect(model.checkoutBranch == "pr/12")

            #expect(await fixture.create(model) == .created(branch: "fix/login"))
            #expect(fixture.git.branchCalls.isEmpty)
            #expect(fixture.git.createCalls.first?.baseBranch == "fix/login")
        }
    }

    @Test func aLocalBranchAtTheRequestsCommit_checkedOutElsewhere_stopsCreate() async throws {
        try await Self.withFixture { fixture, forge in
            // The project's folder has the branch checked out.
            fixture.facts.localBranches = ["main", "fix/login"]
            fixture.facts.localBranchTips = ["fix/login": "c1"]
            fixture.facts.head = "fix/login"
            forge?.add(.fixture(12, branch: "fix/login", commit: "c1"))
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(12, in: &model, fixture)
            #expect(model.problem == .branchCheckedOut)
            #expect(model.plan == nil)
        }
    }

    @Test func aFetchThatFails_saysSoOnTheSheet_andMakesNothing() async throws {
        try await Self.withFixture { fixture, forge in
            forge?.add(.fixture(12))
            fixture.git.nextFetchedRef = FetchedRef(result: .failure("fatal: couldn't find remote ref refs/pull/12/head"), commit: nil)
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(12, in: &model, fixture)

            let outcome = await fixture.create(model)

            guard case let .failed(message, madeBranch) = outcome else {
                Issue.record("the create did not fail: \(outcome)")
                return
            }
            #expect(madeBranch == nil)
            #expect(message.resolved(in: Locale(identifier: "en")).contains("couldn't find remote ref"))
            #expect(fixture.git.branchCalls.isEmpty)
            #expect(fixture.git.createCalls.isEmpty)
        }
    }

    /// A request no longer open can still be checked out, to read it; the
    /// line under the base says it is closed, as a caution.
    @Test func aClosedRequest_canStillBeMade_andSaysItIsClosed() async throws {
        try await Self.withFixture { fixture, forge in
            forge?.add(.fixture(3, branch: "old", commit: "c", state: .closed))
            var model = try await Self.pullRequestForm(fixture)
            try await Self.lookUp(3, in: &model, fixture)
            #expect(model.plan != nil)
            #expect(model.baseLine.map { NewSessionModel.baseLineText($0, locale: Locale(identifier: "en")) }
                == "PR #3 · Closed · Request 3")
        }
    }
}

/// The pull request's head fetched by real git, from a local bare
/// repository standing in for the forge: the request's commit lives only
/// under the forge's ref, as a fork's does.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionPullRequestGitTests {
    /// Pushes a commit on `branch` from a second clone to `refs/pull/<n>/head`
    /// only, and returns that commit.
    @discardableResult
    private static func pushRequest(_ number: Int, branch: String, to bare: URL, beside repo: TempGitRepo) async throws -> String {
        let clone = repo.url.deletingLastPathComponent().appendingPathComponent("\(repo.url.lastPathComponent)-fork")
        try await TempGitRepo.git(
            ["-c", "init.templateDir=", "clone", "-q", bare.path, clone.path],
            in: repo.url.deletingLastPathComponent()
        )
        try await TempGitRepo.configureForTests(clone)
        try await TempGitRepo.git(["checkout", "-q", "-B", branch], in: clone)
        try Data("from the fork\n".utf8).write(to: clone.appendingPathComponent("fork.txt"))
        try await TempGitRepo.git(["add", "fork.txt"], in: clone)
        try await TempGitRepo.git(["commit", "-q", "-m", "fork"], in: clone)
        try await TempGitRepo.git(["push", "-q", "origin", "HEAD:refs/pull/\(number)/head"], in: clone)
        return try await TempGitRepo.git(["rev-parse", "HEAD"], in: clone)
    }

    @Test func theHead_isFetchedByTheForgesRef_leavingNoRefOfOurs() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        let pushed = try await Self.pushRequest(7, branch: "main", to: bare, beside: repo)

        let fetched = try await LiveGit().fetchRef(repoRoot: repo.url, remote: "origin", ref: ForgeKind.gitHub.headRef(of: 7))

        #expect(fetched.result.succeeded)
        #expect(fetched.commit == pushed)
        #expect(try await repo.git(["for-each-ref", "refs/limpid"]).isEmpty)
        #expect(try await repo.git(["for-each-ref", "refs/remotes/origin", "--format=%(refname)"]) == "refs/remotes/origin/main")
    }

    /// The fork's clone gets the settings the first repository has, so a
    /// developer's global excludes file cannot hide the `fork.txt` it adds.
    @Test func theForksClone_getsTheFixturesLocalOverrides() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        try await Self.pushRequest(7, branch: "main", to: bare, beside: repo)
        let clone = repo.url.deletingLastPathComponent().appendingPathComponent("\(repo.url.lastPathComponent)-fork")

        for (key, value) in [("core.autocrlf", "false"), ("tag.gpgsign", "false"), ("core.excludesFile", "/dev/null")] {
            #expect(try await TempGitRepo.git(["config", "--local", "--get", key], in: clone) == value, "\(key)")
        }
    }

    @Test func aRefTheRemoteDoesNotHave_failsTheFetch() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.addBareOrigin()
        let fetched = try await LiveGit().fetchRef(repoRoot: repo.url, remote: "origin", ref: ForgeKind.gitHub.headRef(of: 99))
        #expect(!fetched.result.succeeded)
        #expect(fetched.commit == nil)
    }

    /// The whole Create through real git: a fork's request whose branch is
    /// `main` gets `pr/7` at the fork's commit, and the person's `main`
    /// does not move.
    @Test func create_makesTheWorktreeAtTheRequestsCommit_andTheLocalMainStays() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        let pushed = try await Self.pushRequest(7, branch: "main", to: bare, beside: repo)
        let main = try await repo.git(["rev-parse", "main"])

        try await withTempDir { dir in
            let session = WorkspaceSession()
            let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "repo")
            session.setActiveContainer(.project(project.id))
            let windows = WindowRegistry(primary: session.primarySelection)
            let forge = FakePullRequests()
            forge.add(.fixture(7, branch: "main", forkOwner: "alice"))
            var stores = NewSessionStores(
                session: session,
                launches: SessionLaunchStore(path: { nil }),
                settingsStore: SettingsStore(directory: dir)
            )
            stores.readFacts = { root, _ in await NewSessionFacts.readGit(root: root) }
            stores.pullRequests = forge
            stores.remembersChoices = false
            let request = NewSessionSheetRequest(projectID: project.id)
            var model = try #require(await NewSessionActions.load(request, window: windows.primary, stores: stores))
            await model.setPullRequestAvailability(NewSessionActions.pullRequestAvailability(for: model, stores: stores))
            model.source = .pullRequest
            model.open = .nothing
            model.runsSetup = false
            model.setPullRequestText("7")
            try model.setPullRequestLookup(#require(await NewSessionActions.lookUpPullRequest(7, for: model, stores: stores)), for: 7)

            #expect(await NewSessionActions
                .create(model, request: request, window: windows.primary, stores: stores) == .created(branch: "pr/7"))

            let worktree = try #require(session.project(project.id)?.worktrees.first { $0.gitRef?.branchName == "pr/7" })
            #expect(try await TempGitRepo.git(["rev-parse", "HEAD"], in: worktree.workingDirectory) == pushed)
            #expect(try await repo.git(["rev-parse", "main"]) == main)
        }
    }
}
