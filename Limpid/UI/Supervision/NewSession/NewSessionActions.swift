// NewSessionActions.swift
// Limpid — what the new worktree sheet reads as it opens, its fetch, "Create", and ⌥⌘N's create at once.

import Foundation

/// What the new worktree sheet reads of a project's folder as it opens:
/// its branches, the base Git names and its remote, what it has checked
/// out, and the agents installed.
struct NewSessionFacts: Sendable {
    var localBranches: [String] = []
    var defaultBase: String?
    /// The branch the folder has checked out; `nil` for none.
    var head: String?
    var installations: [AgentInstallation] = []
    /// The folder's remotes (`git remote`).
    var remotes: [String] = []
    /// The remote the default base's local branch tracks, if it does.
    var upstreamRemote: String?
    /// Each local branch's commit (`git for-each-ref refs/heads`).
    var localBranchTips: [String: String] = [:]

    /// Reads them for the folder at `root`, of the project `projectID`,
    /// on whose panes' `PATH` the agents are looked for too
    /// (`AgentCatalog.detectInstallations`). Git failing leaves fewer bases
    /// to offer, not a failure: the folder may be no repository, which the
    /// sheet says on its own, and the worktree stage reports Git's own
    /// words if the person goes on.
    static func read(root: URL, projectID: UUID) async -> NewSessionFacts {
        // The pane `PATH` record is read only when the run writes it: a
        // demo run neither writes nor reads the person's files.
        async let installed = AgentCatalog.detectInstallations(
            panePathRecord: DemoFixture.isDemoActive
                ? nil
                : AgentCatalog.panePathRecordURL(in: LimpidPaths.applicationSupportDirectory(), project: projectID)
        )
        var facts = await readGit(root: root)
        facts.installations = await installed
        return facts
    }

    /// What Git says of the folder at `root`, without the agents.
    static func readGit(root: URL) async -> NewSessionFacts {
        var facts = NewSessionFacts()
        facts.localBranches = await (try? GitProcess.listLocalBranches(repoRoot: root)) ?? []
        facts.defaultBase = await (try? ReviewGit.defaultBase(at: root)) ?? nil
        facts.head = await (try? GitProcess.currentBranch(repoRoot: root)) ?? nil
        facts.remotes = await lines(["remote"], root: root)
        if let base = facts.defaultBase, facts.localBranches.contains(base) {
            facts.upstreamRemote = await lines(["config", "--get", "branch.\(base).remote"], root: root).first
        }
        // The full name, cut here: the short one turns to `heads/x` where a
        // tag is also named `x`. A branch name holds no space (git refuses
        // one), so the last space is the one before the commit.
        for line in await lines(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"], root: root) {
            guard let space = line.lastIndex(of: " ") else { continue }
            let name = line[..<space].dropFirst("refs/heads/".count)
            facts.localBranchTips[String(name)] = String(line[line.index(after: space)...])
        }
        return facts
    }

