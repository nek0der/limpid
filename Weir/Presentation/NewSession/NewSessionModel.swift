// NewSessionModel.swift
// Weir — what the new worktree sheet holds and what it will make.

import Foundation
import WeirDomain

/// What opens the new worktree sheet in a window: the window's project,
/// and, when ⌥⌘N could not make a worktree at once, why, which the sheet
/// shows as it opens.
struct NewSessionSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let projectID: UUID
    var failure: DisplayText?
}

/// The new worktree sheet's fields, what they allow, and what
/// "Create" makes of them. A value: the sheet holds one and edits it, ⌥⌘N
/// makes one and creates it as it opens, and a test drives it without a
/// window. The sheet only makes a worktree; what opens in it is one choice
/// among the agents found, a shell, and nothing, with no instruction.
struct NewSessionModel {
    /// Where the worktree's branch comes from.
    enum Source: Hashable, Sendable, CaseIterable {
        case newBranch
        case existingBranch
        /// A pull request's branch, fetched from the forge's ref for it.
        case pullRequest
    }

    /// What the pull request field has found.
    enum PullRequestState: Equatable, Sendable {
        /// Nothing typed that reads as a number.
        case none
        case lookingUp(Int)
        case found(PullRequestHead)
        case notFound(Int)
        /// The CLI did not answer; its own words when it gave any.
        case failed(Int, String)

        /// The number this is about, `nil` for none.
        var number: Int? {
            switch self {
            case .none: nil
            case let .lookingUp(number), let .notFound(number), let .failed(number, _): number
            case let .found(head): head.number
            }
        }
    }

    /// A branch a new one can start from: its name as shown, and what git
    /// is given.
    struct Base: Hashable, Sendable {
        let name: String
        let ref: String
        /// For the remote's branch the fetch brings up to date
        /// (`origin/main`): the local branch of the same name, which the
        /// worktree starts from when the fetch fails, and which the sheet
        /// says how far behind it is. `nil` for a local base, or when there
        /// is no local branch of that name.
        var localRef: String?
        /// Whether the base is the remote's branch, which only a fetch
        /// brings up to date.
        var isRemote = false
        /// The branch of the worktree the window shows, which the sheet
        /// names as such ("feat/x (Current Worktree)"), so it is not taken
        /// for the default.
        var isCurrentWorktree = false
    }

    /// Where the fetch before Create stands. The sheet starts it as it
    /// opens, so how far the local branch is behind can be said before the
    /// person presses Create, and Create waits for one still running.
    enum FetchState: Equatable, Sendable {
        /// Not asked for, or the project's folder has no remote to fetch.
        case none
        case fetching
        /// `behind`: how many commits the remote's branch has that the
        /// local one lacks; `nil` when there is no local one to compare.
        case fetched(behind: Int?)
        /// Git failed, or the remote did not answer in time: the worktree
        /// starts from the local branch, and the bar says so.
        case failed
        /// The fetch ran and the remote has no branch of the base's name
        /// (its default is another): the worktree starts from the local
        /// branch, and the bar says why.
        case remoteBranchMissing
    }

