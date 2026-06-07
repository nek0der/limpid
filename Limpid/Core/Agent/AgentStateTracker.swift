// AgentStateTracker.swift
// Limpid — generic per-pane lifecycle tracker for any `AgentSpec`
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
    typealias Store = PaneStore<S.StateRecord>
    typealias SessionStore = PaneStore<S.SessionRecord>

    let store: Store
    /// Companion session store. Codex passes a non-nil store so the
    /// PID sweep can delete the resume record at the same time it
    /// clears the badge (Codex has no SessionEnd hook, so a stale
    /// `state=idle` record would auto-resume a `/quit`ted session on
    /// the next launch). Claude leaves this nil.
    let sessionStore: SessionStore?

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
    /// Snapshot of the last badges per pane. Diffed against the
    /// current dict to detect transitions; the authoritative copy
    /// lives on `Tab`.
    private var previousBadges: [UUID: AgentBadge] = [:]
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

    init(store: Store, sessionStore: SessionStore? = nil) {
        self.store = store
        self.sessionStore = sessionStore
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

    /// Sync every alive pane's badge against the on-disk records,
    /// then arm the directory watcher + PID sweep. Called once per
    /// launch after `SessionStore` has restored the snapshot.
    func bootstrap(
        into session: WindowSession,
        attention: AttentionState? = nil,
        notificationManager: LimpidNotificationManager? = nil
    ) {
        self.session = session
        self.attention = attention
        self.notificationManager = notificationManager
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

    /// Drop the on-disk record for a pane that has been closed for
    /// good. Idempotent.
    func didClosePane(_ paneID: UUID) {
        store.delete(paneID: paneID)
        session?.applyAcrossTabs { tab in
            if tab[keyPath: S.badgesKeyPath][paneID] != nil {
                tab[keyPath: S.badgesKeyPath][paneID] = nil
            }
        }
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

    private func runPIDSweep() {
        let hasSessionStore = sessionStore != nil
        for record in store.allRecords() {
            guard let pidString = record.pid, let pid = pid_t(pidString) else { continue }
            // `kill(pid, 0)` returns 0 if the process exists; ESRCH
            // means "no such process". Anything else (EPERM etc.)
            // leaves the badge alone — better to show a stale state
            // than to wipe a live session.
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            guard let paneID = UUID(uuidString: record.paneId) else { continue }
            store.delete(paneID: paneID)
            // Codex companion: drop the resume record too — `/quit`
            // is indistinguishable from a crash from our point of
            // view, so leaving the session in place would auto-resume
            // a conversation the user just dismissed. Claude side
            // skips this branch (sessionStore == nil).
            sessionStore?.delete(paneID: paneID)
            session?.applyAcrossTabs { tab in
                if tab[keyPath: S.badgesKeyPath][paneID] != nil {
                    tab[keyPath: S.badgesKeyPath][paneID] = nil
                }
                if hasSessionStore, tab[keyPath: S.sessionsKeyPath][paneID] != nil {
                    tab[keyPath: S.sessionsKeyPath][paneID] = nil
                }
            }
        }
    }

    // MARK: - Apply records to session

    private func applyAllRecordsToSession() {
        guard let session else { return }
        let records = store.allRecords()
        var byPaneID: [UUID: S.StateRecord] = [:]
        byPaneID.reserveCapacity(records.count)
        for record in records {
            guard let id = UUID(uuidString: record.paneId) else { continue }
            byPaneID[id] = record
        }
        var alive: Set<UUID> = []
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                alive.insert(paneID)
            }
        }

        for tab in session.tabs {
            session.update(tab.id) { mutTab in
                reconcile(&mutTab, byPaneID: byPaneID)
            }
        }

        // Diff against the prior snapshot to fire "agent finished"
        // notifications when a pane goes from running → finished.
        // Only fire after the first apply — restored `.finished`
        // records from before Limpid relaunched aren't real
        // transitions.
        if hasBootstrapped {
            emitFinishedNotifications(session: session)
        }
        rebuildPreviousBadges(session: session)

        // Auto-mark the currently-focused pane's freshly-arrived
        // finished turn as viewed — the user is looking at it as it
        // lands. The helper bails on the bootstrap pass.
        markCurrentlyFocusedViewed(session: session)

        store.cleanup(keeping: alive)
    }

    /// Refresh one tab's per-pane badges from the on-disk records and
    /// call into `S.applyTabTitle` so flavour-specific titling (Codex
    /// firstPrompt → tab.title) lands in the same atomic update.
    private func reconcile(_ tab: inout Tab, byPaneID: [UUID: S.StateRecord]) {
        var current = tab[keyPath: S.badgesKeyPath]
        // One walk over the split tree: feeds both the per-pane
        // reconcile loop and the stale-cleanup membership check
        // below. The prior shape called `allLeafIDs()` twice per
        // tab — fine on small trees, but this runs on every disk
        // event so the allocation noise stacks up.
        let leafIDs = tab.splitTree.allLeafIDs()
        for paneID in leafIDs {
            if let record = byPaneID[paneID],
               let badge = S.makeBadge(from: record)
            {
                // Drop out-of-order async updates.
                if let existing = current[paneID],
                   existing.updatedAt > badge.updatedAt
                {
                    continue
                }
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

    private func markCurrentlyFocusedViewed(session: WindowSession) {
        guard hasBootstrapped,
              let attention,
              let activeTabID = session.activeTabID,
              let tab = session.tab(activeTabID),
              let paneID = tab.splitTree.focusedLeafID
        else { return }
        attention.markViewed(paneID: paneID, in: session)
    }

    /// Diff every leaf's prior badge against its current badge and
    /// hand the transition to `AgentNotificationEmitter`.
    private func emitFinishedNotifications(session: WindowSession) {
        guard let notificationManager else { return }
        let emitter = AgentNotificationEmitter(
            kind: S.kind,
            notificationManager: notificationManager
        )
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let current = tab[keyPath: S.badgesKeyPath][paneID] else { continue }
                emitter.handleTransition(
                    tab: tab,
                    paneID: paneID,
                    previous: previousBadges[paneID],
                    current: current,
                    session: session
                )
            }
        }
    }

    private func rebuildPreviousBadges(session: WindowSession) {
        var next: [UUID: AgentBadge] = [:]
        for tab in session.tabs {
            for (paneID, badge) in tab[keyPath: S.badgesKeyPath] {
                next[paneID] = badge
            }
        }
        previousBadges = next
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
        guard let sessionStore else { return }
        for record in store.allRecords() {
            var isAlive = false
            if let pidString = record.pid, let pid = pid_t(pidString) {
                let killRC = kill(pid, 0)
                let killErrno = errno
                isAlive = killRC == 0 || killErrno == EPERM
            }
            if isAlive { continue }

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
                var updated = record
                updated.killedByLimpidAt = nil
                updated.pid = nil
                // Best-effort: if the write fails (disk full, sandbox
                // permission flake) the marker stays on disk and the
                // next launch retries the exact same clear. Failing
                // the whole cleanup loop for one stale-marker row
                // would be worse than letting the row come back next
                // launch.
                try? store.save(updated)
                continue
            }

            // No marker (or stale marker). Delete both state and
            // session records.
            guard let paneID = UUID(uuidString: record.paneId) else { continue }
            store.delete(paneID: paneID)
            sessionStore.delete(paneID: paneID)
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
            guard let pidString = record.pid, let pid = pid_t(pidString) else {
                continue
            }
            let killRC = kill(pid, 0)
            let killErrno = errno
            let isAlive = killRC == 0 || killErrno == EPERM
            guard isAlive else { continue }
            var updated = record
            updated.killedByLimpidAt = nowISO
            // Best-effort: this runs from `applicationWillTerminate`
            // and the process is about to exit anyway. A failed save
            // costs us the resume marker for one row — the next
            // launch's PID sweep correctly treats the row as having
            // exited cleanly, which is the safer fail-mode than
            // blocking termination on a disk error.
            try? store.save(updated)
        }
    }
}
