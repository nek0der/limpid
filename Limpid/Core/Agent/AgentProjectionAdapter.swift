// AgentProjectionAdapter.swift
// Limpid — one pass of the Rust projection, applied to the interface.

import Foundation
import OSLog

private let log = Logger.limpid("agent.projection.adapter")

/// Drives one projection pass and applies its answer.
///
/// Everything this does is either looking something up that only this process
/// can (which files are there, which processes are alive, where the user is
/// looking) or applying an answer. No rule lives here: which badge a pane
/// shows, which change is worth announcing, and which record is safe to retire
/// are all decided on the other side of the boundary.
///
/// Passes are triggered by the directories changing and by a timer that asks
/// whether the agent processes are still alive. Tests drive `refresh()`
/// directly instead, so a case does not depend on a file event arriving.
@MainActor
final class AgentProjectionAdapter {
    private let directories: [String: AgentDirectories]
    private let descriptors: [String: AgentProviderDescriptor]
    private let executor: AgentCommandExecutor
    private let processStatus: (String?) -> AgentProcessStatus
    /// Read here as well as written through the executor: an intent is the
    /// evidence that a run was killed at quit rather than lost, and the rules
    /// retire a run whose intent they were not told about.
    private let resumeIntents: AgentResumeIntentStore

    private weak var session: WindowSession?
    private weak var attention: AttentionState?
    private weak var tmuxPresence: TmuxPanePresence?

    /// Opaque to this process: what one pass produced, handed back to the
    /// next. Reading it here would make its shape a contract.
    private var carried: Data?
    /// What the previous pass's commands came to, reported once and then
    /// dropped so an outcome cannot be replayed.
    private var pending: [AgentCommandOutcome] = []
    private var hasBootstrapped = false

    /// `nonisolated(unsafe)` so `deinit`, which is nonisolated under Swift 6,
    /// can cancel the sources and invalidate the timer. Each source owns the
    /// descriptor it was opened with; see `watch(_:)`.
    private nonisolated(unsafe) var sources: [any DispatchSourceFileSystemObject] = []
    private nonisolated(unsafe) var sweep: Timer?
    /// Why the last pass could not run, if it could not. Kept because a pass
    /// that fails changes nothing visible, so without this the only evidence
    /// is a log line nobody is watching.
    private(set) var lastFailure: String?

    /// Every tmux socket a record has named. The topology probe needs somewhere
    /// to look, and the records are the only place a socket this process never
    /// spawned is written down.
    private(set) var socketPaths: Set<String> = []
    /// Where each tmux-hosted pane sits, as of the last pass. Kept on the
    /// runtimes so attention can tell a visible tmux pane from one behind it.
    private var paneLocations: [UUID: TmuxPaneLocation] = [:]
    /// Where each run in tmux lives, by the runtime identifier the rules key
    /// it with, as of the last pass. Read by the entries that open a run's
    /// tab again; built here because the endpoint is in the record and the
    /// runtimes the rules return name no record.
    private var tmuxRuns: [String: AgentTmuxRun] = [:]
    /// The leaves with a conversation to resume once tmux stops showing
    /// them, as of the last pass. The rules decide it from the records and
    /// hints; this is where the tmux side reads their answer
    /// (`TmuxConnectionStore.outcome(ofEnded:)`).
    private(set) var resumableTmuxPanes: Set<UUID> = []

    /// The one the application builds: every provider the registry declares,
    /// rooted at this build's own support directory. Tests inject their
    /// directories through the designated initializer instead.
    convenience init() {
        let root = LimpidPaths.applicationSupportDirectory()
        let directories = AgentProviderRegistry.directories(under: root)
        let resumeIntents = AgentResumeIntentStore(
            directory: root.appendingPathComponent("resume-intents", isDirectory: true)
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
            resumeIntents: resumeIntents
        )
    }

    init(
        directories: [String: AgentDirectories],
        descriptors: [String: AgentProviderDescriptor],
        resumeIntents: AgentResumeIntentStore,
        processStatus: @escaping (String?) -> AgentProcessStatus = AgentProcessStatus.inspect
    ) {
        self.directories = directories
        self.descriptors = descriptors
        self.processStatus = processStatus
        self.resumeIntents = resumeIntents
        executor = AgentCommandExecutor(directories: directories, resumeIntents: resumeIntents)
    }

    deinit {
        // The descriptors belong to the sources, not to this object: each
        // cancel handler closes the one it captured. Touching them here too
        // would race that handler and close one twice.
        sources.forEach { $0.cancel() }
        sweep?.invalidate()
    }

