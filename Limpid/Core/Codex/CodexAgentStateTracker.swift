// CodexAgentStateTracker.swift
// Limpid — keeps `Tab.codexAgentBadges` in sync with the on-disk
// state records the Codex hook writes. Mirror of
// `ClaudeAgentStateTracker`: bootstrap from disk, watch the dir with
// `DispatchSource.makeFileSystemObjectSource`, sweep dead PIDs every
// 3 s (tighter than Claude's 30 s because Codex has no
// SessionEnd-equivalent hook). Notification copy uses "Codex" labels
// so users can tell which agent finished when both Claude and Codex
// are running.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "codex.agent.state.tracker")

@MainActor
final class CodexAgentStateTracker {
    private let store: CodexAgentStateStore
    /// Companion session store so the PID sweep can drop the resume
    /// record at the same time it clears the badge. Codex has no
    /// SessionEnd-equivalent hook, so when the user types `/quit`
    /// Codex exits silently — without this cleanup, the next launch
    /// would auto-resume a session the user explicitly closed.
    private let sessionStore: CodexSessionStore
    private weak var session: WindowSession?
    /// Auto-marks the focused pane's finished turn as viewed when it
    /// lands in place (no focus change). Mirrors the Claude tracker.
    private weak var triage: TriageState?
    private weak var notificationManager: LimpidNotificationManager?
    private var previousBadges: [UUID: CodexAgentBadge] = [:]
    private var hasBootstrapped = false

    private nonisolated(unsafe) var dirSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var dirFD: Int32 = -1
    private nonisolated(unsafe) var pidTimer: Timer?

    private let decoder = JSONDecoder()

    init(
        store: CodexAgentStateStore = CodexAgentStateStore(),
        sessionStore: CodexSessionStore = CodexSessionStore()
    ) {
        self.store = store
        self.sessionStore = sessionStore
    }

