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
        notificationManager: LimpidNotificationManager? = nil
    ) {
        self.session = session
        self.notificationManager = notificationManager
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

        store.cleanup(keeping: alive)
    }

    /// Compare `previousBadges` against the current session state and
    /// fire macOS notifications on meaningful state transitions:
    ///
    /// - `(running|compacting) → idle` → "Claude finished" with the
    ///   last user prompt as body.
    /// - `(running|compacting|unknown) → needsInput` → "Claude needs
    ///   input" with the permission / question text as body. The
    ///   generic OSC 9 "Claude is waiting for your input" that Claude
    ///   emits in parallel is suppressed inside
    ///   `GhosttyEventCoordinator.handleDesktopNotification` while the
    ///   pane carries a fresh `.needsInput` badge.
    ///
    /// The `.error` state already shows a red icon and a sound-less
    /// `StopFailure` is best surfaced via the icon — we don't fire a
    /// banner there to avoid duplicating with Anthropic's own rate-
    /// limit / billing dialogs.
    private func emitFinishedNotifications(session: WindowSession) {
        guard let notificationManager else { return }
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let current = tab.claudeAgentBadges[paneID] else { continue }
                let previous = previousBadges[paneID]
                // Detect running → needsInput transitions before
                // running → idle so a single tick that walks both
                // states still fires the right notification.
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
                // Use the container label (project / worktree path) as
                // the notification title — `tab.displayTitle` tends to
                // be "Claude Code" because Claude itself sets the OSC 0
                // title, so it carries no signal. Fall back to a
                // generic "Claude finished" string for loose tabs
                // without a meaningful container.
                let containerLabel = session.containerLabel(for: tab.container)
                let title: String = if containerLabel.isEmpty {
                    String(localized: "Claude finished")
                } else {
                    containerLabel
                }
                // Body uses the user's own prompt so they instantly
                // recognise which request just completed. Truncate to
                // ~80 chars and collapse whitespace; the macOS banner
                // only shows a few lines anyway.
                let body: String = if let prompt = previous.lastPrompt,
                                      let cleaned = truncatedPrompt(prompt)
                {
                    cleaned
                } else {
                    String(localized: "Claude finished")
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

    /// Fire the macOS "Claude needs input" banner. Body prefers the
    /// hook's `detail` (permission message text or AskUserQuestion's
    /// question) and falls back to the user's last prompt when that
    /// was sanitised away — at least the user can tell *which* prompt
    /// is blocked. If even that's empty, drop to a generic string.
    private func emitNeedsInputNotification(
        tab: Tab,
        paneID: UUID,
        badge: ClaudeAgentBadge,
        session: WindowSession,
        notificationManager: LimpidNotificationManager
    ) {
        let containerLabel = session.containerLabel(for: tab.container)
        let title: String = if containerLabel.isEmpty {
            String(localized: "Claude needs input")
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
            return String(localized: "Claude needs input")
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

    /// Match the OSC 9 / 777 path's "only flag unread when the user
    /// isn't already watching the pane" rule. We can't reach the
    /// underlying `SurfaceView` from here, so we approximate by
    /// checking the model's active tab + focused leaf + whether the
    /// app is the key window. Close enough: when the user is staring
    /// at a different tab or another app, we mark unread; when they
    /// are looking at this exact pane, we leave the bell alone.
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

    /// Trim leading / trailing whitespace, collapse runs of inner
    /// whitespace to a single space, and clip the result to ~80
    /// characters with an ellipsis. Returns `nil` if nothing usable
    /// remains so callers fall back to a generic notification body.
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
        var next: [UUID: ClaudeAgentBadge] = [:]
        for tab in session.tabs {
            for (paneID, badge) in tab.claudeAgentBadges {
                next[paneID] = badge
            }
        }
        previousBadges = next
    }

    private func makeBadge(from record: ClaudeAgentStateRecord) -> ClaudeAgentBadge? {
        guard let state = ClaudeAgentState(rawValue: record.state) else { return nil }
        let detail = (record.detail?.isEmpty == false) ? record.detail : nil
        let updatedAt = parseISO8601(record.updatedAt) ?? Date()
        let runStartedAt: Date? = if let raw = record.runStartedAt, !raw.isEmpty {
            parseISO8601(raw)
        } else {
            nil
        }
        let lastPrompt = (record.lastPrompt?.isEmpty == false) ? record.lastPrompt : nil
        return ClaudeAgentBadge(
            state: state,
            detail: detail,
            runStartedAt: runStartedAt,
            contextTokens: record.contextTokens,
            updatedAt: updatedAt,
            lastPrompt: lastPrompt
        )
    }

    private func parseISO8601(_ string: String) -> Date? {
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