    /// What the sheet reads once, as it opens.
    struct Context {
        fileprivate(set) var project: Project
        fileprivate(set) var localBranches: [String]
        /// The branches checked out in the project's folder and its
        /// worktrees: git adds no second worktree on one of them.
        let checkedOutBranches: Set<String>
        /// The branch Git names as the default (`ReviewGit.defaultBase`):
        /// `origin/main` where the remote says so, else a local `main` or
        /// `master`.
        let defaultBase: String?
        /// The branch of the worktree the window shows, offered as a base
        /// of its own.
        let shownBranch: String?
        /// The branch the project's folder has checked out, the base when
        /// there is no default.
        let head: String?
        /// The remote the default base's branch comes from, which the fetch
        /// takes (`NewSessionModel.fetchRemote`); `nil` with none.
        let fetchRemote: String?
        let today: Date
        /// The agents found on the login shell's `PATH`, at their known
        /// locations, or on the project's panes' `PATH`, in the catalog's order
        /// (`AgentCatalog.detectInstallations`): the agents offered.
        var installedAgents: [AgentKind] = AgentCatalog.entries.map(\.kind)
        /// Where that detection found each, handed to the new pane
        /// (`SessionLaunchRequest.executable`): its shim starts it when the
        /// pane's own `PATH` has no agent.
        var agentExecutables: [AgentKind: String] = [:]
        /// Each local branch's commit, which decides whether a pull
        /// request's branch of the same name is reused
        /// (`PullRequestBranchChoice`).
        var localBranchTips: [String: String] = [:]
        /// Whether a worktree can be made from a pull request here, asked
        /// after the sheet opens.
        fileprivate(set) var pullRequests: PullRequestAvailability = .checking
        /// The worktree the window shows, whose uncommitted changes the new
        /// one can take; `nil` when it shows no row of this project.
        var carrySource: CarrySource?
        /// Whether a folder is on disk; a test gives its own.
        let folderExists: (URL) -> Bool
    }

    /// What "Create" makes: the worktree at `path`, on a new branch from
    /// `start` or on the existing branch `start`, then `request` in it.
    struct Plan: Equatable, Sendable {
        let path: URL
        let start: String
        let newBranch: String?
        let request: SessionLaunchRequest
        /// What went short before the worktree is made, for its bar, and
        /// how the carry went once it is.
        var notes: [SessionLaunch.Note]
        /// The pull request whose head is fetched first; `start` and the
        /// branch are then decided again from the commit it brings
        /// (`NewSessionModel.pullRequestPlan(_:commit:)`).
        var pullRequest: PullRequestFetch?
        /// The worktree whose uncommitted changes move into the new one.
        var carry: CarrySource?
    }

    /// A worktree whose uncommitted changes the new one takes: its
    /// folder, the branch it is named by, and how many files it has
    /// changed, counted once the sheet is up; `nil` until then, or when Git
    /// did not say.
    struct CarrySource: Equatable, Sendable {
        let root: URL
        let name: String
        var changedFiles: Int?
    }

    /// Where a pull request's head is fetched from.
    struct PullRequestFetch: Equatable, Sendable {
        let head: PullRequestHead
        let remote: String
        let ref: String
    }

    /// What the line under the branch says will happen.
    enum Outcome: Equatable, Sendable {
        case newBranch(String, base: String)
        case existingBranch(String)
        /// A pull request's branch: a new one made at its head, or a local
        /// one already there (`isExisting`).
        case pullRequest(number: Int, branch: String, isExisting: Bool)
    }

    /// Why "Create" is off, the first that applies.
    enum Problem: Equatable, Sendable {
        case branchNameInvalid
        /// A local branch has the typed name; "Existing Branch" checks it
        /// out.
        case branchExists
        /// A local branch of that name is checked out in the project's
        /// folder or another worktree.
        case branchCheckedOut
        /// "Existing Branch" with no branch to check out.
        case noBranchChosen
        case folderExists(URL)
        case noBase
        /// No pull request can be read here; the source's segment says why.
        case pullRequestsUnavailable(PullRequestAvailability)
        /// No number typed yet, or the lookup still runs.
        case noPullRequestChosen
        /// The link pasted is to another repository's request, not the
        /// project's remote's; the argument names that repository.
        case pullRequestElsewhere(String)
        case pullRequestNotFound(Int)
        case pullRequestLookupFailed(Int, String)
    }

    private(set) var context: Context
    var source: Source = .newBranch
    /// The branch field as typed; empty takes the suggested name.
    private(set) var branchName = ""
    /// The existing branch chosen; `nil` when there is none to choose.
    var existingBranch: String?
    /// The base chosen by name; `nil` is the first offered, the default.
    var baseName: String?
    var open: WorktreeOpenChoice
    var fetches: Bool {
        didSet {
            if !fetches {
                fetchState = .none
            }
        }
    }