    func bootstrap(
        into session: WindowSession,
        attention: AttentionState? = nil,
        tmuxPresence: TmuxPanePresence? = nil
    ) {
        self.session = session
        self.attention = attention
        self.tmuxPresence = tmuxPresence
        if DemoFixture.isDemoActive {
            if let attention {
                Self.seedRuntimes(fromBadgesIn: session, into: attention)
            }
            return
        }
        refresh()
    }

    /// Demo mode never runs a pass, so the runtimes the Waiting list and the
    /// row badges read would stay empty and the fixture's staged turns would
    /// show nowhere. The fixture stages badges, and those are enough to stand
    /// in for runtimes: one per badge, keyed by its pane so the identity is
    /// stable across launches, which is what `make screenshot` depends on.
    static func seedRuntimes(fromBadgesIn session: WindowSession, into attention: AttentionState) {
        for kind in AgentKind.allCases {
            var runtimes: [AgentRuntimePresentation] = []
            for tab in session.tabs {
                for (pane, badge) in tab.agentBadges[kind] ?? [:] {
                    runtimes.append(AgentRuntimePresentation(
                        kind: kind,
                        runID: pane.uuidString,
                        revision: nil,
                        badge: badge,
                        paneIDs: [pane],
                        tmuxLocations: [:],
                        stateEpisodeToken: "\(pane.uuidString):\(badge.updatedAt.timeIntervalSince1970)",
                        attachmentResolution: .attached
                    ))
                }
            }
            attention.replaceRuntimes(runtimes, kind: kind)
        }
    }

    /// Starts watching the directories the hooks write into and asking, on a
    /// timer, whether the processes those records name are still running.
    ///
    /// A pass re-reads everything rather than following individual events. One
    /// hook write fires several of them, the directories hold fewer records
    /// than a machine has panes, and a rule that depended on seeing every
    /// event in order would be wrong the first time one was missed.
    func startWatching() {
        stopWatching()
        for directory in watchedDirectories() {
            guard let source = watch(directory) else { continue }
            sources.append(source)
        }

        // Providers disagree about how quickly a dead process matters: one
        // reports its own exit, another does not, so its records would sit
        // there until something asked. The shortest declared interval wins,
        // because a sweep costs one pass and asking too rarely shows a badge
        // for a session that has gone.
        let seconds = descriptors.values
            .map { Double($0.pidSweepIntervalMs) / 1000 }
            .min() ?? 30
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
        runLifecycle("launch", LimpidProjectionBridge.onLaunch)
    }

