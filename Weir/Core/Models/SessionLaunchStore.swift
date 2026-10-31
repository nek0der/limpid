// SessionLaunchStore.swift
// Weir — a new worktree's copied files, setup, and what it opens, after the worktree is made, and how each failed.

import Foundation
import Observation
import OSLog
import WeirDomain

private let log = Logger.weir("session.launch")

/// What a new worktree gets once it is made: the files Git ignores
/// copied from the project's folder, its setup, and what opens in it.
struct SessionLaunchRequest: Equatable, Sendable {
    let open: WorktreeOpenChoice
    /// The agent's executable as the new worktree sheet found it
    /// (`AgentCatalog.detectInstallations`), staged for the one pane that
    /// starts it; `nil` leaves the shim to search. Only an agent has one.
    let executable: String?
    /// Whether the files the project names (`Project.ignoredFilesToCopy`)
    /// are copied in before the setup.
    let copiesIgnoredFiles: Bool
    /// Whether the project's setup commands run before anything opens.
    let runsSetup: Bool

    init(open: WorktreeOpenChoice, executable: String? = nil, copiesIgnoredFiles: Bool = false, runsSetup: Bool = true) {
        self.open = open
        self.executable = open.agent == nil ? nil : executable
        self.copiesIgnoredFiles = copiesIgnoredFiles
        self.runsSetup = runsSetup
    }

    var agent: AgentKind? {
        open.agent
    }
}

/// A new worktree between its making and what it opens: the files being
/// copied, the setup running, the agent starting, or the stage that failed.
/// Kept until the agent reports its start, or, with a note to read,
/// until the person dismisses it.
struct SessionLaunch: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The files Git ignores that the project names are being copied in.
        case copyingFiles
        /// The project's setup command at `stepIndex`, of `stepCount`.
        case settingUp(stepIndex: Int, stepCount: Int, command: String)
        /// The agent's tab is open and its agent has not reported its
        /// start (SessionStart). `isLaunched`: the pane's terminal is
        /// made, which is when the tab is first shown, so the CLI has
        /// been typed and its time to start runs.
        case starting(isLaunched: Bool)
        /// The agent is in front in its terminal and has not reported its
        /// start: it asks something first (sign in, trust the folder), or
        /// it was started past Weir's shim (an alias to its path), which
        /// Weir cannot follow. Not a stop: nothing failed that Weir
        /// can tell.
        case waitingInTerminal
        /// Everything ran, with notes the person has not dismissed yet.
        case done
        case failed(Failure)
    }

    struct Failure: Equatable, Sendable {
        let stage: NewSessionStage
        let message: DisplayText
        /// What the failed step printed last; empty when it printed
        /// nothing or never ran.
        let logTail: String
        /// New for every failure, so a second one is a new stop in the
        /// attention list rather than the one already dealt with.
        let token: String
        let failedAt: Date
    }

    /// Something that went short of what was asked and did not stop the
    /// worktree: said in the bar until the person dismisses it.
    enum Note: Equatable, Sendable {
        case fetch(FetchShortfall)
        /// Git could not list the files it ignores, so none were copied.
        case ignoredFilesNotListed
        /// These paths could not be copied.
        case copyFailed([String])
        /// These paths were left out: they would have taken the copies past
        /// `limit` bytes.
        case copySkippedOverLimit([String], limit: Int64)
        /// The changes could not be put in this worktree; the one named
        /// still has them, untouched.
        case carryNotApplied(from: String)
        /// The changes are here, and still in the worktree named, which
        /// changed while they were moved.
        case carryLeftInSource(from: String)
        /// The changes are here, and the worktree named could not be
        /// cleared of all of them; `stash` is the copy kept, if one was.
        case carryPartlyCleared(from: String, stash: String?)
    }

    /// Why the worktree does not start from the remote's branch the fetch
    /// was for, and what it starts from instead.
    enum FetchShortfall: Equatable, Sendable {
        /// The fetch failed or did not answer in time. `start` is the local
        /// branch, or, with none, the remote's branch as the last fetch
        /// left it (`isLastFetched`).
        case failed(start: String, isLastFetched: Bool)
        /// The fetch ran and the remote has no such branch.
        case remoteBranchMissing(remote: String, start: String)
    }

    let projectID: UUID
    let worktreeID: UUID
    let worktreeRoot: URL
    let request: SessionLaunchRequest
    /// The window the worktree was asked for in, whose selection its tab
    /// opens in and leaves alone: the sheet's, then the one whose bar was
    /// used last (Retry, Skip Setup). Kept as it was asked, so a window
    /// that is gone by then is no window rather than the primary.
    var windowID: WindowID
    var phase: Phase
    var notes: [Note] = []
    /// The pane the agent was last started in; `nil` before the start.
    var paneID: UUID?
    /// "Skip Setup and Open" was chosen and the step that runs is
    /// stopping; what the worktree opens starts once it has, and the bar
    /// offers the skip no more.
    var isStoppingSetup = false

    var container: ContainerID {
        .worktree(projectID: projectID, worktreeID: worktreeID)
    }

    var failure: Failure? {
        if case let .failed(failure) = phase {
            return failure
        }
        return nil
    }
}