    var copiesFiles: Bool
    var runsSetup: Bool
    var fetchState: FetchState = .none
    /// The pull request field as typed: `12`, `#12`, or a link to it.
    private(set) var pullRequestText = ""
    var pullRequest: PullRequestState = .none
    /// The open requests the field's menu lists, newest first; empty until
    /// asked for, or when the forge lists none.
    var openPullRequests: [PullRequestHead] = []
    /// Whether the shown worktree's uncommitted changes move into the new
    /// one. Off each time the sheet opens, and never remembered: moving
    /// the person's work is asked for each time.
    var carriesChanges = false

    init(context: Context, choices: NewWorktreeChoices) {
        self.context = context
        open = choices.open
        fetches = choices.fetches
        copiesFiles = choices.copiesIgnoredFiles
        runsSetup = choices.runsSetup
        existingBranch = existingBranches.first
    }

    // MARK: - What the sheet opens with

    /// The choices the sheet, and ⌥⌘N, start from for the project at
    /// `root`: what was opened there last, else anywhere, else what an
    /// earlier build's sheet started, as far as it can open now
    /// (`WorktreeOpenChoice.initial`); the fetch as it was last anywhere;
    /// the copy and the setup as they were last in the project, on before.
    static func initialChoices(_ settings: NewSessionSettings, forProjectAt root: URL, installed: [AgentKind]) -> NewWorktreeChoices {
        let memory = settings.memory(forProjectAt: root)
        return NewWorktreeChoices(
            open: WorktreeOpenChoice.initial(remembered: settings.rememberedOpen(forProjectAt: root), installed: installed),
            fetches: settings.fetchesBeforeCreate,
            copiesIgnoredFiles: memory?.copiesIgnoredFiles ?? true,
            runsSetup: memory?.runsSetup ?? true
        )
    }

    /// What Create will make the next sheet start from.
    var choices: NewWorktreeChoices {
        NewWorktreeChoices(open: open, fetches: fetches, copiesIgnoredFiles: copiesFiles, runsSetup: runsSetup)
    }

    /// The agents the open menu lists: every one the catalog has, those not
    /// found unchosen; a shell and nothing follow (`WorktreeOpenChoice.others`).
    var openMenuAgents: [WorktreeOpenChoice.MenuAgent] {
        WorktreeOpenChoice.menuAgents(catalog: AgentCatalog.entries.map(\.kind), installed: context.installedAgents)
    }

    // MARK: - Files and setup

    /// The files the project names to copy, as Project Settings lists them.
    var filesToCopy: [String] {
        context.project.ignoredFilesToCopy ?? []
    }

    /// Whether there is anything to copy; the checkbox is off without.
    var canCopyFiles: Bool {
        !filesToCopy.isEmpty
    }

    /// The project's setup commands, as they run.
    var setupCommands: [String] {
        context.project.bootstrap.map(\.cmd)
    }

    /// Whether there is a setup to run; the checkbox is off without.
    var canRunSetup: Bool {
        !setupCommands.isEmpty
    }

    /// Whether the shown worktree has changes to carry; the checkbox is off
    /// without. A count Git did not give is taken as some: Create reads the
    /// changes again, and carries nothing when there are none.
    var canCarryChanges: Bool {
        guard let source = context.carrySource else { return false }
        return source.changedFiles.map { $0 > 0 } ?? true
    }

    /// How many files the shown worktree has changed, once counted.
    mutating func setCarryCount(_ count: Int?) {
        context.carrySource?.changedFiles = count
    }

    /// The worktree whose changes Create carries, while asked for.
    var carry: CarrySource? {
        carriesChanges && canCarryChanges ? context.carrySource : nil
    }

    // MARK: - Branch

    /// The local branches a worktree can check out: not one checked out
    /// already, nor git's `(HEAD detached at …)` line. The existing
    /// branch's menu.
    var existingBranches: [String] {
        context.localBranches.filter { !$0.hasPrefix("(") && !context.checkedOutBranches.contains($0) }
    }