    /// Records what Limpid is about to kill and what would bring it back.
    ///
    /// Synchronous by necessity: it runs inside `willTerminate`, and anything
    /// it defers would not reach disk.
    func prepareForTermination() {
        runLifecycle("terminate", LimpidProjectionBridge.onTerminate)
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
        guard !DemoFixture.isDemoActive else { return }
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
            log.error("\(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A pane is gone. The rules decide what that means for the records it
    /// held, so this only asks them again.
    func didClosePane(_ paneID: UUID) {
        refresh()
    }

    func stopWatching() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        sweep?.invalidate()
        sweep = nil
    }

    private func watchedDirectories() -> [URL] {
        directories.values.flatMap { directory -> [URL] in
            [
                directory.state,
                directory.sessions,
                directory.hostedSessions,
                directory.state.appendingPathComponent("worktree-events", isDirectory: true)
            ] + (directory.cwdEvents.map { [$0] } ?? [])
        }
    }

    private func watch(_ directory: URL) -> (any DispatchSourceFileSystemObject)? {
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
            log.error("cannot watch \(directory.path, privacy: .public): errno=\(errno)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // Captured by value so the close belongs to this source's lifetime
        // rather than the adapter's.
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        return source
    }

    /// Runs one pass: read the directories, ask the rules, apply the answer.
    func refresh() {
        guard let session, !DemoFixture.isDemoActive else { return }
        let input = buildInput(session: session)
        let response: AgentProjectionResponse
        let body: Data
        do {
            body = try LimpidProjectionBridge.project(
                state: carried,
                input: JSONEncoder().encode(input),
                now: JSONEncoder().encode(instants())
            )
            response = try JSONDecoder().decode(AgentProjectionResponse.self, from: body)
        } catch {
            // A pass that cannot run leaves the interface as it is. The next
            // file change tries again with the same carried state.
            lastFailure = String(describing: error)
            log.error("projection failed: \(String(describing: error), privacy: .public)")
            return
        }
        lastFailure = nil
        carried = carriedState(from: body)
        hasBootstrapped = true

        apply(response.projection, to: session)
        pending = perform(response.commands, session: session)
    }

    // MARK: - Reading

    /// What the launch and quit rules read: the files, the intents, and which
    /// processes answer. No interface, because at launch there is none.
    private func lifecycleInput() -> AgentProjectionInput {
        var input = AgentProjectionInput()
        input.providers = descriptors
        for (provider, directory) in directories {
            input.records += files(in: directory.state, suffix: ".state.json", provider: provider)
            input.sessionRecords += files(in: directory.sessions, suffix: ".json", provider: provider)
            // After the plain hints, so a pane that has both — a conversation
            // that ran natively before it was reopened in tmux — is read from
            // the hosted one, which is the later truth.
            input.sessionRecords += files(in: directory.hostedSessions, suffix: ".json", provider: provider, isTmuxHosted: true)
        }
        input.resumeIntents = intents()
        input.pidStatus = pidStatus(for: input.records)
        return input
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

    private func buildInput(session: WindowSession) -> AgentProjectionInput {
        var input = AgentProjectionInput()
        input.providers = descriptors
        input.isBootstrap = !hasBootstrapped
        input.acknowledged = pending

        for (provider, directory) in directories {
            input.records += files(in: directory.state, suffix: ".state.json", provider: provider)
            input.sessionRecords += files(in: directory.sessions, suffix: ".json", provider: provider)
            // After the plain hints, so a pane that has both — a conversation
            // that ran natively before it was reopened in tmux — is read from
            // the hosted one, which is the later truth.
            input.sessionRecords += files(in: directory.hostedSessions, suffix: ".json", provider: provider, isTmuxHosted: true)
            if let cwd = directory.cwdEvents {
                input.cwdEvents += files(in: cwd, suffix: ".cwd.json", provider: provider)
            }
            input.worktreeEvents += worktreeFiles(in: directory.state, provider: provider)
        }
        input.resumeIntents = intents()

        input.tabs = session.tabs.map {
            AgentProjectionTabPanes(id: $0.id, panes: Array($0.splitTree.allLeafIDs()))
        }
        input.pidStatus = pidStatus(for: input.records)
        input.marks = marks()
        input.presence = presence(for: input.records, in: session)
        input.focus = focus(in: session)
        return input
    }

    private func files(
        in directory: URL,
        suffix: String,
        provider: String,
        isTmuxHosted: Bool = false
    ) -> [AgentProjectionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(suffix), !name.hasPrefix(".") else { return nil }
            let url = directory.appendingPathComponent(name)
            return AgentProjectionFile(
                provider: provider,
                name: String(name.dropLast(suffix.count)),
                // A read that fails here is reported as present-but-unread so
                // the rules keep the record they already accepted.
                content: (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) },
                isTmuxHosted: isTmuxHosted
            )
        }
    }

    private func worktreeFiles(in state: URL, provider: String) -> [AgentProjectionWorktreeFile] {
        let directory = state.appendingPathComponent("worktree-events", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            // The writer renames a dot-prefixed temporary into place, so a
            // name that is not a finished `.json` event is a write in
            // progress and must not be read as an event.
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let content = String(data: data, encoding: .utf8)
            else { return nil }
            return AgentProjectionWorktreeFile(
                provider: provider,
                fileName: name,
                content: content
            )
        }
    }

    /// Liveness for every process a record names. Asking is a system call, so
    /// it happens here and the answer travels as a fact.
    private func pidStatus(for records: [AgentProjectionFile]) -> [String: String] {
        var status: [String: String] = [:]
        for record in records {
            guard let content = record.content,
                  let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  let pid = object["pid"] as? String, status[pid] == nil
            else { continue }
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
        return AgentProjectionMarks(
            viewed: attention.viewedRuntimeTokens,
            dismissed: attention.dismissedRuntimeTokens
        )
    }

    /// Which panes each tmux-hosted run reaches.
    ///
    /// Resolved per endpoint rather than by listing every pane tmux knows,
    /// because the topology probe answers that question and only that
    /// question. An endpoint with no answer is left out of the map entirely,
    /// which is how the rules tell "nobody is attached" from "not known yet".
    ///
    /// Two kinds of pane can show an endpoint: a mirror leaf bound to that
    /// tmux pane, and a pane whose own tty drives a tmux client attached to
    /// the session. Both are listed, since both put the run in front of the
    /// user. Only the second kind gets a location: a mirror shows every pane
    /// of its window at once, so "not the active pane" does not mean out of
    /// sight there, and there is no client of ours to `select-pane` for.
    ///
    /// The key stays the record's own spelling of the socket, because that
    /// is what the rules build from the record; the canonical form is only
    /// for matching the mirror leaves.
    private func presence(
        for records: [AgentProjectionFile],
        in session: WindowSession
    ) -> AgentProjectionPresence {
        var presence = AgentProjectionPresence()
        // Collected even when no probe is running, because the probe asks for
        // its candidates before it starts and would otherwise have nowhere to
        // look for a session this process did not spawn.
        socketPaths = Set(records.compactMap { endpoint(in: $0)?.socketPath })
        paneLocations = [:]
        tmuxRuns = [:]
        let aliases = tmuxPresence?.topology.socketAliases ?? [:]
        var mirrored: [TmuxRuntimeEndpoint: [UUID]] = [:]
        for tab in session.tabs {
            for (endpoint, leaf) in tab.mirroredEndpoints(aliases: aliases) {
                mirrored[endpoint, default: []].append(leaf)
            }
        }
        for record in records {
            guard let endpoint = endpoint(in: record) else { continue }
            if let identity = runIdentity(in: record), let kind = AgentKind(rawValue: record.provider) {
                tmuxRuns[identity.runtimeID] = AgentTmuxRun(
                    kind: kind,
                    endpoint: endpoint,
                    leafID: identity.leafID
                )
            }
            let key = AgentProjectionPresence.key(for: endpoint)
            // Reported whether or not anything shows the endpoint: it is what
            // says the run is over, and a run nothing shows is exactly the
            // one the rules would otherwise keep holding.
            if tmuxPresence?.isGone(endpoint) == true {
                presence.goneEndpoints.insert(key)
            }
            guard presence.attachments[key] == nil else { continue }
            let leaves = mirrored[endpoint.canonical(aliases: aliases)] ?? []
            let attachments = tmuxPresence?.attachments(for: endpoint) ?? [:]
            guard !leaves.isEmpty || !attachments.isEmpty
                || tmuxPresence?.resolution(for: endpoint) == .detached
            else { continue }
            presence.attachments[key] = leaves + attachments.keys.filter { !leaves.contains($0) }
            for (pane, location) in attachments {
                presence.locations[pane.uuidString] = .init(isActive: location.isActive)
                paneLocations[pane] = location
            }
        }
        return presence
    }

    /// The runtime this record belongs to, and the leaf it names.
    ///
    /// The identifier is built the way the rules build it — provider, then run
    /// id, falling back to the pane id for a record from before run ids — so
    /// what is learned here meets a runtime they returned. `AgentTmuxRun` is
    /// the only thing keyed by it, and a spelling that drifted would leave a
    /// run without one rather than attaching it to the wrong runtime.
    private func runIdentity(in record: AgentProjectionFile) -> (runtimeID: String, leafID: UUID)? {
        guard let object = object(in: record),
              let paneID = object["paneId"] as? String,
              let leafID = UUID(uuidString: paneID)
        else { return nil }
        let runID = (object["runId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? paneID
        return ("\(record.provider):\(runID)", leafID)
    }

    private func object(in record: AgentProjectionFile) -> [String: Any]? {
        guard let content = record.content else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    }

    private func endpoint(in record: AgentProjectionFile) -> TmuxRuntimeEndpoint? {
        guard let object = object(in: record),
              let socketPath = object["tmuxSocketPath"] as? String, !socketPath.isEmpty,
              let paneID = object["tmuxPaneId"] as? String, !paneID.isEmpty
        else { return nil }
        return TmuxRuntimeEndpoint(
            socketPath: socketPath,
            serverPID: object["tmuxServerPID"] as? String ?? "",
            serverStartedAt: object["tmuxServerStartedAt"] as? String ?? "",
            paneID: paneID
        )
    }

    private func focus(in session: WindowSession) -> AgentProjectionFocus? {
        guard let tab = session.activeTab, let pane = tab.splitTree.focusedLeafID else { return nil }
        return AgentProjectionFocus(
            tab: tab.id,
            pane: pane,
            // The key window's own first responder is what the notification
            // delegate asks about too, so a run that finishes behind another
            // application is not treated as seen.
            isActive: LimpidNotificationDelegate.isPaneFocused(paneIDString: pane.uuidString)
        )
    }

    private func instants() -> [String: AnyEncodableInstant] {
        [
            "wall": .text(AgentDateParsing.formatISO8601(Date())),
            // Uptime rather than the wall clock, so a clock adjustment cannot
            // expire or revive a notification that is waiting for a pane.
            "monotonicMs": .number(UInt64(ProcessInfo.processInfo.systemUptime * 1000))
        ]
    }

    /// Lifts the opaque state out of the body without decoding it, so its
    /// shape stays a private matter for the rules.
    private func carriedState(from body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let state = object["state"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: state)
    }

    // MARK: - Applying

    private func apply(_ projection: AgentProjection, to session: WindowSession) {
        for (provider, descriptor) in descriptors {
            guard let kind = AgentKind(rawValue: descriptor.id) else { continue }
            attention?.replaceRuntimes(
                projection.runtimes
                    .filter { $0.provider == provider }
                    .map(runtimePresentation),
                kind: kind
            )
        }
        resumableTmuxPanes = projection.resumableTmuxPanes ?? []
        // The rules trimmed the marks to the runs that still exist; what they
        // handed back is the whole of what the interface keeps.
        attention?.viewedRuntimeTokens = projection.marksToKeep.viewed
        attention?.dismissedRuntimeTokens = projection.marksToKeep.dismissed

        let badgesByPane = projection.badgesByPane
        let sessionsByPane = projection.sessionsByPane
        let titlesByTab = projection.titlesByTab
        let candidatesByPane = projection.resumeCandidatesByPane
        session.applyAcrossTabs { tab in
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
            if let title = titlesByTab[tab.id], tab.capabilities.titleFollowsPaneTitle, tab.title != title {
                tab.title = title
            }
        }
    }

    private func runtimePresentation(
        _ runtime: AgentProjectedRuntime
    ) -> AgentRuntimePresentation {
        let panes = Set(runtime.panes)
        let resolution: AgentAttachmentResolution = switch runtime.attachment {
        case "attached": .attached
        case "detached": .detached
        default: .unresolved
        }
        return AgentRuntimePresentation(
            kind: AgentKind(rawValue: runtime.provider) ?? .claude,
            runID: runtime.runID ?? runtime.id,
            revision: runtime.revision,
            badge: runtime.badge.asAgentBadge,
            paneIDs: panes,
            // From the topology probe: focus-driven viewed marks skip a tmux
            // pane that is not its window's active one, and ⌘J selects the
            // pane inside tmux.
            tmuxLocations: Dictionary(uniqueKeysWithValues: runtime.panes.compactMap { pane in
                paneLocations[pane].map { (pane, $0) }
            }),
            stateEpisodeToken: runtime.episodeToken,
            attachmentResolution: resolution,
            tmuxRun: tmuxRuns[runtime.id]
        )
    }

    /// Runs the file commands and applies the rest here, where the interface
    /// is. The split is the executor's contract: it owns the lock, this owns
    /// everything that is not a file.
    private func perform(
        _ commands: [AgentProjectionCommand],
        session: WindowSession
    ) -> [AgentCommandOutcome] {
        var outcomes = executor.run(commands)
        for command in commands {
            switch command.op {
            case let .markViewed(runtimeID, token):
                attention?.viewedRuntimeTokens[runtimeID] = token
            case let .cwdChanged(pane, newCwd, oldCwd):
                onCwdChanged?(pane, newCwd, oldCwd)
            case let .gitSyncRefetch(repoRoot):
                onGitSyncRequested?(repoRoot)
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
        return outcomes
    }

    /// Set by the host to receive the cwd changes and git refetch requests
    /// that leave this subsystem.
    var onCwdChanged: ((UUID, String, String?) -> Void)?
    var onGitSyncRequested: ((String) -> Void)?
    /// Set by the host to actually raise a notification. Returns whether it
    /// was delivered, which is what retires the pending entry.
    var onNotify: ((AgentNotifyPayload, Tab) -> Bool)?

    private func deliver(_ payload: AgentNotifyPayload, session: WindowSession) -> Bool {
        guard let onNotify, let tab = session.tabs.first(where: { $0.id == payload.tab }) else {
            return false
        }
        return onNotify(payload, tab)
    }

}

/// One value of the two-clock envelope. A tiny type rather than a dictionary
/// of `Any` so the encoded shape cannot drift.
enum AnyEncodableInstant: Encodable {
    case text(String)
    case number(UInt64)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        }
    }
}
