// AgentProjectionAdapter.swift
// Weir — one pass of the Rust projection, applied to the interface.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("agent.projection.adapter")

/// Drives one projection pass and applies its answer.
///
/// Everything this does is either looking something up that only this process
/// can (which files are there, which processes are alive, where the user is
/// looking) or applying an answer. No rule lives here: which badge a pane
/// shows, which change is worth announcing, and which record is safe to retire
/// are all decided on the other side of the boundary.
///
/// Passes are triggered by the directories changing and by a timer that asks
/// whether the agent processes are still alive, through `requestPass()`.
/// Tests drive `refresh()` and `requestPass()` directly instead, awaiting
/// `passesSettled()` after the latter, so a case does not depend on a file
/// event arriving, and `noteTurnsChanged()` stands in for the turn
/// directory's.
@MainActor
final class AgentProjectionAdapter {
    private let directories: [String: AgentDirectories]
    private let descriptors: [String: AgentProviderDescriptor]
    private let executor: AgentCommandExecutor
    /// Deletes the turns a pass asks to, off the main actor.
    private let turnCollector: TurnGarbageCollector
    /// This ends the turns a pass read as stopped by the person, off the
    /// main actor and once each.
    private let stoppedTurns: StoppedTurnCloser
    private let processStatus: (String?) -> AgentProcessStatus
    /// Read here as well as written through the executor: an intent is the
    /// evidence that a run was killed at quit rather than lost, and the rules
    /// retire a run whose intent they were not told about.
    private let resumeIntents: AgentResumeIntentStore

    private weak var session: WorkspaceSession?
    private weak var attention: AttentionState?
    private weak var tmuxPresence: TmuxPanePresence?

    /// What the rules remember between passes. Opaque to this process:
    /// reading it here would make its shape a contract. Not private so the
    /// count of what a retention change deletes
    /// (`AgentProjectionAdapter+TurnRetention.swift`) asks the same engine.
    let engine: any ProjectionPassing
    /// What the previous pass's commands came to, reported once and then
    /// dropped so an outcome cannot be replayed.
    private var pending: [AgentCommandOutcome] = []
    private var hasBootstrapped = false

    /// `nonisolated(unsafe)` so `deinit`, which is nonisolated under Swift 6,
    /// can cancel the sources and invalidate the timer. Each source owns the
    /// descriptor it was opened with; see `watch(_:)`.
    private nonisolated(unsafe) var sources: [any DispatchSourceFileSystemObject] = []
    private nonisolated(unsafe) var sweep: Timer?
    private var isWatching = false
    /// The cadence the sweep runs at, or nil while no provider has a record.
    /// Recomputed on every pass so it follows the records. A record with no
    /// process to ask about, such as a tmux-hosted run, still keeps the
    /// sweep going: its presence is re-read on the same pass.
    private(set) var sweepInterval: TimeInterval?
    /// Between the file events and `requestPass()`, so a hook write that fans out
    /// into several events costs one pass now and at most one more later.
    private lazy var watcherPasses = AgentPassCoalescer { [weak self] in self?.requestPass() }
    /// The requested pass running off the main actor, if one is.
    private var passInFlight: Task<Void, Never>?
    /// Whether a pass was requested while one ran.
    private var isPassOwed = false
    /// Bumped by every pass run in place, so an answer still on its way
    /// from a requested pass that started before it is not applied over it.
    private var passGeneration = 0
    /// Whether a turn directory reported a change since a pass last listed
    /// them. The other directories change with every hook write, the turn
    /// records only when one is written or deleted; listing them costs more
    /// the more turns are kept, so a pass for any other change goes by the
    /// last list.
    private var haveTurnsChanged = true
    /// Why the last pass could not run, if it could not. Kept because a pass
    /// that fails changes nothing visible, so without this the only evidence
    /// is a log line nobody is watching.
    private(set) var lastFailure: String?
    /// The hints the person ended a session by (`forgetSession`) that are
    /// still on disk: a hook held their lock, or the file could not go.
    /// Tried again before every pass and at quit, kept from the rules
    /// meanwhile, and kept in a file (`AgentForgottenHintQueue`), so the
    /// ended session is neither shown again nor resumed by any launch.
    private var forgottenHintQueue: AgentForgottenHintQueue
    var forgottenHints: [AgentForgottenHint] {
        forgottenHintQueue.hints
    }

    /// Every tmux socket a record has named. The topology probe needs somewhere
    /// to look, and the records are the only place a socket this process never
    /// spawned is written down.
    private(set) var socketPaths: Set<String> = []
    /// Every recorded turn, as the last pass that succeeded read them.
    let turnHistory = TurnHistory()
    /// Which turn records the projection has already read, so a pass sends
    /// only the ones that changed.
    private let turnRecords = TurnRecordCache()
    /// Where each tmux endpoint's tmux pane sits in every pane attached to
    /// it, by endpoint key, as of the last pass, for the runtimes'
    /// `tmuxLocations` (each runtime names its endpoint). Keyed by the
    /// endpoint, not the pane: two runs in one tmux session reach the same
    /// pane from different tmux panes, and only one of them can be in front.
    private var tmuxLocationsByEndpoint: [String: [UUID: TmuxPaneLocation]] = [:]