    /// The name a new branch gets while the field is empty:
    /// `task/MMDD-n`, the first that is neither a branch nor a folder.
    var suggestedBranchName: String {
        BranchNameSuggester.suggest(today: context.today) { name in
            context.localBranches.contains(name)
                || context.folderExists(context.project.resolvedWorktreeURL(branchLeaf: BranchNameSuggester.folderLeaf(of: name)))
        }
    }

    /// The branch the worktree checks out: the name typed, else the
    /// suggested one, for a new branch; the one chosen for an existing.
    var checkoutBranch: String {
        switch source {
        case .newBranch:
            let typed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? suggestedBranchName : typed
        case .existingBranch:
            return existingBranch ?? ""
        case .pullRequest:
            return pullRequestChoice?.branch ?? ""
        }
    }

    /// The branch field's text.
    mutating func setBranchName(_ text: String) {
        branchName = text
    }

    /// What Create will do, `nil` while something stops it.
    var outcome: Outcome? {
        guard problem == nil else { return nil }
        switch source {
        case .existingBranch:
            return .existingBranch(checkoutBranch)
        case .newBranch:
            guard let base else { return nil }
            return .newBranch(checkoutBranch, base: base.name)
        case .pullRequest:
            guard let head = foundPullRequest, let choice = pullRequestChoice else { return nil }
            if case .existingBranch = choice {
                return .pullRequest(number: head.number, branch: choice.branch, isExisting: true)
            }
            return .pullRequest(number: head.number, branch: choice.branch, isExisting: false)
        }
    }

    /// What the one line under the branch says.
    enum BranchLine: Equatable, Sendable {
        case problem(Problem)
        case outcome(Outcome)
        /// The pull request's lookup runs; muted, as it stops Create only
        /// for the moment.
        case lookingUp(Int)
        case empty
    }

    /// The line under the branch, which keeps its height whatever it says:
    /// the problem that stops Create, else what Create will do.
    var branchLine: BranchLine {
        if source == .pullRequest, case .available = context.pullRequests, pullRequestLinkElsewhere == nil,
           case let .lookingUp(number) = pullRequest
        {
            return .lookingUp(number)
        }
        if let problem {
            return .problem(problem)
        }
        return outcome.map(BranchLine.outcome) ?? .empty
    }

    /// git made the new branch and then failed to add the worktree: the
    /// retry checks that branch out rather than making it again.
    mutating func useMadeBranch(_ branch: String) {
        if !context.localBranches.contains(branch) {
            context.localBranches.append(branch)
        }
        source = .existingBranch
        existingBranch = branch
    }

    /// The project as its settings now have it: the placement decides the
    /// destination, the setup and the files to copy what the boxes offer.
    mutating func setProject(_ project: Project) {
        context.project = project
    }

    /// What the forge said of pull requests here, asked after the sheet
    /// opens.
    mutating func setPullRequestAvailability(_ availability: PullRequestAvailability) {
        context.pullRequests = availability
    }

    /// The pull request field's text. A number other than the one found
    /// clears what was found, so Create never makes a worktree of a request
    /// the field no longer names. Any edit after a lookup that failed asks
    /// again, the same number too: that is how the person tries again.
    mutating func setPullRequestText(_ text: String) {
        let isEdit = text != pullRequestText
        pullRequestText = text
        let number = pullRequestNumber
        let hasFailed = switch pullRequest {
        case .notFound, .failed: true
        case .none, .lookingUp, .found: false
        }
        if number != pullRequest.number || (isEdit && hasFailed) {
            pullRequest = number.map(PullRequestState.lookingUp) ?? .none
        }
    }

    /// A request picked from the field's menu: found already, as the list
    /// gave it.
    mutating func choosePullRequest(_ head: PullRequestHead) {
        pullRequestText = "#\(head.number)"
        pullRequest = .found(head)
    }

    // MARK: - Base and fetch