/// The new worktrees whose copy, setup, or agent has not finished, and the
/// one task each runs (its copy, its setup, or the wait for its start). One
/// task a worktree: "Retry" and "Skip Setup and Open" cancel the one that
/// runs before going on, so a setup never runs twice in the same tree.
///
/// The setup runs here, apart from the pane, rather than typed into the
/// agent's terminal: its stage and failed step are then known for certain,
/// and canceling it stops its processes. What the pane would have shown
/// is the failed step's log tail.
@MainActor
@Observable
final class SessionLaunchStore {
    private(set) var launches: [UUID: SessionLaunch] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Whether anything waits on the panes: a launch, its agent's start
    /// among them.
    var isFollowing: Bool {
        !launches.isEmpty
    }

    /// Whether `agent` is the process in front in the pane's terminal, or
    /// the tmux client hosting it; set by the app, which holds the
    /// terminals.
    @ObservationIgnored var isAgentInFront: (@MainActor (UUID, AgentKind) -> Bool)?
    /// Where the setup's `PATH` comes from; a test gives its own.
    @ObservationIgnored private let path: WorktreeSetup.PathSource
    /// What lists the files Git ignores; a test gives its own.
    @ObservationIgnored private let git: any GitRunning
    @ObservationIgnored private let now: () -> Date
    /// How long an agent has, once its terminal runs, to report its start.
    /// A CLI that is not installed, or that exits at once, never does.
    @ObservationIgnored private let startTimeout: Duration
    /// The most the copied files may come to.
    @ObservationIgnored private let copyByteLimit: Int64
    /// The setup steps this store has running, which `cancelAll` stops
    /// when Weir quits, and no other store's.
    @ObservationIgnored private let runningSteps = WorktreeSetup.RunningSteps()

    init(
        path: @escaping WorktreeSetup.PathSource = WorktreeSetup.loginShellPath,
        git: any GitRunning = LiveGit(),
        now: @escaping () -> Date = Date.init,
        startTimeout: Duration = .seconds(30),
        copyByteLimit: Int64 = IgnoredFileCopier.byteLimit
    ) {
        self.path = path
        self.git = git
        self.now = now
        self.startTimeout = startTimeout
        self.copyByteLimit = copyByteLimit
    }

    func launch(in container: ContainerID) -> SessionLaunch? {
        container.worktreeID.flatMap { launches[$0] }
    }

