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
        notificationManager: LimpidNotificationManager? = nil
    ) {
        self.session = session
        self.notificationManager = notificationManager
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
                var current = mutTab.codexAgentBadges
                for paneID in mutTab.splitTree.allLeafIDs() {
                    if let record = byPaneID[paneID],
                       let badge = makeBadge(from: record)
                    {
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
                let leaves = Set(mutTab.splitTree.allLeafIDs())
                for stale in current.keys where !leaves.contains(stale) {
                    current[stale] = nil
                }
                if mutTab.codexAgentBadges != current {
                    mutTab.codexAgentBadges = current
                }
            }
        }

        if hasBootstrapped {
            emitFinishedNotifications(session: session)
        }
        rebuildPreviousBadges(session: session)

        store.cleanup(keeping: alive)
    }

    private func emitFinishedNotifications(session: WindowSession) {
        guard let notificationManager else { return }
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let current = tab.codexAgentBadges[paneID] else { continue }
                let previous = previousBadges[paneID]
                if current.state == .needsInput,
                   previous?.state != .needsInput
                {
                    emitNeedsInputNotification(
                        tab: tab,
                        paneID: paneID,
                        badge: current,
                        session: session,
                        notificationManager: notificationManager
                    )
                    continue
                }
                guard current.state == .idle else { continue }
                guard let previous else { continue }
                guard previous.state == .running || previous.state == .compacting else {
                    continue
                }
                let containerLabel = session.containerLabel(for: tab.container)
                let title: String = if containerLabel.isEmpty {
                    String(localized: "Codex finished")
                } else {
                    containerLabel
                }
                let body: String = if let prompt = previous.lastPrompt,
                                      let cleaned = truncatedPrompt(prompt)
                {
                    cleaned
                } else {
                    String(localized: "Codex finished")
                }
                notificationManager.send(
                    title: title,
                    body: body,
                    paneID: paneID,
                    tabID: tab.id,
                    containerID: tab.container,
                    requireFocus: true,
                    kind: .desktop,
                    tabTitleSnapshot: tab.displayTitle,
                    containerLabel: containerLabel
                )
                markUnreadUnlessFocused(
                    session: session,
                    tab: tab,
                    paneID: paneID
                )
            }
        }
    }

    private func emitNeedsInputNotification(
        tab: Tab,
        paneID: UUID,
        badge: CodexAgentBadge,
        session: WindowSession,
        notificationManager: LimpidNotificationManager
    ) {
        let containerLabel = session.containerLabel(for: tab.container)
        let title: String = if containerLabel.isEmpty {
            String(localized: "Codex needs input")
        } else {
            containerLabel
        }
        let body: String = {
            if let detail = badge.detail, let cleaned = truncatedPrompt(detail) {
                return cleaned
            }
            if let prompt = badge.lastPrompt, let cleaned = truncatedPrompt(prompt) {
                return cleaned
            }
            return String(localized: "Codex needs input")
        }()
        notificationManager.send(
            title: title,
            body: body,
            paneID: paneID,
            tabID: tab.id,
            containerID: tab.container,
            requireFocus: true,
            kind: .desktop,
            tabTitleSnapshot: tab.displayTitle,
            containerLabel: containerLabel
        )
        markUnreadUnlessFocused(
            session: session,
            tab: tab,
            paneID: paneID
        )
    }

    private func markUnreadUnlessFocused(
        session: WindowSession,
        tab: Tab,
        paneID: UUID
    ) {
        let isActiveTab = session.activeTabID == tab.id
        let isFocusedLeaf = tab.splitTree.focusedLeafID == paneID
        if isActiveTab,
           isFocusedLeaf,
           LimpidNotificationDelegate.isKeyAndFocused
        {
            return
        }
        session.markUnread(paneID: paneID)
    }

    private func truncatedPrompt(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let limit = 80
        if collapsed.count <= limit { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return collapsed[..<cutoff] + "…"
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
        guard let state = CodexAgentState(rawValue: record.state) else { return nil }
        let detail = (record.detail?.isEmpty == false) ? record.detail : nil
        let updatedAt = Self.parseISO8601(record.updatedAt) ?? Date()
        let runStartedAt: Date? = if let raw = record.runStartedAt, !raw.isEmpty {
            Self.parseISO8601(raw)
        } else {
            nil
        }
        let lastPrompt = (record.lastPrompt?.isEmpty == false) ? record.lastPrompt : nil
        return CodexAgentBadge(
            state: state,
            detail: detail,
            runStartedAt: runStartedAt,
            contextTokens: record.contextTokens,
            updatedAt: updatedAt,
            lastPrompt: lastPrompt
        )
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