    /// The one the application builds: every provider the registry declares,
    /// rooted at this build's own support directory. Tests inject their
    /// directories through the designated initializer instead.
    convenience init(writesFiles: Bool, staged: StagedProjection? = nil) {
        let root = WeirPaths.applicationSupportDirectory()
        let directories = AgentProviderRegistry.directories(under: root)
        let resumeIntents = AgentResumeIntentStore(
            directory: root.appendingPathComponent("resume-intents", isDirectory: true),
            writesFiles: writesFiles
        )
        // The intents an earlier build wrote under each provider's state
        // directory, before they were shared.
        for directory in directories.values {
            resumeIntents.adoptLegacyIntents(
                from: directory.state.appendingPathComponent("resume-intents", isDirectory: true)
            )
        }
        self.init(
            directories: directories,
            descriptors: AgentProviderRegistry.descriptors,
            resumeIntents: resumeIntents,
            writesFiles: writesFiles,
            staged: staged,
            forgottenHintsURL: root.appendingPathComponent(AgentForgottenHintFile.fileName),
            turnDeletionsURL: root.appendingPathComponent(TurnDeletionFile.fileName)
        )
    }

    /// `writesFiles` is false in demo mode, which the app decides. The
    /// adapter then never runs a pass or a lifecycle call, because those are
    /// what delete, move, and rewrite the records: a pass keeps only the
    /// hints of the panes it can see, and a demo window shows none of the
    /// person's. It watches nothing either, since watching creates the
    /// directories. It shows `staged` instead, which the app hands in.
    init(
        directories: [String: AgentDirectories],
        descriptors: [String: AgentProviderDescriptor],
        resumeIntents: AgentResumeIntentStore,
        writesFiles: Bool = true,
        staged: StagedProjection? = nil,
        forgottenHintsURL: URL? = nil,
        turnDeletionsURL: URL? = nil,
        processStatus: @escaping (String?) -> AgentProcessStatus = AgentProcessStatus.inspect,
        turnCollector: TurnGarbageCollector = TurnGarbageCollector(),
        stoppedTurns: StoppedTurnCloser = StoppedTurnCloser(),
        engine: any ProjectionPassing = WeirProjectionBridge.Engine()
    ) {
        self.engine = engine
        self.directories = directories
        self.turnCollector = turnCollector
        self.stoppedTurns = stoppedTurns
        self.descriptors = descriptors
        self.processStatus = processStatus
        self.resumeIntents = resumeIntents
        self.writesFiles = writesFiles
        self.staged = staged
        executor = AgentCommandExecutor(directories: directories, resumeIntents: resumeIntents)
        forgottenHintQueue = AgentForgottenHintQueue(url: writesFiles ? forgottenHintsURL : nil)
        turnDeletions = TurnDeletionQueue(url: writesFiles ? turnDeletionsURL : nil)
    }

    /// See the designated initializer.
    private let writesFiles: Bool
    /// What demo mode shows in place of a pass; `nil` when passes run.
    private let staged: StagedProjection?

    deinit {
        // The descriptors belong to the sources, not to this object: each
        // cancel handler closes the one it captured. Touching them here too
        // would race that handler and close one twice.
        sources.forEach { $0.cancel() }
        sweep?.invalidate()
    }

    func bootstrap(
        into session: WorkspaceSession,
        attention: AttentionState? = nil,
        tmuxPresence: TmuxPanePresence? = nil
    ) {
        self.session = session
        self.attention = attention
        self.tmuxPresence = tmuxPresence
        guard writesFiles else {
            return show(staged, in: session, attention: attention)
        }
        refresh()
        finishInterruptedDeletions()
    }

    /// Finishes the deletions a quit cut short (a record moved aside, its
    /// refs not yet deleted) once a run, whether or not the sweep asks for
    /// anything: otherwise they wait for the next batch, which may not come
    /// for days, with refs no limit counts and a record no list shows.
    private func finishInterruptedDeletions() {
        for directory in Set(directories.values.compactMap(\.turns)) {
            turnCollector.enqueue([], in: directory) { [weak self] deletions in
                guard let self else { return }
                // A record git refused to let go is put back in the list.
                noteTurnsChanged()
                // Moved aside before this run read the records, so no
                // history knows them: what they were comes from the file
                // the run that asked for them kept (`TurnDeletionFile`).
                // Another directory's turns are judged by its own batch.
                announce(turnDeletions.recovered(deletions, recordState: TurnDeletionFile.recordStates(in: directory)))
            }
        }
    }