    /// Copies the files the project names into the worktree just made,
    /// runs its setup, then opens what `request` asks in a new tab of its
    /// row, in `window`, the launch's window. `notes` are what went short
    /// before the worktree was made (the fetch).
    func begin(
        projectID: UUID,
        worktreeID: UUID,
        request: SessionLaunchRequest,
        notes: [SessionLaunch.Note] = [],
        in session: WorkspaceSession,
        window: WindowID
    ) {
        guard let worktree = session.worktree(projectID: projectID, worktreeID: worktreeID) else { return }
        let launch = SessionLaunch(
            projectID: projectID,
            worktreeID: worktreeID,
            worktreeRoot: worktree.workingDirectory,
            request: request,
            windowID: window,
            phase: .copyingFiles,
            notes: notes
        )
        launches[worktreeID] = launch
        let patterns = session.project(projectID)?.ignoredFilesToCopy ?? []
        if request.copiesIgnoredFiles, !patterns.isEmpty {
            copyFiles(patterns, of: launch, in: session)
        } else {
            setUp(launch, in: session)
        }
    }

    /// Runs the failed stage again: the setup from its failed step, in the
    /// worktree already made, or the agent's start. The tab opens in
    /// `window`, whose bar asked; `nil` keeps the launch's window, where the
    /// worktree was asked for (`adopt`).
    func retry(worktreeID: UUID, in session: WorkspaceSession, window: WindowID?) {
        guard var launch = launches[worktreeID], let failure = launch.failure else { return }
        adopt(window, into: &launch, for: worktreeID)
        switch failure.stage {
        case let .setup(stepIndex):
            runSetup(from: stepIndex, of: launch, in: session)
        case .creatingWorktree, .startingCLI:
            start(worktreeID: worktreeID, in: session, bringsToFront: true)
        }
    }

    /// Opens what the worktree asked for without the rest of the setup,
    /// once the step that runs has stopped: one that ignores SIGTERM runs
    /// until the SIGKILL a few seconds later, and would write in the folder
    /// beside the agent meanwhile. The tab opens in `window`, whose bar
    /// asked; `nil` keeps the launch's window (`adopt`). It comes to front
    /// only if the person is still on the row they pressed on once the step
    /// has stopped.
    func skipSetup(worktreeID: UUID, in session: WorkspaceSession, window: WindowID?) {
        // Only where the bar offers it: a click that lands after the
        // phase moved on must not open a second tab.
        guard var launch = launches[worktreeID], !launch.isStoppingSetup else { return }
        switch launch.phase {
        case .settingUp:
            break
        case let .failed(failure):
            guard case .setup = failure.stage else { return }
        case .copyingFiles, .starting, .waitingInTerminal, .done:
            return
        }
        adopt(window, into: &launch, for: worktreeID)
        guard let setup = tasks.removeValue(forKey: worktreeID) else {
            start(worktreeID: worktreeID, in: session, bringsToFront: true)
            return
        }
        // The row the bar was pressed on. Stopping the step can take seconds
        // (a SIGTERM ignored until the SIGKILL), and a person who moved to
        // another row meanwhile is typing there: the tab then opens as a
        // setup that ends by itself would (`intentAfterWait`).
        let pressed = session.waitOrigin(in: launch.windowID)
        setup.cancel()
        launch.isStoppingSetup = true
        launches[worktreeID] = launch
        tasks[worktreeID] = Task { [weak self] in
            // The setup's task ends once nothing its step started still runs.
            await setup.value
            guard !Task.isCancelled else { return }
            let isStillThere = session.intentAfterWait(from: pressed) == .person
            self?.start(worktreeID: worktreeID, in: session, bringsToFront: isStillThere)
        }
    }

    /// Stops the copy (between its paths) or the setup before the worktree is deleted, and
    /// returns once it has ended: a step still running would keep writing
    /// into the folder git removes, and make it look modified. A worktree
    /// past its setup is left: if the delete is refused, its tab is still
    /// there, and if not, the closed pane ends it (`follow`).
    func cancelSetup(worktreeID: UUID) async {
        guard let launch = launches[worktreeID] else { return }
        switch launch.phase {
        case .copyingFiles, .settingUp:
            break
        default:
            return
        }
        let task = tasks[worktreeID]
        forget(worktreeID)
        await task?.value
    }

