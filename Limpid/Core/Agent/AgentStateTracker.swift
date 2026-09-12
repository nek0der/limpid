// AgentStateTracker.swift
// Limpid — generic runtime lifecycle tracker and pane projection for any `AgentSpec`
// flavour. Sub-phase 2.2d collapsed `ClaudeAgentStateTracker` and
// `CodexAgentStateTracker` (~785 LOC of near-identical code) into one
// parameterised class. Both trackers shared the same skeleton —
// bootstrap from disk, watch the state directory with
// `DispatchSource.makeFileSystemObjectSource`, sweep dead PIDs every
// `S.pidSweepInterval`, fire "agent finished" notifications on
// `running → finished`, auto-mark the currently-focused pane as
// viewed — but each owned its own copy.
//
// The Codex side adds two methods Claude does not need
// (`cleanupDeadSessionsOnLaunch` + `preserveLiveSessionsOnTerminate`,
// driven by Codex's missing SessionEnd-equivalent hook); those live
// in an `extension AgentStateTracker where S == CodexAgent` so the
// generic skeleton stays Claude-clean.

import Foundation
import OSLog

@MainActor
final class AgentStateTracker<S: AgentSpec> {
    typealias Store = AgentStateStore<S.StateRecord>
    typealias SessionStore = PaneStore<S.SessionRecord>

    let store: Store
    /// Companion session store. Codex passes a non-nil store so the
    /// PID sweep can delete the resume record at the same time it
    /// clears the badge (Codex has no SessionEnd hook, so a stale
    /// `state=idle` record would auto-resume a `/quit`ted session on
    /// the next launch). Claude leaves this nil.
    let sessionStore: SessionStore?
    let resumeIntents: AgentResumeIntentStore
    private let processStatus: (String?) -> AgentProcessStatus

    private weak var session: WindowSession?
    /// Auto-marks the focused pane's finished turn as viewed when it
    /// lands in place (no focus change). `focusMoved` only fires on
    /// changes, so a `running → finished` transition on the same pane
    /// would otherwise stay green forever.
    private weak var attention: AttentionState?
    /// Optional notification sink. Wired in production so
    /// `running → finished` transitions fire a macOS notification;
    /// tests pass nil.
    private weak var notificationManager: LimpidNotificationManager?
    private weak var tmuxPresence: TmuxPanePresence?
    /// We diff per invocation, even while detached, so attaching another
    /// client neither duplicates notifications nor invents transitions.
    private var notificationOutbox = AgentNotificationOutbox()
    private var stateEpisodeTracker = AgentStateEpisodeTracker()
    private var acceptedRecords: [String: S.StateRecord] = [:]
    var socketPaths: Set<String> {
        Set(acceptedRecords.values.compactMap(\.tmuxSocketPath))
    }

    /// Set once the bootstrap apply has run. Skips notifications +
    /// auto-viewed marking on the first pass so a restored
    /// `.finished` record from a previous run doesn't fire a banner.
    private var hasBootstrapped = false

    /// FSEvents-equivalent: a directory monitor on the state dir.
    /// `nonisolated(unsafe)` so deinit (nonisolated under Swift 6)
    /// can read these handles to clean up; mutation is otherwise
    /// confined to the MainActor methods below.
    private nonisolated(unsafe) var dirSource: (any DispatchSourceFileSystemObject)?
    private nonisolated(unsafe) var dirFD: Int32 = -1
    private nonisolated(unsafe) var pidTimer: Timer?

    private let log: Logger

    init(
        store: Store,
        sessionStore: SessionStore? = nil,
        processStatus: @escaping (String?) -> AgentProcessStatus = AgentProcessStatus.inspect
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.resumeIntents = AgentResumeIntentStore(directory: store.directory.appendingPathComponent("resume-intents"))
        self.processStatus = processStatus
        self.log = Logger.limpid("\(S.label).agent.state.tracker")
    }

    deinit {
        // Timers and DispatchSources hold on to self via blocks;
        // cancel them via the captured handles. The `dirFD` close is
        // owned by the source's cancel handler (see
        // `startDirectoryWatch`) — touching it here would race the
        // cancel handler and double-close the same fd. Mirror of
        // `SettingsFileWatcher`'s teardown pattern.
        pidTimer?.invalidate()
        dirSource?.cancel()
    }

    // MARK: - Bootstrap