    /// Starts watching the directories the hooks write into and asking, on a
    /// timer, whether the processes those records name are still running.
    ///
    /// A pass re-reads everything rather than following individual events. One
    /// hook write fires several of them, the directories hold fewer records
    /// than a machine has panes, and a rule that depended on seeing every
    /// event in order would be wrong the first time one was missed. The turn
    /// records are the exception: they grow with every turn, so they are
    /// listed again only when their own directory reports a change.
    func startWatching() {
        stopWatching()
        guard writesFiles else { return }
        let turnDirectories = Set(directories.values.compactMap(\.turns))
        for directory in watchedDirectories() {
            guard let source = watch(directory, isTurns: turnDirectories.contains(directory)) else { continue }
            sources.append(source)
        }
        // A record written between the last listing and the descriptors
        // opening sent no event this watch will see, so one pass reads
        // everything again now rather than at whatever comes next.
        noteTurnsChanged()
        isWatching = true
        rearmSweep()
        if hasBootstrapped {
            watcherPasses.request()
        }
    }

    /// Picks the sweep cadence from the records the pass just read.
    ///
    /// Providers disagree about how quickly a dead process matters: one
    /// reports its own exit, another does not, so its records would sit
    /// there until something asked. The shortest interval among the
    /// providers that currently have records wins, because a sweep costs one
    /// pass and asking too rarely shows a badge for a session that has gone.
    /// A provider with no records has nothing a sweep could find, so it does
    /// not set the pace; with no records at all the timer stops, and the file
    /// event that announces the next record starts it again. Before this,
    /// the fastest provider's three seconds applied all day whether or not
    /// it had ever run.
    private func stepSweep(for input: AgentProjectionInput) {
        let present = Set(input.records.map(\.provider))
        sweepInterval = descriptors
            .filter { present.contains($0.key) }
            .map { Double($0.value.pidSweepIntervalMs) / 1000 }
            .min()
        if isWatching {
            rearmSweep()
        }
    }