    /// Forgets a launch whose agent waits in its terminal, or whose notes
    /// were read: the person dealt with it.
    func dismiss(worktreeID: UUID) {
        switch launches[worktreeID]?.phase {
        case .waitingInTerminal?, .done?:
            forget(worktreeID)
        default:
            break
        }
    }

    /// Follows each started agent. `agentPanes` are the panes an
    /// agent has reported its start in.
    /// - A launch ends when its agent starts, and goes with its pane. The
    ///   wait for the start runs once the pane's terminal is made.
    /// - A failed start stays when its pane closes, for "Retry", and ends
    ///   if the agent comes up after all.
    /// - A launch with notes stays, done, until they are dismissed, its
    ///   pane closed or not.
    func follow(session: WorkspaceSession, agentPanes: Set<UUID>) {
        for (id, launch) in launches {
            guard let paneID = launch.paneID else { continue }
            let hasStarted = agentPanes.contains(paneID)
            switch launch.phase {
            case let .starting(isLaunched):
                if hasStarted {
                    finish(id)
                } else if session.tab(containing: paneID) == nil {
                    // Its pane closed: its notes, if any, still stand.
                    finish(id)
                } else if !isLaunched, session.stagedLaunch(paneID: paneID) == nil {
                    launched(id, paneID: paneID)
                }
            case .waitingInTerminal:
                if hasStarted {
                    finish(id)
                } else if session.tab(containing: paneID) == nil {
                    // Its pane closed: its notes, if any, still stand.
                    finish(id)
                }
            case let .failed(failure) where failure.stage == .startingCLI:
                if hasStarted {
                    finish(id)
                }
            case .copyingFiles, .settingUp, .done, .failed:
                break
            }
        }
    }

    /// Forgets the launches whose worktree is gone or hidden from the
    /// sidebar, stopping their copy or setup: an agent must not start in a
    /// row no one sees, nor a stop point at one.
    func prune(keeping worktreeIDs: Set<UUID>) {
        for id in launches.keys where !worktreeIDs.contains(id) {
            forget(id)
        }
    }

    /// The agent's terminal runs: the CLI has its time to report.
    private func launched(_ worktreeID: UUID, paneID: UUID) {
        guard var launch = launches[worktreeID] else { return }
        launch.phase = .starting(isLaunched: true)
        launches[worktreeID] = launch
        let timeout = startTimeout
        tasks[worktreeID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.startTimedOut(worktreeID, paneID: paneID)
        }
    }

    /// No start reported in time. An agent in front of its terminal did
    /// start, and waits there; anything else in front (the shell, after
    /// "command not found" or a crash) means it did not.
    private func startTimedOut(_ worktreeID: UUID, paneID: UUID) {
        guard var launch = launches[worktreeID], launch.paneID == paneID,
              launch.phase == .starting(isLaunched: true), let agent = launch.request.agent
        else { return }
        if isAgentInFront?(paneID, agent) == true {
            tasks[worktreeID] = nil
            launch.phase = .waitingInTerminal
            launches[worktreeID] = launch
            return
        }
        let name = AgentProviderRegistry.displayName(for: agent)
        fail(worktreeID, stage: .startingCLI, message: .localized(LocalizedStringResource(
            "\(name) didn’t start. If its terminal shows an error, check that \(agent.launchCommand) is installed, then retry.",
            comment: "New worktree: the agent did not start; the agent's name, then its command"
        )), logTail: "")
    }

    private func forget(_ worktreeID: UUID) {
        tasks.removeValue(forKey: worktreeID)?.cancel()
        launches[worktreeID] = nil
    }