    /// The remote the fetch takes for the default base: the one its
    /// name starts with (`origin/main`), else the local branch's upstream,
    /// else `origin`, else the only remote. Only that one: fetching every
    /// remote would wait on each.
    static func fetchRemote(defaultBase: String?, upstreamRemote: String?, remotes: [String]) -> String? {
        if let defaultBase, let remote = remotes.first(where: { defaultBase.hasPrefix($0 + "/") }) {
            return remote
        }
        if let upstreamRemote, remotes.contains(upstreamRemote) {
            return upstreamRemote
        }
        if remotes.contains("origin") {
            return "origin"
        }
        return remotes.count == 1 ? remotes.first : nil
    }

    /// The bases offered: the default branch, then the branch of
    /// the worktree the window shows when it is another one, else the
    /// branch checked out at the project's root.
    ///
    /// With a fetch (`fetchRemote`), the default is the remote's branch
    /// (`origin/main`), which the fetch has just brought up to date: the
    /// local `main` does not move on a fetch, so starting from it would
    /// start from where the person last pulled. Without one, the default is
    /// the person's local branch of that name when there is one, rather
    /// than what the last fetch saw of the remote's.
    static func bases(
        defaultBase: String?,
        localBranches: [String],
        shownBranch: String?,
        head: String?,
        fetchRemote: String?
    ) -> [Base] {
        var bases: [Base] = []
        if let defaultBase {
            let name = defaultBase.split(separator: "/", maxSplits: 1).count == 2 && !localBranches.contains(defaultBase)
                ? String(defaultBase.split(separator: "/", maxSplits: 1)[1])
                : defaultBase
            let local = localBranches.contains(name) ? name : nil
            if let fetchRemote {
                let remoteRef = "\(fetchRemote)/\(name)"
                bases.append(Base(name: remoteRef, ref: remoteRef, localRef: local, isRemote: true))
            } else {
                bases.append(Base(name: name, ref: local ?? defaultBase))
            }
        }
        if let shownBranch, !bases.contains(where: { $0.name == shownBranch }) {
            bases.append(Base(name: shownBranch, ref: shownBranch, isCurrentWorktree: true))
        }
        if bases.isEmpty, let head {
            bases.append(Base(name: head, ref: head))
        }
        return bases
    }

    /// The remote the fetch takes, while it is asked for.
    var fetchRemote: String? {
        fetches ? context.fetchRemote : nil
    }

    var bases: [Base] {
        Self.bases(
            defaultBase: context.defaultBase,
            localBranches: context.localBranches,
            shownBranch: context.shownBranch,
            head: context.head,
            fetchRemote: fetchRemote
        )
    }

    /// The base in use: the one chosen while it is still offered, else the
    /// default.
    var base: Base? {
        let offered = bases
        return offered.first { $0.name == baseName } ?? offered.first
    }

    /// Whether Create must wait for the fetch: it runs still.
    var isFetching: Bool {
        fetchState == .fetching
    }

    /// Whether the base is one only a fetch brings up to date, so the
    /// sheet fetches for it: the remote's branch. A local base, the shown
    /// worktree's branch among them, waits on no fetch.
    var needsFetch: Bool {
        fetchRemote != nil && base?.isRemote == true && source == .newBranch
    }

    /// What went short in the fetch, which the line under the base and
    /// the bar say; `nil` while nothing did.
    var fetchShortfall: SessionLaunch.FetchShortfall? {
        guard let base, base.isRemote else { return nil }
        switch fetchState {
        case .failed:
            // With no local branch of its name, the remote's branch as the
            // last fetch left it is what there is.
            return base.localRef.map { .failed(start: $0, isLastFetched: false) } ?? .failed(start: base.ref, isLastFetched: true)
        case .remoteBranchMissing:
            return .remoteBranchMissing(remote: base.name, start: base.localRef ?? base.ref)
        case .none, .fetching, .fetched:
            return nil
        }
    }