    /// Re-arms the sweep at `sweepInterval`, or leaves it alone when it
    /// already runs at that rate.
    private func rearmSweep() {
        guard let seconds = sweepInterval else {
            sweep?.invalidate()
            sweep = nil
            return
        }
        if let sweep, sweep.isValid, sweep.timeInterval == seconds {
            return
        }
        sweep?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestPass() }
        }
        // Best effort, so let the system coalesce it with other work.
        timer.tolerance = seconds / 3
        RunLoop.main.add(timer, forMode: .common)
        sweep = timer
    }

    /// Decides what to restore and what to retire before the interface exists.
    ///
    /// Runs before the first pass, and before the session hints reach the tabs,
    /// because a run this drops must not be offered for resume by the pass that
    /// follows it.
    func prepareForLaunch() {
        runLifecycle("launch", WeirProjectionBridge.onLaunch)
    }

    /// Records what Weir is about to kill and what would bring it back.
    ///
    /// Synchronous by necessity: it runs inside `willTerminate`, and anything
    /// it defers would not reach disk.
    func prepareForTermination() {
        // The last tries at a hint the person ended while a hook held it, which
        // a few short waits outlast; one that stays is in the queue's file.
        for _ in 0..<10 where !forgottenHints.isEmpty {
            retryForgottenHints()
            if !forgottenHints.isEmpty {
                usleep(20000)
            }
        }
        // The list may be what an earlier write failed to keep, and none of
        // the tries above changed it: the next launch reads only the file.
        forgottenHintQueue.save()
        runLifecycle("terminate", WeirProjectionBridge.onTerminate)
    }

    /// Neither call needs the interface, and launch runs before there is one:
    /// what they read is the records, the hints, the intents, and which
    /// processes are alive. Everything a pass adds — which panes are open,
    /// what the user has looked at — is a question about a window that does
    /// not exist yet at launch and is beside the point at quit.
    private func runLifecycle(
        _ name: String,
        _ call: (Data, String) throws -> Data
    ) {
        guard writesFiles else { return }
        // A hint ended while a hook held it goes now if it can; one that
        // stays is kept from the launch rules by `lifecycleInput`.
        retryForgottenHints()
        do {
            let body = try call(
                JSONEncoder().encode(lifecycleInput()),
                AgentDateParsing.formatISO8601(Date())
            )
            let commands = try JSONDecoder().decode([AgentProjectionCommand].self, from: body)
            // File commands only: the rules raise no notification and touch no
            // pane here, so the executor is the whole of it.
            executor.run(commands)
        } catch {
            // The interface is unaffected either way: a launch that cannot
            // decide leaves every record where it is, and a quit that cannot
            // leaves the runs to be judged as orphans on the next launch.
            lastFailure = String(describing: error)
            log.error("\(name, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// A pane is gone. The rules decide what that means for the records it
    /// held, so this only asks them again.
    func didClosePane(_ paneID: UUID) {
        requestPass()
    }

    /// The person ended `sessionID` in `paneID` (`AppState.forgetStoppedConversation`).
    func forgetSession(_ sessionID: String, of kind: AgentKind, inPane paneID: UUID) {
        guard writesFiles else { return }
        forgottenHintQueue.add(AgentForgottenHint(provider: kind.rawValue, pane: paneID, sessionID: sessionID))
        retryForgottenHints()
        requestPass()
    }

    /// Deletes the hints still waiting (`forgottenHints`). One the hook
    /// held the lock of, or that could not be removed, stays for the next
    /// try; any other outcome settles it: deleted, gone already, or naming
    /// a newer session, which is the pane's own now.
    private func retryForgottenHints() {
        if !forgottenHints.isEmpty {
            forgottenHintQueue.removeAll {
                executor.forgetSessionHint(provider: $0.provider, pane: $0.pane, sessionID: $0.sessionID).isSettled
            }
        }
        // A write that failed goes again, though no hint settled since.
        forgottenHintQueue.save()
    }

    /// The hints read for a pass without the ones still waiting to be
    /// deleted, which the rules would take for the pane's session, and the
    /// launch rules would resume.
    private func withoutForgottenHints(_ files: [AgentProjectionFile]) -> [AgentProjectionFile] {
        AgentForgottenHint.removing(forgottenHints, from: files)
    }

    func stopWatching() {
        isWatching = false
        sources.forEach { $0.cancel() }
        sources.removeAll()
        sweep?.invalidate()
        sweep = nil
    }

    private func watchedDirectories() -> [URL] {
        directories.values.flatMap { directory -> [URL] in
            [directory.state, directory.sessions]
                + [directory.worktreeEvents, directory.cwdEvents, directory.turns].compactMap(\.self)
        }
    }

    private func watch(_ directory: URL, isTurns: Bool) -> (any DispatchSourceFileSystemObject)? {
        // Created here rather than waited for: on a fresh install nothing has
        // written a record yet, and a descriptor cannot be opened on a
        // directory that does not exist, so the first run of an agent would
        // otherwise go unwatched until the next launch.
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // We just tried to create it, so this is a directory we cannot
            // have: the volume is read-only, or the sandbox refused. Nothing
            // here can fix that, and the pass still reads what it can.
            log.error("cannot watch \(directory.path, privacy: .private): errno=\(errno)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            // The source delivers on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                // The directory itself was removed or moved: this descriptor
                // now follows an inode nothing writes to again, and the hook
                // makes a new directory. Open that one, which also lists the
                // turn records again.
                if !events.isDisjoint(with: [.delete, .rename]) {
                    self.startWatching()
                } else if isTurns {
                    self.noteTurnsChanged()
                }
                self.watcherPasses.request()
            }
        }
        // Captured by value so the close belongs to this source's lifetime
        // rather than the adapter's.
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        return source
    }

    /// A turn directory changed: the next requested pass lists the turn
    /// records again.
    func noteTurnsChanged() {
        haveTurnsChanged = true
    }

    /// The pass anything other than a test asks for: a file event, the
    /// sweep, a closed pane, tmux, or attention. It lists the turn records
    /// again only when their directory changed since the last listing.
    ///
    /// The slow part of the pass runs off the main actor: with ten thousand
    /// turns kept, listing their records and encoding and decoding what
    /// crosses the bridge take tens of milliseconds, which on the main actor
    /// dropped frames on every hook write. One requested pass runs at a
    /// time; one asked for meanwhile runs once after it, reading whatever
    /// changed by then.
    func requestPass() {
        guard passInFlight == nil else {
            isPassOwed = true
            return
        }
        guard let work = preparePass(shouldRereadTurns: haveTurnsChanged) else { return }
        // This pass reads everything that changed until now.
        isPassOwed = false
        let generation = passGeneration
        let engine = engine
        passInFlight = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                AgentProjectionPass.run(work, engine: engine)
            }.value
            guard let self else { return }
            passInFlight = nil
            // A pass run in place (`refresh()`) since this one started read
            // newer files, and this answer was made from older ones. The
            // rules do not always refuse its commit: when this pass reached
            // them after the in-place pass had committed, its answer was
            // built on that newer state. So the generation, not the commit, is what drops it, without
            // reporting a failure. When the pass in place failed, nothing
            // newer was applied, so one more pass catches up at once.
            if generation == passGeneration {
                finishPass(outcome, of: work)
            } else if lastFailure != nil {
                isPassOwed = true
            }
            if isPassOwed {
                requestPass()
            }
        }
    }

    /// Waits until no requested pass is running or owed. For tests, which
    /// otherwise cannot tell when a requested pass has been applied.
    func passesSettled() async {
        while let pass = passInFlight {
            await pass.value
        }
    }

    /// Runs one pass in place: read every directory, ask the rules, apply
    /// the answer. For the first pass, which the interface waits for, and
    /// for tests.
    func refresh() {
        guard let work = preparePass(shouldRereadTurns: true) else { return }
        // Newer than any answer still on its way from a requested pass.
        passGeneration += 1
        finishPass(AgentProjectionPass.run(work, engine: engine), of: work)
    }

    // MARK: - Reading

    /// What the launch and quit rules read: the files, the intents, and which
    /// processes answer. No interface, because at launch there is none.
    private func lifecycleInput() -> AgentProjectionInput {
        var input = AgentProjectionInput()
        input.providers = descriptors
        for (provider, directory) in directories {
            input.records += runRecords(in: directory, provider: provider)
            input.sessionRecords += withoutForgottenHints(paneFiles(in: directory, .sessions, provider: provider))
        }
        input.resumeIntents = intents()
        input.pidStatus = pidStatus(for: input.records)
        return input
    }

    /// Each provider's turn directory, with what its records' names end with.
    private func turnDirectories() -> [TurnRecordCache.Source] {
        guard let suffix = AgentProviderRegistry.recordLayout?.turnRecordSuffix else { return [] }
        return directories.sorted { $0.key < $1.key }.compactMap { provider, directory in
            directory.turns.map { TurnRecordCache.Source(provider: provider, directory: $0, suffix: suffix) }
        }
    }

    private func intents() -> [AgentProjectionIntent] {
        resumeIntents.allIntents().map {
            AgentProjectionIntent(
                runID: $0.runID,
                paneID: $0.paneID,
                sessionID: $0.sessionID,
                ownerRunID: $0.ownerRunID,
                pid: $0.pid,
                createdAt: AgentDateParsing.formatISO8601($0.createdAt)
            )
        }
    }

    private func buildInput(session: WorkspaceSession, protection: TurnProtection?) -> AgentProjectionInput {
        var input = AgentProjectionInput()
        input.providers = descriptors
        input.home = NSHomeDirectory()
        input.resolvedHomes = AgentProjectionInput.resolvedHomes(of: descriptors.keys, under: NSHomeDirectory())
        input.isBootstrap = !hasBootstrapped
        input.acknowledged = pending

        for (provider, directory) in directories {
            input.records += runRecords(in: directory, provider: provider)
            input.sessionRecords += withoutForgottenHints(paneFiles(in: directory, .sessions, provider: provider))
            input.cwdEvents += paneFiles(in: directory, .cwdEvents, provider: provider)
            input.worktreeEvents += AgentProjectionWorktreeFile.events(in: directory, provider: provider)
        }
        input.resumeIntents = intents()

        input.tabs = session.tabs.map {
            AgentProjectionTabPanes(id: $0.id, panes: Array($0.splitTree.allLeafIDs()))
        }
        input.pidStatus = pidStatus(for: input.records)
        input.marks = marks()
        input.presence = presence(for: input.records)
        input.focus = focus(in: session)
        input.seenPanes = seenPanes().sorted { $0.uuidString < $1.uuidString }
        input.programStatus = programStatus()
        input.turnSweep = protection.map { AgentProjectionTurnSweep(limits: turnRetention, protection: $0) }
        return input
    }

    /// The provider's run records, found by the name the writer gives them.
    /// Without that name there is no file we can call a record, so the pass
    /// sees none rather than reading files by a guess.
    private func runRecords(in directory: AgentDirectories, provider: String) -> [AgentProjectionFile] {
        guard let suffix = directory.runRecordSuffix else { return [] }
        return AgentProjectionFile.files(in: directory.state, suffix: suffix, provider: provider)
    }

    /// The provider's resume hints or cwd events, found the same way as its
    /// run records and read as nothing for the same reason.
    private func paneFiles(
        in directory: AgentDirectories,
        _ kind: AgentPaneStoreKind,
        provider: String
    ) -> [AgentProjectionFile] {
        guard let store = directory.paneStore(kind) else { return [] }
        return AgentProjectionFile.files(in: store.directory, suffix: store.suffix, provider: provider)
    }

    /// Liveness for every process a record names. Asking is a system call, so
    /// it happens here and the answer travels as a fact.
    private func pidStatus(for records: [AgentProjectionFile]) -> [String: String] {
        var status: [String: String] = [:]
        for record in records {
            guard let pid = record.recordFacts?.pid, status[pid] == nil else { continue }
            status[pid] = switch processStatus(pid) {
            case .alive: "alive"
            case .dead: "dead"
            case .unknown: "unknown"
            }
        }
        return status
    }

    private func marks() -> AgentProjectionMarks {
        guard let attention else { return AgentProjectionMarks() }
        return AgentProjectionMarks(viewed: attention.viewedRuntimeTokens)
    }

    /// Which panes each tmux-hosted run reaches.
    ///
    /// Resolved per endpoint rather than by listing every pane tmux knows,
    /// because the topology probe answers that question and only that
    /// question. An endpoint with no answer is left out of the map entirely,
    /// which is how the rules tell "nobody is attached" from "not known yet".
    private func presence(for records: [AgentProjectionFile]) -> AgentProjectionPresence {
        var presence = AgentProjectionPresence()
        // Collected even when no probe is running, because the probe asks for
        // its candidates before it starts and would otherwise have nowhere to
        // look for a session this process did not spawn.
        let endpoints = records.compactMap(\.tmuxEndpoint)
        socketPaths = Set(endpoints.map(\.socketPath))
        tmuxLocationsByEndpoint = [:]
        guard let tmuxPresence else { return presence }
        for endpoint in endpoints {
            let key = AgentProjectionPresence.key(for: endpoint)
            guard presence.attachments[key] == nil else { continue }
            let attachments = tmuxPresence.attachments(for: endpoint)
            guard !attachments.isEmpty || tmuxPresence.resolution(for: endpoint) == .detached else {
                continue
            }
            presence.attachments[key] = Array(attachments.keys)
            presence.locations[key] = Dictionary(uniqueKeysWithValues: attachments.map { pane, location in
                (pane.uuidString, AgentProjectionPaneLocation(isActive: location.isActive))
            })
            tmuxLocationsByEndpoint[key] = attachments
        }
        return presence
    }

    /// The pane with the keyboard: the focused pane of the window the
    /// person was last in while it is shown, else the primary's.
    private func focus(in session: WorkspaceSession) -> AgentProjectionFocus? {
        let front = session.lastFrontWindowID
        let window = session.hiddenWindowIDs.contains(front) ? session.primaryWindowID : front
        guard let tab = session.activeTab(in: window),
              session.windows(showing: tab.id).contains(window),
              let pane = tab.splitTree.focusedLeafID
        else { return nil }
        return AgentProjectionFocus(tab: tab.id, pane: pane)
    }

    // MARK: - Applying

    /// `keepsMarks` leaves the viewed marks as they are: the person changed
    /// them after the pass read them, so the rules' trimmed set would drop
    /// that change.
    private func apply(_ projection: AgentProjection, to session: WorkspaceSession, keepsMarks: Bool = false) {
        for (provider, descriptor) in descriptors {
            guard let kind = AgentKind(rawValue: descriptor.id) else { continue }
            attention?.replaceRuntimes(
                projection.runtimes
                    .filter { $0.provider == provider }
                    .map(runtimePresentation),
                kind: kind
            )
        }
        // The rules trimmed the marks to the runs that still exist; what they
        // handed back is the whole of what the interface keeps.
        if !keepsMarks {
            attention?.replaceMarks(viewed: projection.marksToKeep.viewed)
        }

        let badgesByPane = projection.badgesByPane
        let sessionsByPane = projection.sessionsByPane
        let titlesByTab = projection.titlesByTab
        let candidatesByPane = projection.resumeCandidatesByPane
        session.applyAcrossTabs { tab in
            // Before the badges are replaced: a tab restored without a name
            // is named by the ones it was saved with.
            tab.rememberSavedConversationName()
            let leaves = tab.splitTree.allLeafIDs()
            // Every provider the interface can key by, not only the ones the
            // registry answered for. A provider with no descriptor this run —
            // the registry could not be read, or a test supplied one — still
            // has to have its map cleared, or a badge restored from the last
            // session would sit there claiming a run that is not there.
            for kind in AgentKind.allCases {
                let id = kind.rawValue
                var badges: [UUID: AgentBadge] = [:]
                var sessions: [UUID: AgentSessionInfo] = [:]
                for leaf in leaves {
                    if let badge = badgesByPane[leaf]?[id] {
                        badges[leaf] = badge.asAgentBadge
                    }
                    if let info = sessionsByPane[leaf]?[id] {
                        sessions[leaf] = AgentSessionInfo(sessionId: info.sessionID, cwd: info.cwd)
                    }
                }
                if tab.agentBadges[kind] ?? [:] != badges {
                    tab.agentBadges[kind] = badges
                }
                if tab.agentSessions[kind] ?? [:] != sessions {
                    tab.agentSessions[kind] = sessions
                }
            }
            var candidates: [UUID: Set<AgentKind>] = [:]
            for leaf in leaves {
                let kinds = Set((candidatesByPane[leaf] ?? []).compactMap(AgentKind.init(rawValue:)))
                if !kinds.isEmpty {
                    candidates[leaf] = kinds
                }
            }
            if tab.agentResumeCandidates != candidates {
                tab.agentResumeCandidates = candidates
            }
            if let title = titlesByTab[tab.id], tab.title != title {
                tab.title = title
            }
            // Read from the badges just applied, by the rule the tab's title
            // is chosen by, so the row's name and the pane header's agree
            // while the agent runs.
            tab.rememberConversationName()
        }
        onProjectionApplied?(session)
    }

    private func runtimePresentation(_ runtime: AgentProjectedRuntime) -> AgentRuntimePresentation {
        AgentRuntimePresentation(projected: runtime, tmuxLocationsByEndpoint: tmuxLocationsByEndpoint)
    }

    /// Runs the file commands and applies the rest here, where the interface
    /// is. The split is the executor's contract: it owns the lock, this owns
    /// everything that is not a file.
    /// `sweptWith` is what protected turns when the rules chose the ones
    /// to delete.
    private func perform(
        _ commands: [AgentProjectionCommand],
        session: WorkspaceSession,
        sweptWith: TurnProtection?
    ) -> [AgentCommandOutcome] {
        var outcomes = executor.run(commands)
        // One batch per turns directory.
        var turnsToDelete: [URL: [String]] = [:]
        turnDeletions.forgetPastWaits(now: turnDeletionClock())
        for command in commands {
            switch command.op {
            case let .markViewed(runtimeID, token):
                attention?.viewedRuntimeTokens[runtimeID] = token
            case let .cwdChanged(pane, newCwd, oldCwd):
                onCwdChanged?(pane, newCwd, oldCwd)
            case let .gitSyncRefetch(repoRoot):
                onGitSyncRequested?(repoRoot)
            case let .deleteTurn(turnID):
                // The op and the target name the turn alike, or neither is
                // trusted.
                if case let .turn(provider, target) = command.target, target == turnID,
                   let directory = directories[provider]?.turns, turnDeletions.mayAsk(turnID)
                {
                    turnsToDelete[directory, default: []].append(turnID)
                }
            case let .notify(payload):
                if deliver(payload, session: session) {
                    outcomes.append(.notified(
                        runtimeID: payload.runtimeID,
                        eventToken: payload.eventToken,
                        state: payload.state
                    ))
                }
            default:
                continue
            }
        }
        // We hand the turns over on every pass, so a turn no pass asks about
        // any more is forgotten. The badge already shows the turn stopped;
        // the write makes the record say so, and the turn where its commit
        // lands, which the next pass reads at once.
        stoppedTurns.close(StoppedTurnRequest.asked(by: commands, in: directories)) { [weak self] in
            self?.noteTurnsChanged()
            self?.requestPass()
        }
        // Reported by what the next pass reads: a deleted turn's record is
        // gone from the directory, and one that stayed is chosen again.
        // The rules ask for deletions only with a sweep, which carries what
        // protected turns.
        if let sweptWith {
            for (directory, turnIDs) in turnsToDelete {
                turnDeletions.ask(turnIDs, in: directory, sweptWith: sweptWith, turn: turnHistory.turn)
            }
        }
        return outcomes
    }

    /// Sends the next batch waiting, checked against what protects turns
    /// now (`TurnDeletionQueue.nextBatch`), and the one after it once it
    /// has finished. The collector calls back for every batch, and no batch
    /// is empty, so the batch it holds never keeps the others waiting.
    private func sendNextTurnBatch() {
        guard turnDeletions.hasBatchToSend else { return }
        let next = turnDeletions.nextBatch(protection: turnProtection())
        if next.needsSweep {
            requestPass()
        }
        guard let batch = next.batch else { return }
        turnCollector.enqueue(batch.turnIDs, in: batch.directory) { [weak self] deletions in
            guard let self else { return }
            let report = turnDeletions.finished(asked: batch.turnIDs, deletions, now: turnDeletionClock())
            // The batch took records out of the directory; the next pass
            // lists it rather than wait for the watcher's event.
            noteTurnsChanged()
            announce(report)
            sendNextTurnBatch()
        }
    }

    /// Hands the host what a batch took.
    private func announce(_ report: TurnDeletionQueue.Report) {
        if !report.gone.isEmpty {
            onTurnsDeleted?(report.gone, report.remaining)
        }
        guard !report.deletedIn.isEmpty else { return }
        Task { [weak self, onTurnsDeletedIn] in
            guard await onTurnsDeletedIn?(report.deletedIn) ?? true else { return }
            self?.turnDeletions.spansSaved(report.spanTurnIDs)
        }
    }

    /// What one pass may hand the rules (`MAX_PROJECTION_INPUT_BYTES` in
    /// the bridge). Past it every pass fails. The content is split by
    /// `TurnRecordCache.contentBudgetBytes`; what grows without it is every turn
    /// record's name, about seventy bytes each. The two sides check the
    /// value against `rust/fixtures/contract/shared-values.json`.
    static let inputLimitBytes = 16 * 1024 * 1024

    /// Logs past three quarters of the limit, once a run, so it is seen
    /// before the passes start failing.
    private func noteSize(input: Int) {
        guard input > Self.inputLimitBytes / 4 * 3, !hasWarnedOfInputSize else { return }
        hasWarnedOfInputSize = true
        log.error("projection input \(input, privacy: .public) bytes, near the limit")
    }

    private var hasWarnedOfInputSize = false

    /// The turn deletions on their way or waiting.
    private(set) var turnDeletions: TurnDeletionQueue
    /// The clock the waits are measured by; injected by tests.
    var turnDeletionClock: () -> Date = Date.init
    /// The turn record content one pass sends at most
    /// (`TurnRecordCache.contentBudgetBytes`); a test sets a small one to see the
    /// records arrive over several passes.
    var turnContentBudgetBytes = TurnRecordCache.contentBudgetBytes
    /// The limits turn records are kept within; set by the host.
    var turnRetention = TurnRetentionLimits.standard
    /// The turns the host protects from the retention sweep, or `nil` while
    /// it has not read what protects them; set by the host. The default
    /// protects everything by never letting the sweep run.
    var turnProtection: @MainActor () -> TurnProtection? = { nil }
    /// Set by the host to forget what it kept about turns that are gone (their
    /// read marks, a conversation's viewed line), each with its conversation
    /// as the history had it when the deletion was asked for, or as the file
    /// kept it for one an earlier run left cut short (none when neither knew
    /// it), and the conversations that still have
    /// turns not deleted or still being deleted (`TurnProtection.conversationsEmptied`).
    var onTurnsDeleted: (@MainActor ([TurnID: ConversationKey?], Set<ConversationKey>) -> Void)?
    /// Set by the host to keep, by worktree, when the turns deleted there
    /// ran (`TurnDeletionQueue.Span`). It returns true once they are saved
    /// (`TurnDeletionQueue.spansSaved`).
    var onTurnsDeletedIn: (@MainActor ([String: [DateInterval]]) async -> Bool)?

    /// Set by the host to receive the cwd changes and git refetch requests
    /// that leave this subsystem.
    var onCwdChanged: ((UUID, String, String?) -> Void)?
    var onGitSyncRequested: ((String) -> Void)?
    /// Set by the host to take in at once the one pass that shows a run whose
    /// process died at work, before its commands retire the record.
    var onRunsExited: (@MainActor () -> Void)?
    /// Set by the host to actually raise a notification. Returns whether it
    /// was delivered, which is what retires the pending entry.
    var onNotify: ((AgentNotifyPayload, Tab) -> Bool)?
    /// The panes the person can see now: empty while the application is in
    /// the background. Set by the host, which knows the windows; the default
    /// sees nothing, so nothing is read by accident.
    var seenPanes: @MainActor () -> Set<UUID> = { [] }
    /// What each pane's program last reported about itself over OSC 7501
    /// (`PaneProgramStatusStore`). Set by the host, which receives the
    /// terminal's reports; the default has none.
    var programStatus: @MainActor () -> [String: AgentProjectionProgramStatus] = { [:] }
    /// Set by the host to react once the panes reflect a new projection.
    /// Approval presentation uses it to release requests the terminal
    /// already answered.
    var onProjectionApplied: (@MainActor (WorkspaceSession) -> Void)?

    private func deliver(_ payload: AgentNotifyPayload, session: WorkspaceSession) -> Bool {
        guard let onNotify, let tab = session.tabs.first(where: { $0.id == payload.tab }) else {
            return false
        }
        return onNotify(payload, tab)
    }

}

