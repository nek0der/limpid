// ClaudeAgentStateTracker.swift
// Limpid — keeps `Tab.claudeAgentBadges` in sync with the on-disk
// state records the shim's hook writes. On launch we boot from disk;
// while the app is running we watch the agent-states directory with
// `DispatchSource.makeFileSystemObjectSource` so badge updates land
// within a few hundred milliseconds of a hook event.
//
// A periodic PID sweep (default 30 s) defends against Claude crashes
// that skip `Stop` — if `kill(pid, 0)` reports the process is dead
// we force the badge to `.unknown` so the icon disappears. Same
// approach cmux retrofitted in PR #1306.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.agent.state.tracker")

@MainActor
final class ClaudeAgentStateTracker {
    private let store: ClaudeAgentStateStore
    private weak var session: WindowSession?
    /// Set by `bootstrap(triage:)`; weak so we don't extend its
    /// lifetime. Used to auto-mark a finished turn as viewed when it
    /// arrives on the pane the user is currently looking at — the
    /// `focusMoved` path only fires on focus *changes*, so an in-place
    /// `running → finished` transition (same pane stayed focused) would
    /// otherwise stay green forever.
    private weak var triage: TriageState?
    /// Optional notification sink. When wired, the tracker fires a
    /// macOS notification on every `.running` / `.compacting` → `.idle`
    /// transition so users notice when Claude has finished a turn
    /// while they were doing something else.
    private weak var notificationManager: LimpidNotificationManager?
    /// Snapshot of the last badges we observed, indexed by paneID.
    /// Used to detect state transitions (e.g. running → idle) — we
    /// only diff this map, the authoritative copy lives on `Tab`.
    private var previousBadges: [UUID: ClaudeAgentBadge] = [:]
    /// `true` once the initial bootstrap has happened. Used to skip
    /// firing the "Claude finished" notification on launch when we
    /// see a stale `.idle` record from a previous run (the previous
    /// state was effectively `.unknown`, not running).
    private var hasBootstrapped = false

    /// FSEvents-equivalent: a directory monitor on the agent-states
    /// dir. Re-armed every time it fires because
    /// `DispatchSource.makeFileSystemObjectSource` is one-shot per
    /// underlying mtime tick on macOS.
    ///
    /// `nonisolated(unsafe)` so deinit (which is nonisolated under
    /// Swift 6) can read these handles to clean up. Mutation is
    /// confined to the MainActor methods below, so there is no real
    /// concurrent access.
    private nonisolated(unsafe) var dirSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var dirFD: Int32 = -1

    private nonisolated(unsafe) var pidTimer: Timer?

    /// Decoder reused across reads. JSONDecoder is thread-safe for
    /// `decode(_:from:)` usage.
    private let decoder = JSONDecoder()

    init(store: ClaudeAgentStateStore = ClaudeAgentStateStore()) {
        self.store = store
    }

    deinit {
        // Timers and DispatchSources hold on to self via blocks; cancel
        // them on the MainActor (we are nonisolated here) by deferring
        // to the captured handles.
        pidTimer?.invalidate()
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Bootstrap

    /// Sync every alive pane's badge against the on-disk records,
    /// then arm the directory watcher + PID sweep. Called once per
    /// launch after `SessionStore` has restored the snapshot.
    ///
    /// `notificationManager` is optional so unit tests can construct
    /// a tracker without a full app graph; production passes the
    /// live manager so `running → idle` transitions can fire a
    /// "Claude finished" macOS notification.
    func bootstrap(
        into session: WindowSession,
        triage: TriageState? = nil,
        notificationManager: LimpidNotificationManager? = nil
    ) {
        self.session = session
        self.triage = triage
        self.notificationManager = notificationManager
        // Demo mode treats `DemoFixture` as the whole truth: any badge
        // we'd pull from `~/Library/.../agent-states` would clobber the
        // in-memory fixture (the disk lookup deletes badges for panes
        // that have no record). Skip the disk sync + watchers entirely.
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
            if tab.claudeAgentBadges[paneID] != nil {
                tab.claudeAgentBadges[paneID] = nil
            }
        }
    }

    // MARK: - Directory watch