    /// The ref the new branch starts from: the base, or what the fetch's
    /// shortfall says it starts from instead.
    var startRef: String? {
        guard let base else { return nil }
        switch fetchShortfall {
        case let .failed(start, _)?, let .remoteBranchMissing(_, start)?:
            return start
        case nil:
            return base.ref
        }
    }

    /// What the line under the base says of the fetch.
    enum BaseLine: Equatable, Sendable {
        case fetching
        /// The worktree starts from the remote's branch as the fetch left it.
        case fromRemote(String)
        case behind(local: String, count: Int, remote: String)
        case shortfall(SessionLaunch.FetchShortfall)
        /// The pull request found: its state, its fork, its title. A
        /// request no longer open is said as a caution.
        case pullRequest(PullRequestHead)
    }

    /// `nil` for a local base, which no fetch changes.
    var baseLine: BaseLine? {
        if source == .pullRequest {
            return foundPullRequest.map(BaseLine.pullRequest)
        }
        guard let base, base.isRemote, source == .newBranch else { return nil }
        if let fetchShortfall {
            return .shortfall(fetchShortfall)
        }
        switch fetchState {
        case .fetching:
            return .fetching
        case let .fetched(behind?) where behind > 0:
            return base.localRef.map { .behind(local: $0, count: behind, remote: base.name) } ?? .fromRemote(base.name)
        case .none, .fetched, .failed, .remoteBranchMissing:
            return .fromRemote(base.name)
        }
    }

    static func baseLineText(_ line: BaseLine, locale: Locale) -> String {
        let resource: LocalizedStringResource
        switch line {
        case let .pullRequest(head):
            return pullRequestLineText(head, locale: locale)
        case .fetching:
            resource = LocalizedStringResource(
                "Fetching…",
                comment: "New worktree sheet: while git fetches the base's remote, under the base and in the footer"
            )
        case let .fromRemote(remote):
            resource = LocalizedStringResource(
                "Starts from the latest \(shownName(remote)) on the remote",
                comment: "New worktree sheet: the line under the base with the fetch on; the argument is the remote's branch"
            )
        case let .behind(local, count, remote):
            resource = LocalizedStringResource(
                "Your local \(shownName(local)) is \(count) commits behind \(shownName(remote))",
                comment: "New worktree sheet: after the fetch; the local branch, how many commits behind, the remote's branch"
            )
        case let .shortfall(shortfall):
            resource = shortfallText(shortfall)
        }
        return resource.resolved(in: locale)
    }

    /// The count the room under the base is measured with: wider than any
    /// a local branch is likely to be behind, even in a large repository
    /// left unpulled for long, so a real count never needs more.
    nonisolated static let mostCommitsBehind = 99999

    /// Every form the line under the base can take while the fetch it
    /// waits for runs and answers as it usually does (fetching, up to date,
    /// no such branch on the remote, behind by many), the one it says now
    /// among them, each once; empty when it says nothing. The sheet keeps
    /// the room of the longest, so the fetch's answer, which comes after
    /// the sheet opens and without the person doing anything, never moves
    /// the rows under it. A failed fetch may take more: the sheet grows
    /// then, as it does for a choice.
    func baseLineForms(locale: Locale) -> [String] {
        guard let line = baseLine else { return [] }
        var lines = [line]
        if case .pullRequest = line {
            // Said once the request is found, and never changed after.
        } else if let base {
            // A remote with no such branch is an answer, not a failure.
            lines += [
                .fetching,
                .fromRemote(base.name),
                .shortfall(.remoteBranchMissing(remote: base.name, start: base.localRef ?? base.ref))
            ]
            if let local = base.localRef {
                lines.append(.behind(local: local, count: Self.mostCommitsBehind, remote: base.name))
            }
        }
        return lines.map { Self.baseLineText($0, locale: locale) }.reduce(into: []) { unique, form in
            if !unique.contains(form) {
                unique.append(form)
            }
        }
    }