    /// Project every on-disk runtime record onto its current pane,
    /// then arm the directory watcher + PID sweep. Called once per
    /// launch after `SessionStore` has restored the snapshot.
    func bootstrap(
        into session: WindowSession,
        attention: AttentionState? = nil,
        notificationManager: LimpidNotificationManager? = nil,
        tmuxPresence: TmuxPanePresence? = nil
    ) {
        self.session = session
        self.attention = attention
        self.notificationManager = notificationManager
        self.tmuxPresence = tmuxPresence
        // Demo mode treats `DemoFixture` as the whole truth — any
        // badge we'd pull from the Application Support directory
        // would clobber the in-memory fixture (the disk lookup
        // deletes badges for panes that have no record).
        guard !DemoFixture.isDemoActive else {
            hasBootstrapped = true
            return
        }
        applyAllRecordsToSession()
        hasBootstrapped = true
        startDirectoryWatch()
        startPIDSweep()
    }

    /// Drop direct runtime records launched from a pane that closed. tmux
    /// runtimes survive because the outer client is not their owner.
    func didClosePane(_ paneID: UUID) {
        store.deleteRecords(launchedFrom: paneID, includingTmux: false)
        session?.applyAcrossTabs { tab in
            if tab[keyPath: S.badgesKeyPath][paneID] != nil {
                tab[keyPath: S.badgesKeyPath][paneID] = nil
            }
        }
    }

    func refreshPresentation() {
        // Same rule as bootstrap: the tmux presence poll and the
        // attention callback both land here, and in demo mode a disk
        // pass would replace the fixture's badges with an empty runtime
        // list — which is exactly how the hero screenshot lost its
        // Waiting rows.
        guard !DemoFixture.isDemoActive else { return }
        applyAllRecordsToSession()
    }

    // MARK: - Directory watch