    deinit {
        pidTimer?.invalidate()
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Bootstrap

    func bootstrap(
        into session: WindowSession,
        triage: TriageState? = nil,
        notificationManager: LimpidNotificationManager? = nil
    ) {
        self.session = session
        self.triage = triage
        self.notificationManager = notificationManager
        // Same demo-mode guard as `ClaudeAgentStateTracker.bootstrap`:
        // skip the disk sync so `DemoFixture` stays the source of truth.
        guard !DemoFixture.isDemoActive else {
            hasBootstrapped = true
            return
        }
        applyAllRecordsToSession()
        hasBootstrapped = true
        startDirectoryWatch()
        startPIDSweep()
    }

    func didClosePane(_ paneID: UUID) {
        store.delete(paneID: paneID)
        session?.applyAcrossTabs { tab in
            if tab.codexAgentBadges[paneID] != nil {
                tab.codexAgentBadges[paneID] = nil
            }
        }
    }

    /// One-shot PID liveness check called from `LimpidApp` before the
    /// session tracker bootstraps. Without this, a `/quit` that exits
    /// Codex between Limpid sessions leaves a stale rollout id on disk
    /// and the next launch auto-resumes a conversation the user closed.
    /// Operates purely on disk (the tracker isn't attached to a
    /// WindowSession yet at this point) — drops state + session files
    /// in lockstep.
    func cleanupDeadSessionsOnLaunch() {
        for record in store.allRecords() {
            // Decide alive/dead first.
            var isAlive = false
            if let pidString = record.pid, let pid = pid_t(pidString) {
                let killRC = kill(pid, 0)
                let killErrno = errno
                isAlive = killRC == 0 || killErrno == EPERM
            }
            if isAlive { continue }

            // Dead or unknown. Honor the "Limpid killed it" marker
            // for one resume attempt — but only when it's recent
            // (24h) and we always clear it so we can't loop. If the
            // hook hasn't re-stamped a fresh pid on the next boot
            // (Codex TUI delays SessionStart on resume — upstream
            // #15269 / #24228), we fall through and delete on the
            // second pass.
            //
            // Also clear `pid` here: if we left the dead pid in
            // place, the 3-second `runPIDSweep` would catch it on
            // the next tick and delete this record we just chose to
            // preserve. Nil-ing the pid keeps the record alive
            // until either a fresh hook fire restamps it or the
            // marker ages out (next cleanup pass deletes).
            if let killedAt = record.killedByLimpidAt,
               let date = Self.parseISO8601(killedAt),
               Date().timeIntervalSince(date) < 86400
            {
                var updated = record
                updated.killedByLimpidAt = nil
                updated.pid = nil
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
    /// record whose pid is still alive (i.e. codex is running and is
    /// about to be killed alongside Limpid), stamp a
    /// `killedByLimpidAt` marker. The pid stays in place — the next
    /// launch will see it's dead and consult the marker to decide
    /// whether to preserve the session (yes, if the marker is recent)
    /// or treat the death as a `/quit` and drop everything (no
    /// marker present).
    ///
    /// Records whose codex already exited (e.g. user typed `/quit`
    /// before ⌘Q) get no marker → next launch's cleanup deletes
    /// them, which is the desired behaviour.
    func preserveLiveSessionsOnTerminate() {
        let nowISO = Self.isoFormatter.string(from: Date())
        for record in store.allRecords() {
            guard let pidString = record.pid, let pid = pid_t(pidString) else {
                continue
            }
            let killRC = kill(pid, 0)
            let killErrno = errno
            let isAlive = killRC == 0 || killErrno == EPERM
            guard isAlive else { continue }
            // Mark "Limpid killed this on terminate" via the sidecar
            // field. Keep the pid in place — the next bootstrap will
            // see it's dead, then check the marker for the one-shot
            // resume permission.
            var updated = record
            updated.killedByLimpidAt = nowISO
            try? store.save(updated)
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

    /// Tighter than the Claude side (30 s) because Codex has no
    /// SessionEnd-equivalent hook — `/q` / Ctrl-C / crash all leave a
    /// stale `state=idle` record with a dead pid that this sweep is
    /// the only signal for. Three seconds keeps the L2 sparkle icon
    /// from lingering visibly after the user exits codex while still
    /// being cheap (one `kill(pid, 0)` per live record per tick).
    private func startPIDSweep() {
        pidTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runPIDSweep()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pidTimer = timer
    }

    private func runPIDSweep() {
        for record in store.allRecords() {
            guard let pidString = record.pid, let pid = pid_t(pidString) else { continue }
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            guard let paneID = UUID(uuidString: record.paneId) else { continue }
            store.delete(paneID: paneID)
            // Drop the resume record too — `/quit` is indistinguishable
            // from a crash from our point of view, both reach this
            // branch. Leaving the session in place would auto-resume
            // a conversation the user just dismissed.
            sessionStore.delete(paneID: paneID)
            session?.applyAcrossTabs { tab in
                if tab.codexAgentBadges[paneID] != nil {
                    tab.codexAgentBadges[paneID] = nil
                }
                if tab.codexSessions[paneID] != nil {
                    tab.codexSessions[paneID] = nil
                }
            }
        }
    }

    // MARK: - Apply records to session

    private func applyAllRecordsToSession() {
        guard let session else { return }
        let records = store.allRecords()
        var byPaneID: [UUID: CodexAgentStateRecord] = [:]
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

        if hasBootstrapped {
            emitFinishedNotifications(session: session)
        }
        rebuildPreviousBadges(session: session)

        // Mirror the Claude tracker: a finished turn landing on the
        // currently-focused pane should grey the L1 / L2 check on the
        // spot, without waiting for the next focus change. The helper
        // bails on the bootstrap pass (a restored finished pane stays
        // unviewed on relaunch); routing unconditionally keeps the
        // caller's branch count down.
        markCurrentlyFocusedViewed(session: session)

        store.cleanup(keeping: alive)
    }

    /// Refresh one tab's per-pane badges from the on-disk records and
    /// name the tab after the focused Codex pane's opening prompt.
    /// Split out of `applyAllRecordsToSession` so each stays under the
    /// cyclomatic-complexity limit.
    private func reconcile(
        _ tab: inout Tab,
        byPaneID: [UUID: CodexAgentStateRecord]
    ) {
        var current = tab.codexAgentBadges
        for paneID in tab.splitTree.allLeafIDs() {
            if let record = byPaneID[paneID], let badge = makeBadge(from: record) {
                // Drop out-of-order async updates.
                if let existing = current[paneID], existing.updatedAt > badge.updatedAt {
                    continue
                }
                if current[paneID] != badge {
                    current[paneID] = badge
                }
            } else if current[paneID] != nil {
                current[paneID] = nil
            }
        }
        let leaves = Set(tab.splitTree.allLeafIDs())
        for stale in current.keys where !leaves.contains(stale) {
            current[stale] = nil
        }
        if tab.codexAgentBadges != current {
            tab.codexAgentBadges = current
        }
        applyCodexTitle(&tab, badges: current)
    }

    /// Name the tab after the Codex conversation's opening prompt.
    /// Codex emits no auto-title and Limpid suppresses its OSC 2 pwd
    /// title, so the pane's `firstPrompt` is the only meaningful label
    /// this pane produces. We write `tab.title` (not `titleOverride`,
    /// which belongs to the user's manual rename and still wins via
    /// `displayTitle`).
    ///
    /// Only the pane whose Codex/Claude session started most recently
    /// (`Tab.latestAgentSessionPaneID`) is allowed to push a title —
    /// without this guard, an older session typing another turn would
    /// re-emit its own `firstPrompt` and clobber a newer pane's label.
    /// When that owner pane is Claude (or no agent at all), we leave
    /// the Codex side alone: Claude's hook drives OSC 2 directly.
    private func applyCodexTitle(_ tab: inout Tab, badges: [UUID: CodexAgentBadge]) {
        guard let owner = tab.latestAgentSessionPaneID,
              let prompt = badges[owner]?.firstPrompt,
              !prompt.isEmpty,
              tab.title != prompt
        else { return }
        tab.title = prompt
    }

    private func markCurrentlyFocusedViewed(session: WindowSession) {
        // Skip on the bootstrap pass: a restored finished pane mustn't
        // be silently marked viewed (the user hasn't actually seen it
        // this run yet).
        guard hasBootstrapped,
              let triage,
              let activeTabID = session.activeTabID,
              let tab = session.tab(activeTabID),
              let paneID = tab.splitTree.focusedLeafID
        else { return }
        triage.markViewed(paneID: paneID, in: session)
    }

    /// Diff every leaf's prior badge against its current badge and
    /// hand the transition to `AgentNotificationEmitter`. See the
    /// emitter file header for the per-transition rules — Claude and
    /// Codex use the exact same logic now, only the localized titles
    /// differ.
    private func emitFinishedNotifications(session: WindowSession) {
        guard let notificationManager else { return }
        let emitter = AgentNotificationEmitter(
            kind: .codex,
            notificationManager: notificationManager
        )
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let current = tab.codexAgentBadges[paneID] else { continue }
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
        var next: [UUID: CodexAgentBadge] = [:]
        for tab in session.tabs {
            for (paneID, badge) in tab.codexAgentBadges {
                next[paneID] = badge
            }
        }
        previousBadges = next
    }

    private func makeBadge(from record: CodexAgentStateRecord) -> CodexAgentBadge? {
        guard let state = AgentState(rawValue: record.state) else { return nil }
        let detail = (record.detail?.isEmpty == false) ? record.detail : nil
        let updatedAt = Self.parseISO8601(record.updatedAt) ?? Date()
        let lastPrompt = (record.lastPrompt?.isEmpty == false) ? record.lastPrompt : nil
        let firstPrompt = (record.firstPrompt?.isEmpty == false) ? record.firstPrompt : nil
        return CodexAgentBadge(
            state: state,
            detail: detail,
            runStartedAt: Self.parseOptionalDate(record.runStartedAt),
            contextTokens: record.contextTokens,
            updatedAt: updatedAt,
            lastPrompt: lastPrompt,
            firstPrompt: firstPrompt,
            sessionStartedAt: Self.parseOptionalDate(record.sessionStartedAt)
        )
    }

    /// Parse an optional ISO-8601 string from a hook record. Empty
    /// strings (`runStartedAt=""` on a reset) become `nil` so callers
    /// don't have to repeat the empty-vs-missing check inline.
    private static func parseOptionalDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return parseISO8601(raw)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
