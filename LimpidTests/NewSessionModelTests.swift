// NewSessionModelTests.swift
// Limpid — the new worktree sheet's fields, what they allow, and what Create makes of them.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct NewSessionModelTests {
    private static let today: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 21
        parts.hour = 12
        return Calendar.current.date(from: parts) ?? Date()
    }()

    private static let choices = NewWorktreeChoices(open: .agent(.claude), fetches: true, copiesIgnoredFiles: true, runsSetup: true)

    private static func model(
        branches: [String] = ["main"],
        checkedOut: Set<String> = [],
        defaultBase: String? = "main",
        shownBranch: String? = nil,
        head: String? = "main",
        fetchRemote: String? = nil,
        folders: Set<String> = [],
        installed: [AgentKind] = [.claude, .codex],
        executables: [AgentKind: String] = [:],
        choices: NewWorktreeChoices = choices,
        project: (inout Project) -> Void = { _ in }
    ) -> NewSessionModel {
        var (_, made) = WorkspaceSessionFixture.withProject(name: "demo")
        project(&made)
        return NewSessionModel(
            context: .init(
                project: made,
                localBranches: branches,
                checkedOutBranches: checkedOut,
                defaultBase: defaultBase,
                shownBranch: shownBranch,
                head: head,
                fetchRemote: fetchRemote,
                today: today,
                installedAgents: installed,
                agentExecutables: executables,
                // By the folder's own name: each fixture's project sits in a
                // folder of its own, which the sibling placement prefixes.
                folderExists: { url in folders.contains { url.lastPathComponent.hasSuffix($0) } }
            ),
            choices: choices
        )
    }

    // MARK: - What it opens with

    @Test func theFirstChoices_comeFromWhatWasRemembered() {
        var settings = NewSessionSettings()
        let root = URL(fileURLWithPath: "/tmp/app")
        // Nothing remembered: the first agent found, the fetch on, the
        // copy and the setup on.
        #expect(NewSessionModel.initialChoices(settings, forProjectAt: root, installed: [.codex])
            == NewWorktreeChoices(open: .agent(.codex), fetches: true, copiesIgnoredFiles: true, runsSetup: true))
        settings.remember(
            NewWorktreeChoices(open: .nothing, fetches: false, copiesIgnoredFiles: false, runsSetup: false),
            forProjectAt: root
        )
        #expect(NewSessionModel.initialChoices(settings, forProjectAt: root, installed: [.codex])
            == NewWorktreeChoices(open: .nothing, fetches: false, copiesIgnoredFiles: false, runsSetup: false))
        // Another project takes what was opened last anywhere, and its own
        // copy and setup, on before its first.
        #expect(NewSessionModel.initialChoices(settings, forProjectAt: URL(fileURLWithPath: "/tmp/other"), installed: [.codex])
            == NewWorktreeChoices(open: .nothing, fetches: false, copiesIgnoredFiles: true, runsSetup: true))
    }

    /// A person used to "Create and Start" with an agent gets that agent:
    /// what an earlier build kept is read while nothing newer is.
    @Test func whatAnEarlierBuildStarted_isWhatOpens() {
        var settings = NewSessionSettings()
        let root = URL(fileURLWithPath: "/tmp/app")
        settings.projects[NewSessionSettings.key(forProjectAt: root)] = NewWorktreeProjectMemory(agent: "codex", location: "projectFolder")
        settings.lastAgent = "claude"
        #expect(NewSessionModel.initialChoices(settings, forProjectAt: root, installed: [.claude, .codex]).open == .agent(.codex))
        #expect(NewSessionModel.initialChoices(settings, forProjectAt: URL(fileURLWithPath: "/tmp/b"), installed: [.claude, .codex]).open
            == .agent(.claude))
        // "none" was a terminal: a shell now.
        settings.lastAgent = "none"
        #expect(NewSessionModel.initialChoices(settings, forProjectAt: URL(fileURLWithPath: "/tmp/b"), installed: [.claude]).open == .shell)
    }

    /// The open menu lists every agent the catalog has, in its order, the
    /// ones not found off; a shell and nothing follow, always on.
    @Test func theOpenMenu_listsEveryCatalogAgent_theOnesNotFoundOff() {
        let catalog = AgentCatalog.entries.map(\.kind)
        #expect(Self.model().openMenuAgents.map(\.kind) == catalog)
        #expect(Self.model().openMenuAgents.map(\.isAvailable) == catalog.map { _ in true })
        let codexOnly = Self.model(installed: [.codex]).openMenuAgents
        #expect(codexOnly.map(\.kind) == catalog)
        #expect(codexOnly.map(\.isAvailable) == catalog.map { $0 == .codex })
        #expect(Self.model(installed: []).openMenuAgents.allSatisfy { !$0.isAvailable })
        #expect(WorktreeOpenChoice.others == [.shell, .nothing])
    }

    /// The remembered agent, no longer found: the sheet opens with the
    /// first agent found, else the shell, and the menu still lists the
    /// remembered one, off.
    @Test func aRememberedAgentNotFound_fallsBack_andStaysListedOff() {
        #expect(WorktreeOpenChoice.initial(remembered: ["claude"], installed: [.codex]) == .agent(.codex))
        #expect(WorktreeOpenChoice.initial(remembered: ["claude"], installed: []) == .shell)
        let menu = WorktreeOpenChoice.menuAgents(catalog: [.claude, .codex], installed: [.codex])
        #expect(menu == [.init(kind: .claude, isAvailable: false), .init(kind: .codex, isAvailable: true)])
    }

    @Test func theLaunch_carriesWhatOpens_theExecutableFound_andTheBoxes() {
        let found = "/opt/bin/codex"
        var model = Self.model(executables: [.codex: found]) { project in
            project.bootstrap = [.shorthand("make")]
            project.ignoredFilesToCopy = [".env"]
        }
        model.open = .agent(.codex)
        #expect(model.launchRequest == SessionLaunchRequest(
            open: .agent(.codex),
            executable: found,
            copiesIgnoredFiles: true,
            runsSetup: true
        ))
        model.open = .shell
        model.runsSetup = false
        #expect(model.launchRequest == SessionLaunchRequest(open: .shell, copiesIgnoredFiles: true, runsSetup: false))
    }

    /// A box with nothing to act on asks for nothing: no files named, no
    /// setup, whatever was remembered.
    @Test func theCopyAndTheSetup_needSomethingToActOn() {
        let model = Self.model()
        #expect(!model.canCopyFiles)
        #expect(!model.canRunSetup)
        #expect(model.launchRequest.copiesIgnoredFiles == false)
        #expect(model.launchRequest.runsSetup == false)
        #expect(model.choices.copiesIgnoredFiles, "the choice is kept for a project that names files later")
    }

    // MARK: - Branch

    @Test func anEmptyField_takesTheSuggestedName() {
        var model = Self.model()
        #expect(model.checkoutBranch == "task/1021-1")
        #expect(model.outcome == .newBranch("task/1021-1", base: "main"))
        model.setBranchName("  feat/x ")
        #expect(model.checkoutBranch == "feat/x")
        model.setBranchName("")
        #expect(model.checkoutBranch == "task/1021-1")
    }

    @Test func aSuggestion_skipsANameThatIsTaken_orWhoseFolderExists() {
        #expect(Self.model(branches: ["main", "task/1021-1"]).suggestedBranchName == "task/1021-2")
        #expect(Self.model(folders: ["-task-1021-1"]).suggestedBranchName == "task/1021-2")
    }

    @Test func createMakes_aNewBranchFromTheBase_inThePlacementsFolder() {
        var model = Self.model()
        model.setBranchName("feat/login")
        let destination = model.context.project.resolvedWorktreeURL(branchLeaf: "feat-login")
        #expect(model.destination == destination)
        #expect(model.plan == NewSessionModel.Plan(
            path: destination,
            start: "main",
            newBranch: "feat/login",
            // No setup to run in this project.
            request: SessionLaunchRequest(open: .agent(.claude), runsSetup: false),
            notes: []
        ))
    }

    @Test func anExistingBranch_isCheckedOut_withNoBase() {
        var model = Self.model(branches: ["main", "feat/old", "feat/older"], checkedOut: ["main"])
        model.source = .existingBranch
        #expect(model.existingBranch == "feat/old")
        model.existingBranch = "feat/older"
        #expect(model.outcome == .existingBranch("feat/older"))
        #expect(model.baseLine == nil)
        #expect(model.plan?.start == "feat/older")
        #expect(model.plan?.newBranch == nil)
    }

    @Test func noExistingBranch_stopsCreate() {
        var model = Self.model(branches: ["main"], checkedOut: ["main"])
        model.source = .existingBranch
        #expect(model.existingBranch == nil)
        #expect(model.problem == .noBranchChosen)
        #expect(model.plan == nil)
    }

    @Test func theExistingBranches_leaveOutTheOnesCheckedOut_andADetachedHead() {
        let model = Self.model(branches: ["main", "(HEAD detached at 1a2b)", "feat/a", "feat/b"], checkedOut: ["main", "feat/b"])
        #expect(model.existingBranches == ["feat/a"])
    }

    @Test func aTypedNameThatIsABranch_saysSo() {
        var model = Self.model(branches: ["main", "feat/old"], checkedOut: ["main"])
        model.setBranchName("feat/old")
        #expect(model.problem == .branchExists)
        model.setBranchName("main")
        #expect(model.problem == .branchCheckedOut)
        #expect(model.branchLine == .problem(.branchCheckedOut))
    }

    @Test func aBadName_andAFolderThatExists_stopCreate() {
        var model = Self.model()
        model.setBranchName("bad name")
        #expect(model.problem == .branchNameInvalid)
        #expect(model.outcome == nil)
        #expect(model.plan == nil)

        var crowded = Self.model(folders: ["-feat-here"])
        crowded.setBranchName("feat/here")
        #expect(crowded.problem == .folderExists(crowded.context.project.resolvedWorktreeURL(branchLeaf: "feat-here")))
    }

    @Test func aBranchGitMadeBeforeFailing_isTheRetrysExistingBranch() {
        var model = Self.model()
        model.setBranchName("feat/half")
        model.useMadeBranch("feat/half")
        #expect(model.source == .existingBranch)
        #expect(model.checkoutBranch == "feat/half")
        #expect(model.context.localBranches.contains("feat/half"))
        #expect(model.problem == nil)
        #expect(model.plan?.newBranch == nil)
    }

    @Test func theResultLine_saysWhatCreateWillDo_inEnglishAndJapanese() {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(NewSessionModel.resultLine(.newBranch("task/1014-1", base: "master"), locale: en)
            == "Creates the new branch task/1014-1 from master")
        #expect(NewSessionModel.resultLine(.newBranch("task/1014-1", base: "master"), locale: ja)
            == "master から新しいブランチ task/1014-1 を作成します")
        #expect(NewSessionModel.resultLine(.existingBranch("feat/x"), locale: en) == "Checks out the existing branch feat/x")
        #expect(NewSessionModel.resultLine(.existingBranch("feat/x"), locale: ja) == "既存のブランチ feat/x をチェックアウトします")
    }

    @Test func theResultLine_marksTheBranchesItNames_andNoOtherWord() {
        let en = Locale(identifier: "en")
        // "e" and "main" are in the words too; only the names are code.
        #expect(NewSessionModel.resultRuns(.existingBranch("e"), locale: en)
            == [.plain("Checks out the existing branch "), .code("e")])
        #expect(NewSessionModel.resultRuns(.newBranch("in", base: "main"), locale: en)
            == [.plain("Creates the new branch "), .code("in"), .plain(" from "), .code("main")])
    }

    // MARK: - Base and fetch

    @Test func withoutAFetch_theDefaultBase_isTheLocalBranch_whenThereIsOne() {
        #expect(NewSessionModel.bases(defaultBase: "origin/main", localBranches: ["main"], shownBranch: nil, head: "main", fetchRemote: nil)
            == [.init(name: "main", ref: "main")])
        #expect(NewSessionModel.bases(defaultBase: "origin/main", localBranches: [], shownBranch: nil, head: nil, fetchRemote: nil)
            == [.init(name: "main", ref: "origin/main")])
    }

    /// A fetch does not move the local `main`: with one, the base is the
    /// remote's branch it brought up to date.
    @Test func withAFetch_theDefaultBase_isTheRemotesBranch() {
        #expect(NewSessionModel.bases(
            defaultBase: "origin/main",
            localBranches: ["main"],
            shownBranch: nil,
            head: "main",
            fetchRemote: "origin"
        )
            == [.init(name: "origin/main", ref: "origin/main", localRef: "main", isRemote: true)])
        // A local default with an upstream elsewhere.
        #expect(NewSessionModel.bases(defaultBase: "main", localBranches: ["main"], shownBranch: nil, head: "main", fetchRemote: "upstream")
            == [.init(name: "upstream/main", ref: "upstream/main", localRef: "main", isRemote: true)])
        #expect(NewSessionModel.bases(defaultBase: "origin/main", localBranches: [], shownBranch: nil, head: nil, fetchRemote: "origin")
            == [.init(name: "origin/main", ref: "origin/main", isRemote: true)])
    }

    @Test func theShownWorktreesBranch_followsTheDefault_once() {
        #expect(NewSessionModel.bases(
            defaultBase: "main",
            localBranches: ["main", "feat/x"],
            shownBranch: "feat/x",
            head: "main",
            fetchRemote: nil
        )
            == [.init(name: "main", ref: "main"), .init(name: "feat/x", ref: "feat/x", isCurrentWorktree: true)])
        #expect(NewSessionModel.bases(defaultBase: "main", localBranches: ["main"], shownBranch: "main", head: "main", fetchRemote: nil)
            == [.init(name: "main", ref: "main")])
    }

    @Test func withoutADefault_theRootsBranchIsTheBase() {
        #expect(NewSessionModel.bases(defaultBase: nil, localBranches: ["dev"], shownBranch: nil, head: "dev", fetchRemote: "origin")
            == [.init(name: "dev", ref: "dev")])
        #expect(NewSessionModel.bases(defaultBase: nil, localBranches: [], shownBranch: nil, head: nil, fetchRemote: nil).isEmpty)
    }

    @Test func theRemoteFetched_isTheBasesOwn_thenItsUpstream_thenOrigin_thenTheOnlyOne() {
        #expect(NewSessionModel.fetchRemote(defaultBase: "origin/main", upstreamRemote: nil, remotes: ["origin", "fork"]) == "origin")
        #expect(NewSessionModel.fetchRemote(defaultBase: "main", upstreamRemote: "fork", remotes: ["origin", "fork"]) == "fork")
        #expect(NewSessionModel.fetchRemote(defaultBase: "main", upstreamRemote: nil, remotes: ["fork", "origin"]) == "origin")
        #expect(NewSessionModel.fetchRemote(defaultBase: "main", upstreamRemote: nil, remotes: ["only"]) == "only")
        #expect(NewSessionModel.fetchRemote(defaultBase: "main", upstreamRemote: nil, remotes: ["a", "b"]) == nil)
        // The test repositories have none: nothing is fetched.
        #expect(NewSessionModel.fetchRemote(defaultBase: "main", upstreamRemote: nil, remotes: []) == nil)
    }

    @Test func theFetchBox_switchesTheBase_betweenTheRemotesBranchAndTheLocal() {
        var model = Self.model(fetchRemote: "origin")
        #expect(model.base?.name == "origin/main")
        #expect(model.plan?.start == "origin/main")
        model.fetches = false
        #expect(model.base?.name == "main")
        #expect(model.plan?.start == "main")
        // With no remote, the box asks for nothing.
        let local = Self.model(fetchRemote: nil)
        #expect(local.fetchRemote == nil)
        #expect(local.base?.name == "main")
        #expect(local.baseLine == nil)
    }

    @Test func theLineUnderTheBase_followsTheFetch() {
        var model = Self.model(fetchRemote: "origin")
        #expect(model.baseLine == .fromRemote("origin/main"))
        model.fetchState = .fetching
        #expect(model.baseLine == .fetching)
        #expect(model.isFetching)
        model.fetchState = .fetched(behind: 3)
        #expect(model.baseLine == .behind(local: "main", count: 3, remote: "origin/main"))
        model.fetchState = .fetched(behind: 0)
        #expect(model.baseLine == .fromRemote("origin/main"))
        model.fetchState = .failed
        #expect(model.baseLine == .shortfall(.failed(start: "main", isLastFetched: false)))
        // The fetch turned off forgets where it stood.
        model.fetches = false
        #expect(model.fetchState == .none)
    }

    @Test func aFailedFetch_startsFromTheLocalBranch_andSaysSoInTheBar() {
        var model = Self.model(fetchRemote: "origin")
        model.fetchState = .failed
        #expect(model.plan?.start == "main")
        #expect(model.plan?.notes == [.fetch(.failed(start: "main", isLastFetched: false))])
        model.fetchState = .fetched(behind: 1)
        #expect(model.plan?.start == "origin/main")
        #expect(model.plan?.notes == [])
    }

    @Test func theLinesUnderTheBase_readInEnglishAndJapanese() {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(NewSessionModel.baseLineText(.behind(local: "main", count: 1, remote: "origin/main"), locale: en)
            == "Your local main is 1 commit behind origin/main")
        #expect(NewSessionModel.baseLineText(.behind(local: "main", count: 1, remote: "origin/main"), locale: ja)
            == "ローカルの main は origin/main より 1 コミット遅れています")
        #expect(NewSessionModel.baseLineText(.fromRemote("origin/main"), locale: ja) == "リモートの最新の origin/main から作成します")
        #expect(NewSessionModel.baseLineText(.behind(local: "main", count: 3, remote: "origin/main"), locale: en)
            == "Your local main is 3 commits behind origin/main")
        #expect(NewSessionModel.baseLineText(.fetching, locale: ja) == "フェッチ中…")
        #expect(NewSessionModel.baseLineText(.shortfall(.failed(start: "origin/main", isLastFetched: true)), locale: ja)
            == "リモートからフェッチできなかったため、前回フェッチした origin/main から作成します。")
        #expect(NewSessionModel.baseLineText(.shortfall(.remoteBranchMissing(remote: "origin/main", start: "main")), locale: en)
            == "origin/main isn’t on the remote, so the worktree starts from main.")
    }

    /// The line under the base keeps the room of every answer the fetch
    /// usually gives, from before it answers; a local base has no line,
    /// and so no room.
    @Test func theLineUnderTheBase_offersTheFetchsUsualAnswers_andNoneForALocalBase() {
        let en = Locale(identifier: "en")
        var model = Self.model(fetchRemote: "origin")
        model.fetchState = .fetching
        let forms = model.baseLineForms(locale: en)
        #expect(forms.contains("Fetching…"))
        #expect(forms.contains(NewSessionModel.baseLineText(.fromRemote("origin/main"), locale: en)))
        let farBehind = NewSessionModel.BaseLine.behind(local: "main", count: NewSessionModel.mostCommitsBehind, remote: "origin/main")
        #expect(forms.contains(NewSessionModel.baseLineText(farBehind, locale: en)), "\(forms)")
        let missing = NewSessionModel.BaseLine.shortfall(.remoteBranchMissing(remote: "origin/main", start: "main"))
        #expect(forms.contains(NewSessionModel.baseLineText(missing, locale: en)), "an answer, not a failure: \(forms)")
        #expect(Set(forms).count == forms.count)
        model.fetchState = .fetched(behind: 3)
        let answered = model.baseLineForms(locale: en)
        #expect(answered.contains(NewSessionModel.baseLineText(.behind(local: "main", count: 3, remote: "origin/main"), locale: en)))
        #expect(answered.count == forms.count + 1, "the line said now, with the forms kept before")
        model.fetches = false
        #expect(model.baseLine == nil)
        #expect(model.baseLineForms(locale: en).isEmpty)
    }

    /// With no local branch of its name, a failed fetch starts from the
    /// remote's branch as last fetched, and says it is not the local one.
    @Test func aFailedFetch_withNoLocalBranch_startsFromTheLastFetch() {
        var model = Self.model(branches: ["dev"], defaultBase: "origin/main", fetchRemote: "origin")
        model.fetchState = .failed
        #expect(model.plan?.start == "origin/main")
        #expect(model.plan?.notes == [.fetch(.failed(start: "origin/main", isLastFetched: true))])
    }

    @Test func aRemoteWithoutTheBranch_startsFromTheLocalOne() {
        var model = Self.model(fetchRemote: "origin")
        model.fetchState = .remoteBranchMissing
        #expect(model.plan?.start == "main")
        #expect(model.baseLine == .shortfall(.remoteBranchMissing(remote: "origin/main", start: "main")))
    }

    /// Only the remote's branch waits on the fetch.
    @Test func onlyTheRemotesBranch_needsTheFetch() {
        var model = Self.model(branches: ["main", "feat/x"], shownBranch: "feat/x", fetchRemote: "origin")
        #expect(model.needsFetch)
        model.baseName = "feat/x"
        #expect(!model.needsFetch)
        model.baseName = nil
        model.source = .existingBranch
        #expect(!model.needsFetch)
    }

    @Test func noBase_stopsCreate_forANewBranchOnly() {
        var model = Self.model(branches: ["main", "feat/free"], checkedOut: ["main"], defaultBase: nil, head: nil)
        #expect(model.problem == .noBase)
        #expect(model.outcome == nil)
        model.source = .existingBranch
        #expect(model.problem == nil)
    }

    // MARK: - Folder

    @Test func anotherPlacement_movesTheDestination() {
        var model = Self.model()
        model.setBranchName("feat/x")
        var project = model.context.project
        project.worktreePlacement = .insideHidden
        model.setProject(project)
        #expect(model.destination == project.rootURL.appendingPathComponent(".worktrees/feat-x"))
        project.worktreePlacement = .custom(URL(fileURLWithPath: "/tmp/limpid-wt"))
        model.setProject(project)
        #expect(model.destination == URL(fileURLWithPath: "/tmp/limpid-wt/feat-x"))
    }

    // MARK: - ⌥⌘N

    @Test func createAtOnce_createsTheFormAsItOpens_orOpensTheSheet() {
        #expect(InstantWorktreePlan.decision(for: Self.model()) == .create)
        #expect(InstantWorktreePlan.decision(for: Self.model(defaultBase: nil, head: nil)) == .openSheet)
        #expect(InstantWorktreePlan.announcement(branch: "task/1021-1").resolved(in: Locale(identifier: "ja")) == "task/1021-1 を作成しました")
    }
}