    /// What went short in the fetch and where the worktree starts instead:
    /// under the base while the sheet is open, and in the bar once it is
    /// made, so said in the present for both.
    static func shortfallText(_ shortfall: SessionLaunch.FetchShortfall) -> LocalizedStringResource {
        switch shortfall {
        case let .failed(start, false):
            LocalizedStringResource(
                "Couldn’t fetch from the remote, so the worktree starts from the local \(shownName(start)).",
                comment: "New worktree: the fetch before it failed; the argument is the local branch it starts from"
            )
        case let .failed(start, true):
            LocalizedStringResource(
                "Couldn’t fetch from the remote, so the worktree starts from \(shownName(start)) as last fetched.",
                comment: "New worktree: the fetch failed and there is no local branch; the argument is the remote's branch"
            )
        case let .remoteBranchMissing(remote, start):
            LocalizedStringResource(
                "\(remote) isn’t on the remote, so the worktree starts from \(start).",
                comment: "New worktree: the fetch found no such branch; the remote's branch, then the branch it starts from"
            )
        }
    }

    // MARK: - Folder

    /// Where the worktree goes, by the project's placement setting.
    var destination: URL? {
        let leaf = BranchNameSuggester.folderLeaf(of: checkoutBranch)
        guard !leaf.isEmpty else { return nil }
        return context.project.resolvedWorktreeURL(branchLeaf: leaf)
    }

    // MARK: - Create

    var problem: Problem? {
        let branch = checkoutBranch
        switch source {
        case .newBranch:
            guard BranchNameSuggester.isValid(branch) else { return .branchNameInvalid }
            if context.localBranches.contains(branch) {
                return context.checkedOutBranches.contains(branch) ? .branchCheckedOut : .branchExists
            }
            guard base != nil else { return .noBase }
        case .existingBranch:
            guard !branch.isEmpty else { return .noBranchChosen }
        case .pullRequest:
            if let problem = pullRequestProblem {
                return problem
            }
        }
        if let destination, context.folderExists(destination) {
            return .folderExists(destination)
        }
        return nil
    }

    /// What starts in the worktree once it is made.
    var launchRequest: SessionLaunchRequest {
        SessionLaunchRequest(
            open: open,
            executable: open.agent.flatMap { context.agentExecutables[$0] },
            copiesIgnoredFiles: copiesFiles && canCopyFiles,
            runsSetup: runsSetup && canRunSetup
        )
    }

    /// What "Create" makes; `nil` while something is wrong.
    var plan: Plan? {
        guard problem == nil, let destination else { return nil }
        switch source {
        case .newBranch:
            guard let base, let start = startRef else { return nil }
            let notes = (base.isRemote ? fetchShortfall : nil).map { [SessionLaunch.Note.fetch($0)] } ?? []
            return Plan(
                path: destination,
                start: start,
                newBranch: checkoutBranch,
                request: launchRequest,
                notes: notes,
                carry: carry
            )
        case .existingBranch:
            return Plan(path: destination, start: checkoutBranch, newBranch: nil, request: launchRequest, notes: [], carry: carry)
        case .pullRequest:
            guard let head = foundPullRequest, case let .available(repository) = context.pullRequests else { return nil }
            let fetch = PullRequestFetch(head: head, remote: repository.remote, ref: repository.forge.headRef(of: head.number))
            return pullRequestPlan(fetch, commit: head.headCommit)
        }
    }

    // MARK: - The line's words

    /// A piece of the line under the branch: words, or a branch the words
    /// name, which the sheet draws in the code face. Marked where
    /// the sentence is made, so a name is never looked for in the words
    /// afterward, where it could match another word or a single letter.
    struct LineRun: Equatable, Sendable {
        let text: String
        let isCode: Bool

        static func plain(_ text: String) -> LineRun {
            LineRun(text: text, isCode: false)
        }

        static func code(_ text: String) -> LineRun {
            LineRun(text: text, isCode: true)
        }
    }