    /// What `git <args>` prints, a line each; none when it fails.
    private static func lines(_ args: [String], root: URL) async -> [String] {
        guard let result = try? await GitProcess.run(args, cwd: root), result.succeeded else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// The stores the new worktree sheet's actions use (`NewSessionActions`),
/// and its ways to Git and the disk, which a test gives its own.
@MainActor
struct NewSessionStores {
    let session: WorkspaceSession
    let launches: SessionLaunchStore
    /// Holds what the sheet remembers (`newSession`).
    let settingsStore: SettingsStore
    /// Reads the sheet's facts, given the project's folder and its ID.
    var readFacts: @Sendable (URL, UUID) async -> NewSessionFacts = { await NewSessionFacts.read(root: $0, projectID: $1) }
    var git: any GitRunning = LiveGit()
    /// `gh` and `glab`, for a worktree made from a pull request; `nil`
    /// where nothing may ask them (a demo run), which offers none.
    var pullRequests: (any PullRequestReading)?
    /// How many files a worktree has uncommitted, for the carry's checkbox.
    var countChanges: @Sendable (URL) async -> Int? = { await UncommittedChangesCarrier.changedFileCount(in: $0) }
    var folderExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// The day the suggested branch name is dated by.
    var today: () -> Date = Date.init
    /// Whether the person's choices are kept for the next sheet. A demo
    /// run keeps the person's choices as they were.
    var remembersChoices = !DemoFixture.isDemoActive
}

/// The new worktree sheet's work apart from its drawing: the form it opens
/// with, the fetch, "Create" with what follows a partial failure, and ⌥⌘N,
/// which does the same with no sheet.
@MainActor
enum NewSessionActions {
    /// How "Create" ended.
    enum CreateOutcome: Equatable {
        /// Made: the sheet closes. The worktree's branch.
        case created(branch: String)
        /// The form makes nothing yet (`NewSessionModel.plan`).
        case notReady
        /// Nothing usable was made; the sheet stays open with the message.
        /// `madeBranch` is the branch Git made before it failed, which the
        /// retry checks out rather than making again.
        case failed(DisplayText, madeBranch: String?)
    }

    /// The form the sheet opens with for `request`, read from the
    /// project's folder; `nil` when the project is gone.
    static func load(
        _ request: NewSessionSheetRequest,
        window: ProjectWindowState,
        stores: NewSessionStores
    ) async -> NewSessionModel? {
        guard let project = stores.session.project(request.projectID) else { return nil }
        let shown = shownRow(of: project, in: window, session: stores.session)
        let facts = await stores.readFacts(project.rootURL, project.id)
        // The project as it is now: it may have changed under the wait.
        guard let project = stores.session.project(request.projectID) else { return nil }
        // Named by its branch; a worktree on a detached HEAD by its folder.
        // How many files it has changed is counted after the sheet is up
        // (`countCarryChanges`): ⌥⌘N never carries, and a large worktree
        // takes a while to count.
        let carrySource = shown.map { row in
            NewSessionModel.CarrySource(
                root: row.root,
                name: row.branch ?? (row.isProjectFolder ? facts.head : nil) ?? row.root.lastPathComponent,
                changedFiles: nil
            )
        }
        return model(facts: facts, project: project, window: window, stores: stores, carrySource: carrySource)
    }

    /// The row of `project` the window shows: its folder, and its branch
    /// as the sidebar knows it (`nil` for the project's own folder, whose
    /// branch the facts read). `nil` when the window shows another
    /// project's row, or none.
    private static func shownRow(of project: Project, in window: ProjectWindowState, session: WorkspaceSession) -> ShownRow? {
        switch window.selection.activeContainerID {
        case let .worktree(projectID, worktreeID) where projectID == project.id:
            session.worktree(projectID: projectID, worktreeID: worktreeID).map {
                ShownRow(root: $0.workingDirectory, branch: $0.gitRef?.branchName, isProjectFolder: false)
            }
        case let .project(projectID) where projectID == project.id:
            ShownRow(root: project.rootURL, branch: nil, isProjectFolder: true)
        case .worktree, .project, .loose:
            nil
        }
    }

    /// A row the window shows, as the carry names it.
    private struct ShownRow {
        let root: URL
        let branch: String?
        /// The project's own folder, whose branch the facts read.
        let isProjectFolder: Bool
    }

    /// How many files the shown row has changed, for the carry's checkbox:
    /// asked once the sheet is up.
    static func countCarryChanges(for model: NewSessionModel, stores: NewSessionStores) async -> Int? {
        guard let source = model.context.carrySource else { return nil }
        return await stores.countChanges(source.root)
    }

    /// The form for `project` from what was read of its folder: the bases
    /// with the shown worktree's branch among them, the choices remembered
    /// for the project, and the shown row whose changes can come along.
    static func model(
        facts: NewSessionFacts,
        project: Project,
        window: ProjectWindowState,
        stores: NewSessionStores,
        carrySource: NewSessionModel.CarrySource? = nil
    ) -> NewSessionModel {
        let session = stores.session
        let installedAgents = facts.installations.map(\.kind)
        var shownBranch: String?
        if case let .worktree(projectID, worktreeID) = window.selection.activeContainerID, projectID == project.id {
            shownBranch = session.worktree(projectID: projectID, worktreeID: worktreeID)?.gitRef?.branchName
        }
        let checkedOut = Set([facts.head].compactMap(\.self) + project.worktrees.compactMap(\.gitRef?.branchName))
        return NewSessionModel(
            context: .init(
                project: project,
                localBranches: facts.localBranches,
                checkedOutBranches: checkedOut,
                defaultBase: facts.defaultBase,
                shownBranch: shownBranch,
                head: facts.head,
                fetchRemote: NewSessionModel.fetchRemote(
                    defaultBase: facts.defaultBase,
                    upstreamRemote: facts.upstreamRemote,
                    remotes: facts.remotes
                ),
                today: stores.today(),
                installedAgents: installedAgents,
                agentExecutables: Dictionary(facts.installations.map { ($0.kind, $0.executable) }) { first, _ in first },
                localBranchTips: facts.localBranchTips,
                carrySource: carrySource,
                folderExists: stores.folderExists
            ),
            choices: NewSessionModel.initialChoices(
                stores.settingsStore.settings.newSession,
                forProjectAt: project.rootURL,
                installed: installedAgents
            )
        )
    }

    /// Fetches the remote `model`'s base comes from, then reads how far
    /// the local branch is behind it. Only for a base the fetch brings up
    /// to date (`needsFetch`): a local one waits on nothing. A fetch that
    /// fails is `.failed`, and one after which the remote has no branch of
    /// the base's name `.remoteBranchMissing`: the worktree then starts
    /// from the local branch either way, and the bar says which.
    static func fetch(for model: NewSessionModel, stores: NewSessionStores) async -> NewSessionModel.FetchState {
        guard model.needsFetch, let remote = model.fetchRemote, let base = model.base else { return .none }
        let root = model.context.project.rootURL
        let git = stores.git
        // The base is `<remote>/<branch>`, and we fetch that branch only:
        // the tracking branch of one the remote has deleted stays where it
        // was, and is not the latest of anything.
        guard base.ref.hasPrefix(remote + "/") else { return .failed }
        let branch = String(base.ref.dropFirst(remote.count + 1))
        guard let result = try? await git.fetch(repoRoot: root, remote: remote, branch: branch) else { return .failed }
        guard result.succeeded else { return LiveGit.isMissingRemoteBranch(result) ? .remoteBranchMissing : .failed }
        // Comparing the base against itself says whether the fetch left a
        // branch to start from.
        guard await git.commitsBehind(repoRoot: root, local: base.ref, upstream: base.ref) != nil else {
            return .remoteBranchMissing
        }
        guard let local = base.localRef else { return .fetched(behind: nil) }
        return await .fetched(behind: git.commitsBehind(repoRoot: root, local: local, upstream: base.ref))
    }

    // MARK: - Pull requests

    /// Whether the project's folder can make a worktree from a pull request:
    /// a remote on a forge whose CLI is installed and signed in.
    static func pullRequestAvailability(for model: NewSessionModel, stores: NewSessionStores) async -> PullRequestAvailability {
        guard let reader = stores.pullRequests else { return .noForge }
        return await reader.availability(repoRoot: model.context.project.rootURL)
    }

    /// The request the field names, as the forge has it now.
    static func lookUpPullRequest(_ number: Int, for model: NewSessionModel, stores: NewSessionStores) async -> PullRequestLookup? {
        guard let reader = stores.pullRequests, case let .available(repository) = model.context.pullRequests else { return nil }
        return await reader.pullRequest(number, in: repository, repoRoot: model.context.project.rootURL)
    }

    /// The open requests the field's menu lists.
    static func openPullRequests(for model: NewSessionModel, stores: NewSessionStores) async -> [PullRequestHead] {
        guard let reader = stores.pullRequests, case let .available(repository) = model.context.pullRequests else { return [] }
        return await reader.openPullRequests(in: repository, repoRoot: model.context.project.rootURL)
    }

    /// A fetch that could not run: what failed, in the reader's language,
    /// before what git or the system said of it, which is often English
    /// only.
    static func fetchFailure(_ error: any Error) -> DisplayText {
        switch DisplayText(error: error) {
        case let .localized(said):
            .localized(LocalizedStringResource(
                "Couldn’t fetch from the remote: \(said)",
                comment: "New worktree: git fetch could not run; the argument is why: our sentence, or the system’s message"
            ))
        case let .verbatim(said):
            .localized(LocalizedStringResource(
                "Couldn’t fetch from the remote: \(said)",
                comment: "New worktree: git fetch could not run; the argument is why: our sentence, or the system’s message"
            ))
        }
    }

    /// Fetches the request's head and decides the plan again from the
    /// commit it brought (`NewSessionModel.pullRequestPlan`); a failure is
    /// said on the sheet, nothing made.
    private static func fetchPullRequest(
        _ fetch: NewSessionModel.PullRequestFetch,
        model: NewSessionModel,
        stores: NewSessionStores
    ) async -> Result<NewSessionModel.Plan, CreateFailure> {
        let fetched: FetchedRef
        do {
            fetched = try await stores.git.fetchRef(repoRoot: model.context.project.rootURL, remote: fetch.remote, ref: fetch.ref)
        } catch {
            return .failure(CreateFailure(message: fetchFailure(error)))
        }
        guard let commit = fetched.commit else {
            let said = fetched.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CreateFailure(message: .localized(LocalizedStringResource(
                "Couldn’t fetch PR #\(fetch.head.number) from \(fetch.remote). \(said)",
                comment: "New worktree sheet: git could not fetch the pull request's head; the number, the remote, then git's own words"
            ))))
        }
        guard let plan = model.pullRequestPlan(fetch, commit: commit) else {
            // The fetched commit is the one a local branch checked out
            // elsewhere is at, or the folder for its branch is taken now.
            let choice = model.pullRequestChoice(for: fetch.head, commit: commit)
            let path = model.context.project.resolvedWorktreeURL(branchLeaf: BranchNameSuggester.folderLeaf(of: choice.branch))
            let message = if case .checkedOut = choice {
                LocalizedStringResource(
                    "“\(choice.branch)” is checked out in another worktree.",
                    comment: "New worktree sheet: the local branch named is checked out in the project's folder or another worktree"
                )
            } else {
                LocalizedStringResource("A folder already exists at \(PathFormatting.abbreviateHome(path.path)).")
            }
            return .failure(CreateFailure(message: .localized(message)))
        }
        return .success(plan)
    }

    /// A failure answered on the sheet, nothing of the worktree made.
    struct CreateFailure: Error {
        let message: DisplayText
    }

    /// "Create" for `model`'s plan, in `window`: the worktree is made while
    /// the sheet waits, so a failure of Git is answered on the sheet, and
    /// its copy, setup, and what it opens then go on in its row
    /// (`SessionLaunchStore`). A fetch still running is the caller's to
    /// wait for. The choices are kept for the next sheet only once a
    /// worktree was made.
    static func create(
        _ model: NewSessionModel,
        request: NewSessionSheetRequest,
        window: ProjectWindowState,
        stores: NewSessionStores
    ) async -> CreateOutcome {
        // We take the row shown as the person pressed Create: the pull
        // request's fetch, the carry, and Git all take a while, and one who
        // moved to another row meanwhile stays there.
        await create(model, request: request, window: window, stores: stores, asked: stores.session.waitOrigin(in: window.id))
    }

    /// This is `create(_:request:window:stores:)` with where the person was
    /// as they asked, which the caller takes before its first wait: ⌥⌘N's
    /// load and fetch come before this one's.
    private static func create(
        _ model: NewSessionModel,
        request: NewSessionSheetRequest,
        window: ProjectWindowState,
        stores: NewSessionStores,
        asked: WaitOrigin?
    ) async -> CreateOutcome {
        guard var plan = model.plan else { return .notReady }
        if let fetch = plan.pullRequest {
            switch await fetchPullRequest(fetch, model: model, stores: stores) {
            case let .success(fetched):
                plan = fetched
            case let .failure(failure):
                return .failed(failure.message, madeBranch: nil)
            }
        }
        let repoRoot = model.context.project.rootURL
        // The changes are read and placed on the start before anything is
        // made: what stops them stops Create, with the source untouched.
        var carry: PreparedCarry?
        if let source = plan.carry {
            switch await prepareCarry(from: source, onto: plan.start, named: startName(of: model, plan: plan), repoRoot: repoRoot) {
            case let .success(prepared):
                carry = prepared
            case let .failure(failure):
                return .failed(failure.message, madeBranch: nil)
            }
        }
        let session = stores.session
        // The project as Create found it: making a worktree changes the
        // project under the wait, and the choices belong to the one asked.
        let project = session.project(request.projectID)
        do {
            let worktree = try await session.createGitWorktree(
                projectID: request.projectID,
                path: plan.path,
                baseBranch: plan.start,
                newBranchName: plan.newBranch,
                openTab: false,
                in: window.id,
                intent: .person,
                git: stores.git
            )
            // Before the copy and the setup, which may read what the
            // changes bring (a new dependency, a changed setting).
            if let carry, let note = await finishCarry(carry, into: worktree.workingDirectory, repoRoot: repoRoot) {
                plan.notes.append(note)
            }
            session.setActiveContainer(
                .worktree(projectID: request.projectID, worktreeID: worktree.id),
                in: window.id,
                intent: session.intentAfterWait(from: asked)
            )
            // The launch strip goes with the worktree's tabs: to the window
            // that shows the project now, which another one may have come
            // to show during the wait, else to this one.
            let shownIn = session.orderedWindows { $0.shownProjectID == request.projectID }.first ?? window.id
            stores.launches.begin(
                projectID: request.projectID,
                worktreeID: worktree.id,
                request: plan.request,
                notes: plan.notes,
                in: session,
                window: shownIn
            )
            if stores.remembersChoices, let project {
                stores.settingsStore.settings.newSession.remember(model.choices, forProjectAt: project.rootURL)
            }
            return .created(branch: plan.newBranch ?? plan.start)
        } catch let error as CreateWorktreeError {
            // The branch was made: the retry checks it out.
            switch error {
            case let .gitFailedLeavingBranch(_, branch), let .timedOut(_, branch?, _):
                return .failed(error.message, madeBranch: branch)
            default:
                return .failed(error.message, madeBranch: nil)
            }
        } catch {
            return .failed(DisplayText(error: error), madeBranch: nil)
        }
    }

    /// How ⌥⌘N ended.
    enum InstantOutcome: Equatable {
        case created(branch: String)
        /// The sheet opened instead, with why when Git failed.
        case openedSheet
        /// The window shows no project, the project is gone, the sheet is
        /// up already, or another ⌥⌘N is still creating.
        case nothing
        /// Git failed, and the sheet that would say why could not come up
        /// (another sheet over the window, or New Worktree… up already):
        /// the caller says it instead (`NewWorktreeSheetSlot`).
        case failedUnshown(DisplayText)
    }

    /// ⌥⌘N: the sheet's form as it would open for the window's
    /// project, fetched and created at once, with no sheet. When the form
    /// makes nothing, or Git fails, the sheet opens instead, saying why.
    static func createAtOnce(in window: ProjectWindowState, stores: NewSessionStores) async -> InstantOutcome {
        // One at a time: each would read the same branches and suggest the
        // same name, and the second would fail on it.
        guard let projectID = window.selection.shownProjectID, window.newSession == nil, !window.isCreatingWorktreeAtOnce else {
            return .nothing
        }
        window.isCreatingWorktreeAtOnce = true
        defer { window.isCreatingWorktreeAtOnce = false }
        // We take it before the load and the fetch, not once Git starts:
        // one who moved to another row while either ran is not taken back
        // to the worktree made.
        let asked = stores.session.waitOrigin(in: window.id)
        let request = NewSessionSheetRequest(projectID: projectID)
        guard var model = await load(request, window: window, stores: stores) else { return .nothing }
        guard InstantWorktreePlan.decision(for: model) == .create else {
            openSheet(request, in: window)
            return .openedSheet
        }
        if model.needsFetch {
            model.fetchState = .fetching
            model.fetchState = await fetch(for: model, stores: stores)
        }
        switch await create(model, request: request, window: window, stores: stores, asked: asked) {
        case let .created(branch):
            return .created(branch: branch)
        case .notReady:
            openSheet(request, in: window)
            return .openedSheet
        case let .failed(message, _):
            var failed = request
            failed.failure = message
            return openSheet(failed, in: window) == .opened ? .openedSheet : .failedUnshown(message)
        }
    }

    /// The sheet, unless one is up already (a second would replace what
    /// the person typed) or another sheet covers the window.
    @discardableResult
    private static func openSheet(_ request: NewSessionSheetRequest, in window: ProjectWindowState) -> NewWorktreeSheetSlot.Outcome {
        window.openNewWorktreeSheet(request)
    }
}