// MARK: - One pass

extension AgentProjectionAdapter {
    private func preparePass(shouldRereadTurns: Bool) -> AgentProjectionPass.Work? {
        guard let session, writesFiles else { return nil }
        // A pass asked to go by the last list reads the turn records anyway
        // when that list cannot be trusted (`TurnRecordCache.unchanged`).
        let unchanged = shouldRereadTurns ? nil : turnRecords.unchanged()
        if unchanged == nil {
            haveTurnsChanged = false
        }
        // Every pass reads whatever changed since the last listing, so it
        // leaves nothing for the trailing pass the watcher was owed: an event
        // in a turn directory marks them before it asks for a pass.
        watcherPasses.didRun()
        let protection = turnProtection()
        retryForgottenHints()
        let input = buildInput(session: session, protection: protection)
        stepSweep(for: input)
        return AgentProjectionPass.Work(
            sweptWith: protection,
            input: input,
            now: AnyEncodableInstant.now(),
            unchanged: unchanged,
            turnSources: turnDirectories(),
            sent: turnRecords.snapshot(),
            contentBudgetBytes: turnContentBudgetBytes
        )
    }

    /// `work` is what the pass read on the main actor: the viewed marks it
    /// sent (see `apply(_:to:keepsMarks:)`), and what protected turns from
    /// its sweep.
    private func finishPass(_ outcome: AgentProjectionPass.Outcome, of work: AgentProjectionPass.Work) {
        // The window went while the pass ran: nothing to apply it to, so
        // nothing is committed either.
        guard let session else { return }
        if let bytes = outcome.inputBytes {
            noteSize(input: bytes)
        }
        let answer: AgentProjectionPass.Answer
        do {
            answer = try outcome.answer.get()
            try engine.commit(answer.proposal)
        } catch {
            // A pass that cannot run leaves the interface and the rules'
            // memory as they were. The next pass tries again, reading the
            // turn records again, since what this one read never arrived.
            turnRecords.forgetLastList()
            lastFailure = String(describing: error)
            log.error("projection failed: \(String(describing: error), privacy: .private)")
            return
        }
        lastFailure = nil
        // Only now do the rules hold what this pass sent; a pass that failed
        // above must send the same content again.
        turnRecords.commit(answer.turns)
        hasBootstrapped = true
        let response = answer.response
        if let conversations = response.projection.conversations {
            turnHistory.replace(with: conversations.elements)
        }
        turnDeletions.isHistoryComplete = answer.turns.isComplete

        // A mark the person set while the pass ran is not in what the rules
        // trimmed; keeping theirs leaves it to the pass that change asked for.
        apply(response.projection, to: session, keepsMarks: marks() != work.input.marks)
        // A finished turn's notice held in case a queued instruction follows.
        watcherPasses.request(in: response.projection.nextPassInMs.map { .milliseconds($0) })
        // Before the commands retire it (`onRunsExited`).
        if response.projection.runtimes.contains(where: { $0.badge.stopReason == AgentBadge.processExitedReason }) {
            onRunsExited?()
        }
        pending = perform(response.commands, session: session, sweptWith: work.sweptWith)
        // Only now: sending may ask for a pass at once, which hands the rules
        // what this one's commands came to (`pending`).
        sendNextTurnBatch()
        // The rest of the records, at once rather than at the next event.
        if !answer.turns.isComplete {
            noteTurnsChanged()
            requestPass()
        }
    }
}