    /// What the line's sentence is resolved with in the base's place. A
    /// space between two object replacement characters: git refuses a
    /// space in a branch name, so the branch the sentence also names can
    /// never hold it, and no translation writes the character.
    static let baseMarker = "\u{FFFC} \u{FFFC}"
    /// The same, in the branch's place: two spaces, so neither marker is
    /// found inside the other.
    static let branchMarker = "\u{FFFC}  \u{FFFC}"

    /// The outcome's line run by run, each branch it names marked as code.
    static func resultRuns(_ outcome: Outcome, locale: Locale) -> [LineRun] {
        switch outcome {
        case let .newBranch(branch, base):
            runs(
                resultLine(.newBranch(branchMarker, base: baseMarker), locale: locale),
                names: [branchMarker: branch, baseMarker: base]
            )
        case let .existingBranch(branch):
            runs(resultLine(.existingBranch(branchMarker), locale: locale), names: [branchMarker: branch])
        case let .pullRequest(number, branch, isExisting):
            runs(
                resultLine(.pullRequest(number: number, branch: branchMarker, isExisting: isExisting), locale: locale),
                names: [branchMarker: branch]
            )
        }
    }

    /// `line` cut at each marker of `names`: the words between, and in each
    /// marker's place the name it stands for, as code.
    static func runs(_ line: String, names: [String: String]) -> [LineRun] {
        var result: [LineRun] = []
        var rest = Substring(line)
        while let (range, name) = names.compactMap({ marker, name in
            rest.range(of: marker).map { ($0, name) }
        }).min(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            if range.lowerBound > rest.startIndex {
                result.append(.plain(String(rest[..<range.lowerBound])))
            }
            result.append(.code(name))
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty {
            result.append(.plain(String(rest)))
        }
        return result
    }

    /// The outcome as the sheet's muted line under the branch says it, in
    /// `locale`'s language. The branch and the base come first or last as
    /// the language orders them, so each sentence is one phrase.
    static func resultLine(_ outcome: Outcome, locale: Locale) -> String {
        let resource = switch outcome {
        case let .newBranch(branch, base):
            LocalizedStringResource(
                "Creates the new branch \(branch) from \(base)",
                comment: "New worktree sheet: the line under the branch for a new branch; the arguments are the new branch and its base"
            )
        case let .existingBranch(branch):
            LocalizedStringResource(
                "Checks out the existing branch \(branch)",
                comment: "New worktree sheet: the line under the branch for a local branch; the argument is the branch"
            )
        case let .pullRequest(number, branch, false):
            LocalizedStringResource(
                "Checks out PR #\(number) as the new branch \(branch)",
                comment: "New worktree sheet: the line under a pull request's number; the number, then the local branch made for it"
            )
        case let .pullRequest(number, branch, true):
            LocalizedStringResource(
                "Checks out PR #\(number) on the existing branch \(branch), already at its commit",
                comment: "New worktree sheet: a local branch is at the pull request's head already; the number, then the branch"
            )
        }
        return resource.resolved(in: locale)
    }
}

/// What a key does in the new worktree sheet: Return and ⌘⏎ create from
/// anywhere, and an input method's uncommitted text keeps Return for
/// itself.
enum NewSessionKey {
    enum Action: Equatable, Sendable {
        case create
        /// Taken and dropped. ⌘⏎ while an input method has uncommitted
        /// text: passed on, the window's key equivalent would create with
        /// the branch short of that text. Shift-Return: passed on, the
        /// field editor would submit the branch field and select its whole
        /// name, for the next key to replace.
        case swallow
        /// Left to the responder chain: Escape's cancel, an input method's
        /// commit.
        case pass
    }

    static func action(isReturn: Bool, modifiers: KeyModifiers, hasMarkedText: Bool) -> Action {
        guard isReturn, modifiers.isDisjoint(with: [.option, .control]) else { return .pass }
        if hasMarkedText {
            // Return commits the input method's text; ⌘⏎ waits for that.
            return modifiers.contains(.command) ? .swallow : .pass
        }
        if modifiers.contains(.command) {
            return .create
        }
        return modifiers.contains(.shift) ? .swallow : .create
    }
}