    /// The launch ran to its end: gone, or kept done while it has notes
    /// to read.
    private func finish(_ worktreeID: UUID) {
        tasks.removeValue(forKey: worktreeID)?.cancel()
        guard var launch = launches[worktreeID] else { return }
        guard !launch.notes.isEmpty else {
            launches[worktreeID] = nil
            return
        }
        launch.phase = .done
        launches[worktreeID] = launch
    }

    /// Stops every copy and setup that runs: Weir is quitting, and a step
    /// left running would go on in a worktree no one watches. Waits, a
    /// moment at most, until each step has ended or been sent SIGKILL: the
    /// canceled tasks would send it seconds later, after Weir is gone.
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks = [:]
        runningSteps.stopBeforeExit()
    }

    /// Copies the ignored files `patterns` pick from the project's folder,
    /// off the main actor (`IgnoredFileCopier`), then goes on to the setup.
    /// What could not be copied is a note, not a stop: the worktree is
    /// usable without it, and the person can copy it by hand.
    private func copyFiles(_ patterns: [String], of launch: SessionLaunch, in session: WorkspaceSession) {
        let id = launch.worktreeID
        guard let root = session.project(launch.projectID)?.rootURL else {
            setUp(launch, in: session)
            return
        }
        let git = git
        let limit = copyByteLimit
        let destination = launch.worktreeRoot
        tasks[id] = Task { [weak self] in
            // A listing that failed is said, not taken for a folder with
            // nothing ignored: the files the patterns name are missing
            // from the worktree either way.
            let ignored: [String]?
            do {
                ignored = try await git.listIgnored(repoRoot: root)
            } catch {
                log.error("ignored files not listed: \(String(describing: error), privacy: .private)")
                ignored = nil
            }
            let paths = IgnoredFileSelection.select(patterns: patterns, ignored: ignored ?? [])
            let report = await IgnoredFileCopier.copy(paths, from: root, to: destination, byteLimit: limit)
            guard !Task.isCancelled else { return }
            self?.copied(report, isListed: ignored != nil, worktreeID: id, limit: limit, in: session)
        }
    }

    private func copied(
        _ report: IgnoredFileCopier.Report,
        isListed: Bool,
        worktreeID: UUID,
        limit: Int64,
        in session: WorkspaceSession
    ) {
        tasks[worktreeID] = nil
        // A copy that stopped short was canceled with its launch.
        guard !report.isCanceled, var launch = launches[worktreeID] else { return }
        // The worktree went while its files were copied: nothing is left to
        // set up or open there.
        guard !report.isDestinationGone else {
            forget(worktreeID)
            return
        }
        if !isListed {
            launch.notes.append(.ignoredFilesNotListed)
        }
        if !report.failed.isEmpty {
            launch.notes.append(.copyFailed(report.failed))
        }
        if !report.overLimit.isEmpty {
            launch.notes.append(.copySkippedOverLimit(report.overLimit, limit: limit))
        }
        launches[worktreeID] = launch
        setUp(launch, in: session)
    }

    /// The setup when the worktree asked for it, else what it opens.
    private func setUp(_ launch: SessionLaunch, in session: WorkspaceSession) {
        if launch.request.runsSetup {
            runSetup(from: 0, of: launch, in: session)
        } else {
            start(worktreeID: launch.worktreeID, in: session)
        }
    }

    private func runSetup(from stepIndex: Int, of launch: SessionLaunch, in session: WorkspaceSession) {
        let id = launch.worktreeID
        tasks.removeValue(forKey: id)?.cancel()
        let steps = session.project(launch.projectID)?.bootstrap ?? []
        guard steps.indices.contains(stepIndex) else {
            start(worktreeID: id, in: session)
            return
        }
        noteStep(stepIndex, of: id, steps: steps)
        let path = path
        let runningSteps = runningSteps
        tasks[id] = Task { [weak self] in
            do {
                try await session.runSetup(
                    projectID: launch.projectID,
                    worktreeID: id,
                    from: stepIndex,
                    path: path,
                    runningSteps: runningSteps
                ) { index in
                    self?.noteStep(index, of: id, steps: steps)
                }
            } catch is CancellationError {
                return
            } catch CreateWorktreeError.projectNotFound {
                // The worktree or its project went while the setup ran.
                self?.forget(id)
                return
            } catch let error as CreateWorktreeError {
                guard !Task.isCancelled else { return }
                self?.fail(id, stage: error.stage, message: error.message, logTail: error.logTail)
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failed = self?.runningSetupStep(of: id) ?? stepIndex
                self?.fail(id, stage: .setup(stepIndex: failed), message: Self.setupCouldNotStart(failed, error), logTail: "")
                return
            }
            guard !Task.isCancelled else { return }
            self?.start(worktreeID: id, in: session)
        }
    }

    private func noteStep(_ index: Int, of worktreeID: UUID, steps: [BootstrapItem]) {
        guard var launch = launches[worktreeID], steps.indices.contains(index) else { return }
        launch.phase = .settingUp(stepIndex: index, stepCount: steps.count, command: steps[index].cmd)
        launches[worktreeID] = launch
    }

    /// Opens what the worktree asked for in its row: an agent's tab, after
    /// which the launch waits for the agent's start; a shell's, after which
    /// it is done; or nothing. `bringsToFront` is for "Skip Setup and Open"
    /// and a retry of the agent's start; a setup, first or retried, that
    /// ends by itself brings the tab to front only while the person looks
    /// at the row with no tab of it in front.
    ///
    /// Where it lands is decided first, and written once: the launch's
    /// window while it is there and shows the worktree's project, else no
    /// window. A setup that ends while the person works in another row, or
    /// in a shell tab of this one, must not move them: keys meant for
    /// another terminal would reach this one. So must not one that ends
    /// after the window went to another project, or went away, nor bring
    /// another window forward. The tab then opens behind, and its agent
    /// starts when the tab is opened, which is when its terminal is made.
    ///
    /// A hidden window still shows its project, and is a destination like
    /// a shown one: no keys reach it, and it opens again on the tab. A wait
    /// the person asked through is another matter: hiding the window is
    /// leaving it (`WorkspaceSession.intentAfterWait`).
    private func start(worktreeID: UUID, in session: WorkspaceSession, bringsToFront: Bool = false) {
        tasks[worktreeID] = nil
        guard let launch = launches[worktreeID] else { return }
        guard session.worktree(projectID: launch.projectID, worktreeID: worktreeID) != nil else {
            launches[worktreeID] = nil
            return
        }
        guard launch.request.open != .nothing else {
            finish(worktreeID)
            return
        }
        let window = launch.windowID
        let destination = session.selection(window).flatMap { $0.shownProjectID == launch.projectID ? $0 : nil }
        let selects: Bool
        let intent: SelectionIntent
        if let destination {
            let shown = WorkspaceSession.NavTarget(at: destination)
            let staysBehind = !bringsToFront && (shown.tabID != nil || shown.container != launch.container)
            // In front as the person's choice, within the project the window
            // shows, so no other window is asked; else not selected at all.
            selects = !staysBehind
            intent = staysBehind ? .behind : .person
        } else {
            // No window: the project's view, if it has one, takes the tab
            // as the window would have (`SelectionIntent.behind`).
            selects = true
            intent = .behind
        }
        let paneID = open(launch.request, in: launch.container, session: session, window: window, intent: intent, selects: selects)
        switch Self.outcome(of: launch.request, paneID: paneID) {
        case let .starting(paneID):
            var starting = launch
            starting.phase = .starting(isLaunched: false)
            starting.paneID = paneID
            launches[worktreeID] = starting
        case .finished:
            finish(worktreeID)
        case .failed:
            log.error("new worktree's tab opened with no pane; its agent was not started")
            fail(
                worktreeID,
                stage: .startingCLI,
                message: .localized(LocalizedStringResource(
                    "The agent didn’t start.",
                    comment: "Why a new session stopped: its CLI did not start"
                )),
                logTail: ""
            )
        }
    }

    /// What a launch becomes once its tab is opened.
    enum OpenedTab: Equatable {
        /// The agent's start is awaited in this pane.
        case starting(UUID)
        /// A shell's tab, or none: it has no start to wait for.
        case finished
        /// An agent's tab with no pane: its agent cannot start there.
        case failed
    }

    /// What `request` becomes with its tab opened at `paneID`. An agent's
    /// tab with no pane fails at starting the CLI rather than ending the
    /// launch, which would leave its row with nothing to say why and no
    /// "Retry".
    static func outcome(of request: SessionLaunchRequest, paneID: UUID?) -> OpenedTab {
        guard request.agent != nil else { return .finished }
        return paneID.map(OpenedTab.starting) ?? .failed
    }

    /// Moves `launch` to the window whose bar was used, and stores it, so
    /// its tab opens where the person is rather than where the sheet was.
    /// Only once the press is known to act: one that does nothing moves
    /// nothing. No window (`nil`) keeps the launch's own.
    private func adopt(_ window: WindowID?, into launch: inout SessionLaunch, for worktreeID: UUID) {
        guard let window, launch.windowID != window else { return }
        launch.windowID = window
        launches[worktreeID] = launch
    }

    /// A tab in `container` opening what `request` asks: its agent, waiting
    /// for an instruction, or a shell; none for nothing. Returns its pane.
    /// The last stage of a new worktree. The tab is selected in `window` for
    /// `intent` when it `selects`, and opens behind otherwise
    /// (`WorkspaceSession.openTab`).
    ///
    /// The window and the intent stay two arguments, as in every selection:
    /// one value for both would hide the intent at the call site.
    @discardableResult
    func open( // swiftlint:disable:this function_parameter_count
        _ request: SessionLaunchRequest,
        in container: ContainerID,
        session: WorkspaceSession,
        window: WindowID,
        intent: SelectionIntent,
        selects: Bool
    ) -> UUID? {
        guard request.open != .nothing else { return nil }
        let agent = request.agent
        let paneID = TabActions.newTab(session, in: container, running: agent, window: window, intent: intent, selects: selects)
        if let agent, let paneID, let executable = request.executable {
            session.stageAgentExecutable(AgentInstallation(kind: agent, executable: executable), paneID: paneID)
        }
        return paneID
    }

    /// The setup step a launch was last told is running.
    private func runningSetupStep(of worktreeID: UUID) -> Int? {
        guard case let .settingUp(stepIndex, _, _) = launches[worktreeID]?.phase else { return nil }
        return stepIndex
    }

    /// A setup stopped by an error of the system's rather than the step's
    /// own exit: which command, in the reader's language, before what the
    /// system said of it, which is often English only.
    nonisolated static func setupCouldNotStart(_ stepIndex: Int, _ error: any Error) -> DisplayText {
        switch DisplayText(error: error) {
        case let .localized(said):
            .localized(LocalizedStringResource(
                "Setup command \(stepIndex + 1) couldn’t start: \(said)",
                comment: "New worktree: a setup command couldn’t be started; its number, then the system’s reason"
            ))
        case let .verbatim(said):
            .localized(LocalizedStringResource(
                "Setup command \(stepIndex + 1) couldn’t start: \(said)",
                comment: "New worktree: a setup command couldn’t be started; its number, then the system’s reason"
            ))
        }
    }

    private func fail(_ worktreeID: UUID, stage: NewSessionStage, message: DisplayText, logTail: String) {
        tasks[worktreeID] = nil
        guard var launch = launches[worktreeID] else { return }
        launch.phase = .failed(SessionLaunch.Failure(
            stage: stage,
            message: message,
            logTail: logTail,
            token: UUID().uuidString,
            failedAt: now()
        ))
        launches[worktreeID] = launch
    }
}