    private func startDirectoryWatch() {
        // Re-arm: cancel the old source and let its cancel handler
        // close its captured fd. We just clear our cached `dirFD`
        // pointer so subsequent reads don't fall back to the old one.
        dirSource?.cancel()
        dirFD = -1

        let path = store.directory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("open(\(path, privacy: .public), O_EVTONLY) failed errno=\(errno)")
            return
        }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        // Coalesce bursts (a single hook write fires both .write
        // and .attrib). Re-scan the directory each fire instead of
        // diffing incremental events — fewer than a hundred panes
        // worth of state.json files is cheap to re-read.
        source.setEventHandler { [weak self] in
            self?.applyAllRecordsToSession()
        }
        // Capture `fd` by value so the close is owned by this source's
        // lifetime rather than the tracker's. Mirror of
        // `SettingsFileWatcher`. Avoids the race where deinit closes
        // the fd before the cancel handler runs, or where a re-arm
        // opens a new fd that ends up double-closed when the old
        // cancel handler finally fires.
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        dirSource = source
    }

    // MARK: - PID sweep

    private func startPIDSweep() {
        pidTimer?.invalidate()
        let interval = S.pidSweepInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runPIDSweep()
            }
        }
        // Tolerate up to a third of the interval as drift — sweep is
        // best-effort.
        timer.tolerance = interval / 3
        RunLoop.main.add(timer, forMode: .common)
        pidTimer = timer
    }

    func runPIDSweep() {
        var didDeleteRecord = false
        for record in store.allRecords() {
            // `kill(pid, 0)` returns 0 if the process exists; ESRCH
            // means "no such process". Anything else (EPERM etc.)
            // leaves the badge alone — better to show a stale state
            // than to wipe a live session.
            guard processStatus(record.pid) == .dead else { continue }
            // A pending independent intent is preserved until startup can
            // consume it. Busy cleanup remains on disk for the next sweep.
            if resumeIntents.record(runID: record.storageID) != nil {
                continue
            }
            if removeDeadRecord(record) {
                didDeleteRecord = true
            }
        }
        if didDeleteRecord {
            applyAllRecordsToSession()
        }
    }

    /// The launch pane is not ownership. We coordinate with SessionStart
    /// and compare invocation IDs before removing a native resume hint.
    private func deleteOwnedResumeHint(for record: S.StateRecord) throws -> RecordMutationOutcome {
        guard !record.isTmuxRuntime, let sessionStore,
              let paneID = UUID(uuidString: record.paneId)
        else { return .applied }
        let url = sessionStore.directory.appendingPathComponent("\(paneID.uuidString).json")
        return try AgentFileLock.withLock(for: url) {
            guard let hint = sessionStore.record(forPaneID: paneID) else { return .notFound }
            guard hint.runId == record.runId else { return .preconditionChanged }
            if record.runId == nil,
               store.allRecords().contains(where: {
                   $0.paneId == record.paneId && $0.storageID != record.storageID
               })
            {
                return .preconditionChanged
            }
            try FileManager.default.removeItem(at: url)
            session?.applyAcrossTabs { tab in
                tab[keyPath: S.sessionsKeyPath][paneID] = nil
            }
            return .applied
        }
    }

    private func removeDeadRecord(_ record: S.StateRecord) -> Bool {
        do {
            guard try deleteOwnedResumeHint(for: record) != .busy else { return false }
            return try store.removeIfUnchanged(record) == .applied
        } catch {
            // Retain the runtime as the retry token; never claim that its
            // companion hint was removed after an I/O failure.
            log.error("deferred runtime cleanup: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    // MARK: - Apply records to session

    private func loadOrderedRecords() -> [S.StateRecord] {
        let diskRecords = store.allRecords()
        let readIDs = Set(diskRecords.map(\.storageID))
        acceptedRecords = acceptedRecords.filter { id, _ in readIDs.contains(id) || store.recordExists(recordID: id) != false }
        for record in diskRecords {
            if let previous = acceptedRecords[record.storageID] {
                if let revision = record.revision, let prior = previous.revision, revision <= prior {
                    continue
                }
                if record.revision == nil, record.updatedAt < previous.updatedAt {
                    continue
                }
            }
            acceptedRecords[record.storageID] = record
        }
        return Array(acceptedRecords.values)
    }

    private func applyAllRecordsToSession() {
        guard let session else { return }
        let records = loadOrderedRecords()
        var recordsByPaneID: [UUID: [S.StateRecord]] = [:]
        var runtimes: [AgentRuntimePresentation] = []
        for record in records {
            let targets: Set<UUID> = if record.isTmuxRuntime {
                Set((tmuxPresence?.attachments(for: record.tmuxEndpoint) ?? [:]).keys)
            } else if let paneID = UUID(uuidString: record.paneId) {
                [paneID]
            } else {
                []
            }
            for target in targets {
                recordsByPaneID[target, default: []].append(record)
            }
            if let badge = S.makeBadge(from: record) {
                runtimes.append(AgentRuntimePresentation(
                    kind: S.kind, runID: record.storageID, revision: record.revision,
                    badge: badge, paneIDs: targets,
                    tmuxLocations: record.isTmuxRuntime ? (tmuxPresence?.attachments(for: record.tmuxEndpoint) ?? [:]) : [:],
                    stateEpisodeToken: record.stateEpisodeToken,
                    attachmentResolution: record.isTmuxRuntime
                        ? (tmuxPresence?.resolution(for: record.tmuxEndpoint) ?? .unresolved)
                        : (targets.isEmpty ? .detached : .attached)
                ))
            }
        }
        runtimes = stateEpisodeTracker.stamp(runtimes)
        attention?.replaceRuntimes(runtimes, kind: S.kind)
        var alive: Set<UUID> = []
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                alive.insert(paneID)
            }
        }

        for tab in session.tabs {
            session.update(tab.id) { mutTab in
                reconcile(&mutTab, recordsByPaneID: recordsByPaneID)
            }
        }

        // Diff against the prior snapshot to fire "agent finished"
        // notifications when a pane goes from running → finished.
        // Only fire after the first apply — restored `.finished`
        // records from before Limpid relaunched aren't real
        // transitions.
        let events = notificationOutbox.observe(runtimes, now: ProcessInfo.processInfo.systemUptime, isBootstrap: !hasBootstrapped)
        emitFinishedNotifications(session: session, events: events)

        // Auto-mark the currently-focused pane's freshly-arrived
        // finished turn as viewed — the user is looking at it as it
        // lands. The helper bails on the bootstrap pass.
        markCurrentlyFocusedViewed(session: session)

        let orphans = AgentLifecyclePolicy.removableRecords(records, alivePanes: alive, processStatus: processStatus)
        for record in records where orphans.contains(record.storageID) && resumeIntents.record(runID: record.storageID) == nil {
            _ = removeDeadRecord(record)
        }
        store.pruneRetired()
    }

    /// Refresh one tab's per-pane badges from the on-disk records and
    /// call into `S.applyTabTitle` so flavour-specific titling (Codex
    /// firstPrompt → tab.title) lands in the same atomic update.
    private func reconcile(
        _ tab: inout Tab,
        recordsByPaneID: [UUID: [S.StateRecord]]
    ) {
        var current = tab[keyPath: S.badgesKeyPath]
        // One walk over the split tree: feeds both the per-pane
        // reconcile loop and the stale-cleanup membership check
        // below. The prior shape called `allLeafIDs()` twice per
        // tab — fine on small trees, but this runs on every disk
        // event so the allocation noise stacks up.
        let leafIDs = tab.splitTree.allLeafIDs()
        for paneID in leafIDs {
            if let record = dominantRecord(in: recordsByPaneID[paneID] ?? []),
               let badge = S.makeBadge(from: record)
            {
                // Each run has already been reduced by revision. Comparing
                // this aggregate against the prior pane timestamp would let
                // a newer low-priority run hide an older needs-input run.
                if current[paneID] != badge {
                    current[paneID] = badge
                }
            } else if current[paneID] != nil {
                current[paneID] = nil
            }
        }
        let leaves = Set(leafIDs)
        // Snapshot the keys before mutating — `current.keys` is a
        // view onto the dict's buffer; removing entries mid-iteration
        // is undefined.
        let staleIDs = current.keys.filter { !leaves.contains($0) }
        for stale in staleIDs {
            current[stale] = nil
        }
        if tab[keyPath: S.badgesKeyPath] != current {
            tab[keyPath: S.badgesKeyPath] = current
        }
        S.applyTabTitle(&tab, badges: current)
    }

    private func dominantRecord(in records: [S.StateRecord]) -> S.StateRecord? {
        records.max { lhs, rhs in
            let lhsPriority = displayPriority(lhs)
            let rhsPriority = displayPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            // Revisions only order events within one run, never peers.
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.storageID < rhs.storageID
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func displayPriority(_ record: S.StateRecord) -> Int {
        guard let badge = S.makeBadge(from: record) else { return -1 }
        return attention?.displayPriority(kind: S.kind, runID: record.storageID, badge: badge) ?? badge.state.priority
    }

    private func markCurrentlyFocusedViewed(session: WindowSession) {
        guard hasBootstrapped,
              let attention,
              let activeTabID = session.activeTabID,
              let tab = session.tab(activeTabID),
              let paneID = tab.splitTree.focusedLeafID,
              LimpidNotificationDelegate.isPaneFocused(paneIDString: paneID.uuidString)
        else { return }
        attention.markViewed(paneID: paneID, in: session)
    }

    /// Emit one transition per invocation, regardless of client count.
    private func emitFinishedNotifications(session: WindowSession, events: [AgentRuntimeTransition]) {
        guard let notificationManager else { return }
        for transition in events {
            let runtime = transition.runtime
            let focused = session.activeTab?.splitTree.focusedLeafID
            let preferred = focused.flatMap { runtime.paneIDs.contains($0) ? $0 : nil }
            guard let paneID = preferred ?? runtime.paneIDs.sorted(by: { $0.uuidString < $1.uuidString }).first,
                  let tab = session.tab(containing: paneID)
            else { continue }
            let emitter = AgentNotificationEmitter(
                kind: S.kind, notificationManager: notificationManager,
                suppressWhenPaneFocused: runtime.tmuxLocations[paneID]?.isActive ?? true,
                runtimeID: runtime.id,
                eventToken: runtime.attentionEventToken
            )
            emitter.handleTransition(
                tab: tab, paneID: paneID, previous: transition.previous,
                current: runtime.badge, session: session
            )
            notificationOutbox.acknowledge(transition)
        }
    }
}

// MARK: - Codex-only lifecycle methods

extension AgentStateTracker where S == CodexAgent {
    /// One-shot PID liveness check called from `LimpidApp` before the
    /// session tracker bootstraps. Without this, a `/quit` that exits
    /// Codex between Limpid sessions leaves a stale rollout id on
    /// disk and the next launch auto-resumes a conversation the user
    /// closed. Operates purely on disk (the tracker isn't attached
    /// to a `WindowSession` yet at this point) — drops state +
    /// session files in lockstep.
    func cleanupDeadSessionsOnLaunch() {
        guard sessionStore != nil else { return }
        for record in store.allRecords() {
            if record.isTmuxRuntime, record.pid == nil {
                continue
            }
            let status = processStatus(record.pid)
            if status == .alive {
                continue
            }
            if status == .unknown, record.resumeAttemptedAt == nil, record.killedByLimpidAt == nil {
                continue
            }

            if let intent = resumeIntents.record(runID: record.storageID),
               intent.runID == record.storageID, intent.pid == record.pid,
               intent.paneID.uuidString == record.paneId,
               Date().timeIntervalSince(intent.createdAt) < AgentResumeIntentStore.lifetime,
               let hint = sessionStore?.record(forPaneID: intent.paneID),
               hint.runId == intent.ownerRunID, hint.sessionId == intent.sessionID
            {
                do {
                    let outcome = try store.update(recordID: record.storageID, matching: {
                        $0.pid == record.pid && $0.revision == record.revision
                    }, transform: { latest in
                        latest.pid = nil
                        latest.killedByLimpidAt = nil
                        latest.state = "unknown"
                        latest.resumeAttemptedAt = AgentDateParsing.formatISO8601(Date())
                    })
                    if outcome == .applied {
                        try resumeIntents.remove(runID: record.storageID)
                    }
                } catch {
                    log.error("deferred resume protection: \(error.localizedDescription, privacy: .private)")
                }
                continue
            }

            // Honor the "Limpid killed it" marker for one resume
            // attempt — but only when recent (24 h) and we always
            // clear it so we can't loop. If the hook hasn't
            // re-stamped a fresh pid on the next boot (Codex TUI
            // delays SessionStart on resume), we fall through and
            // delete on the second pass.
            //
            // Also clear `pid` here: if we left the dead pid in
            // place, the 3-second `runPIDSweep` would catch it on
            // the next tick and delete this record we just chose to
            // preserve. Nil-ing the pid keeps the record alive until
            // either a fresh hook fire restamps it or the marker
            // ages out.
            if let killedAt = record.killedByLimpidAt,
               let date = AgentDateParsing.parseISO8601(killedAt),
               Date().timeIntervalSince(date) < 86400
            {
                // Best-effort: if the write fails (disk full, sandbox
                // permission flake) the marker stays on disk and the
                // next launch retries the exact same clear. Failing
                // the whole cleanup loop for one stale-marker row
                // would be worse than letting the row come back next
                // launch.
                _ = try? store.update(recordID: record.storageID, matching: {
                    $0.pid == record.pid && $0.revision == record.revision
                }, transform: { latest in
                    latest.killedByLimpidAt = nil
                    latest.pid = nil
                    latest.state = "unknown"
                    latest.resumeAttemptedAt = AgentDateParsing.formatISO8601(Date())
                })
                continue
            }

            // No marker (or stale marker). Delete both state and
            // session records.
            if removeDeadRecord(record) {
                // The runtime/hint cleanup completed; an expired intent no
                // longer has an owner. Failure here is harmless stale metadata.
                try? resumeIntents.remove(runID: record.storageID)
            }
        }
    }

    /// Called on `applicationWillTerminate`. For every codex state
    /// record whose pid is still alive (codex is running and is
    /// about to be killed alongside Limpid), stamp a
    /// `killedByLimpidAt` marker. The pid stays in place — the next
    /// launch sees it's dead and consults the marker to decide
    /// whether to preserve the session (yes, marker is recent) or
    /// treat the death as a `/quit` and drop everything.
    func preserveLiveSessionsOnTerminate() {
        let nowISO = AgentDateParsing.formatISO8601(Date())
        for record in store.allRecords() {
            // A tmux-hosted process survives Limpid, so it needs neither a
            // forced-kill marker nor a native resume on the next launch.
            guard !record.isTmuxRuntime else { continue }
            guard let pidString = record.pid else {
                continue
            }
            guard processStatus(record.pid) == .alive else { continue }
            if let paneID = UUID(uuidString: record.paneId),
               let hint = sessionStore?.record(forPaneID: paneID), hint.runId == record.runId
            {
                do {
                    try resumeIntents.save(AgentResumeIntent(
                        runID: record.storageID,
                        paneID: paneID,
                        sessionID: hint.sessionId,
                        ownerRunID: hint.runId,
                        pid: pidString,
                        createdAt: Date()
                    ))
                } catch {
                    log.error("could not persist resume intent: \(error.localizedDescription, privacy: .private)")
                }
            }
            // Best-effort: this runs from `applicationWillTerminate`
            // and the process is about to exit anyway. A failed save
            // costs us the resume marker for one row — the next
            // launch's PID sweep correctly treats the row as having
            // exited cleanly, which is the safer fail-mode than
            // blocking termination on a disk error.
            _ = try? store.update(recordID: record.storageID) { $0.killedByLimpidAt = nowISO }
        }
    }
}