    private func startDirectoryWatch() {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }

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
        // Coalesce bursts (a single hook write fires both .write and
        // .attrib). We re-scan the whole directory each fire instead
        // of trying to diff incremental events — fewer than a hundred
        // panes worth of state.json files is cheap to re-read.
        source.setEventHandler { [weak self] in
            self?.applyAllRecordsToSession()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.dirFD >= 0 {
                close(self.dirFD)
                self.dirFD = -1
            }
        }
        source.resume()
        dirSource = source
    }

    // MARK: - PID sweep

    private func startPIDSweep() {
        pidTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runPIDSweep()
            }
        }
        // Tolerate up to 10 s of drift; the sweep is best-effort.
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pidTimer = timer
    }

    private func runPIDSweep() {
        for record in store.allRecords() {
            guard let pidString = record.pid, let pid = pid_t(pidString) else { continue }
            // `kill(pid, 0)` returns 0 if the process exists and we
            // can signal it; ESRCH means "no such process". Anything
            // else (EPERM etc.) leaves the badge alone — better to
            // show a stale state than to wipe a live session.
            if kill(pid, 0) != 0, errno == ESRCH {
                guard let paneID = UUID(uuidString: record.paneId) else { continue }
                store.delete(paneID: paneID)
                session?.applyAcrossTabs { tab in
                    if tab.claudeAgentBadges[paneID] != nil {
                        tab.claudeAgentBadges[paneID] = nil
                    }
                }
            }
        }
    }

    // MARK: - Apply records to session

    private func applyAllRecordsToSession() {
        guard let session else { return }
        let records = store.allRecords()
        var byPaneID: [UUID: ClaudeAgentStateRecord] = [:]
        byPaneID.reserveCapacity(records.count)
        for record in records {
            guard let id = UUID(uuidString: record.paneId) else { continue }
            byPaneID[id] = record
        }
        // Build the set of alive pane IDs once so we can clean up
        // orphan records (panes that closed while Limpid was down).
        var alive: Set<UUID> = []
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                alive.insert(paneID)
            }
        }

        for tab in session.tabs {
            session.update(tab.id) { mutTab in
                var current = mutTab.claudeAgentBadges
                for paneID in mutTab.splitTree.allLeafIDs() {
                    if let record = byPaneID[paneID],
                       let badge = makeBadge(from: record)
                    {
                        // Drop async hook reorderings: keep whichever
                        // record carries the newer `updatedAt`.
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
                // Drop entries whose pane no longer exists in the
                // split tree (closed split, etc.).
                let leaves = Set(mutTab.splitTree.allLeafIDs())
                for stale in current.keys where !leaves.contains(stale) {
                    current[stale] = nil
                }
                if mutTab.claudeAgentBadges != current {
                    mutTab.claudeAgentBadges = current
                }
            }
        }

        // Diff against the prior snapshot to fire "Claude finished"
        // notifications when a pane goes from running → idle. We
        // only fire after the first apply (the initial scan may pick
        // up stale `.idle` records from before Limpid relaunched,
        // and those don't represent a real transition).
        if hasBootstrapped {
            emitFinishedNotifications(session: session)
        }
        // Refresh the snapshot regardless so the next diff has a
        // baseline.
        rebuildPreviousBadges(session: session)

        // Auto-mark the currently-focused pane's freshly-arrived
        // finished turn as viewed — the user is looking at it as it
        // lands, so the L1 / L2 check should grey immediately. The
        // helper itself bails on the bootstrap pass so a restored
        // finished pane stays unviewed (the user hasn't seen it this
        // run yet); we route through it unconditionally here to keep
        // the caller's branch count down.
        markCurrentlyFocusedViewed(session: session)

        store.cleanup(keeping: alive)
    }

    private func markCurrentlyFocusedViewed(session: WindowSession) {
        // Skip the bootstrap apply: on launch a restored finished pane
        // mustn't be silently marked viewed (the user hasn't actually
        // seen it this run). Same shape as `emitFinishedNotifications`.
        guard hasBootstrapped,
              let triage,
              let activeTabID = session.activeTabID,
              let tab = session.tab(activeTabID),
              let paneID = tab.splitTree.focusedLeafID
        else { return }
        triage.markViewed(paneID: paneID, in: session)
    }

    /// Diff every leaf's prior badge against its current badge and
    /// hand the transition to `AgentNotificationEmitter` to decide
    /// whether a banner should fire. The emitter owns the title /
    /// body / unread logic — see its file header for the rules.
    private func emitFinishedNotifications(session: WindowSession) {
        guard let notificationManager else { return }
        let emitter = AgentNotificationEmitter(
            kind: .claude,
            notificationManager: notificationManager
        )
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let current = tab.claudeAgentBadges[paneID] else { continue }
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
        var next: [UUID: ClaudeAgentBadge] = [:]
        for tab in session.tabs {
            for (paneID, badge) in tab.claudeAgentBadges {
                next[paneID] = badge
            }
        }
        previousBadges = next
    }

    private func makeBadge(from record: ClaudeAgentStateRecord) -> ClaudeAgentBadge? {
        guard let state = AgentState(rawValue: record.state) else { return nil }
        let detail = (record.detail?.isEmpty == false) ? record.detail : nil
        let updatedAt = Self.parseISO8601(record.updatedAt) ?? Date()
        let lastPrompt = (record.lastPrompt?.isEmpty == false) ? record.lastPrompt : nil
        return ClaudeAgentBadge(
            state: state,
            detail: detail,
            runStartedAt: Self.parseOptionalDate(record.runStartedAt),
            contextTokens: record.contextTokens,
            updatedAt: updatedAt,
            lastPrompt: lastPrompt,
            sessionStartedAt: Self.parseOptionalDate(record.sessionStartedAt)
        )
    }

    /// Parse an optional ISO-8601 string from a hook record. Empty
    /// strings (`runStartedAt=""` on a reset) become `nil` so callers
    /// don't have to repeat the empty-vs-missing check inline. `static`
    /// to match `CodexAgentStateTracker.parseOptionalDate` (no instance
    /// state needed) and so a future common helper can be lifted out
    /// without an instance dance.
    private static func parseOptionalDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return parseISO8601(raw)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        ClaudeAgentStateTracker.isoFormatter.date(from: string)
    }

    /// Shared ISO-8601 formatter. `ISO8601DateFormatter` is thread-
    /// safe for `date(from:)` once configured; we keep one static
    /// instance to avoid per-call allocation.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - WindowSession helper

@MainActor
extension WindowSession {
    /// Apply a mutating transform to every tab. Used by the agent
    /// state tracker so it can clear stale per-pane entries without
    /// hard-coding the iteration shape at the call site.
    func applyAcrossTabs(_ transform: (inout Tab) -> Void) {
        for tab in tabs {
            update(tab.id, transform: transform)
        }
    }
}
