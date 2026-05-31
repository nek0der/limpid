// CwdEventTracker.swift
// Limpid — watches the cwd-events directory the shim writes into and
// fires a handler on every fresh `CwdChanged` record. Mirrors the
// shape of `ClaudeAgentStateTracker`: one-shot bootstrap, then a
// `DispatchSource.makeFileSystemObjectSource` directory watch that
// re-scans on every fsevent burst.
//
// On launch we read every existing record and stash its `updatedAt`
// into `seen` so a stale event from a prior run can't trigger a
// suggestion — the user has long since moved past it.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.cwd.event.tracker")

@MainActor
final class CwdEventTracker {
    private let store: CwdEventStore
    private weak var session: WindowSession?
    /// Per-pane `updatedAt` we've already routed to the handler. Used
    /// to skip records we've seen on a re-scan; we only fire when the
    /// timestamp differs.
    private var seen: [UUID: String] = [:]
    /// Routed every fresh record. Held strongly because the suggester
    /// is owned by `AppState`, which outlives this tracker.
    private var handler: ((CwdEventRecord) -> Void)?

    /// `nonisolated(unsafe)` so deinit (which is nonisolated under
    /// Swift 6) can read these handles to clean up.
    private nonisolated(unsafe) var dirSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var dirFD: Int32 = -1

    init(store: CwdEventStore = CwdEventStore()) {
        self.store = store
    }

    deinit {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Bootstrap

    /// Snapshot the current on-disk records (so launch doesn't
    /// re-fire stale events) and arm the directory watcher. The
    /// handler receives every record whose `updatedAt` is new
    /// relative to our seen-set — typically one per Claude `cd`.
    func bootstrap(
        into session: WindowSession,
        handler: @escaping (CwdEventRecord) -> Void
    ) {
        self.session = session
        self.handler = handler
        guard !DemoFixture.isDemoActive else { return }
        // Snapshot, but don't dispatch: bootstrap is "I've seen
        // these, don't suggest moves for them". The first real cwd
        // change after launch is the first one that fires.
        for rec in store.allRecords() {
            guard let id = UUID(uuidString: rec.paneId) else { continue }
            seen[id] = rec.updatedAt
        }
        startDirectoryWatch()
    }

    /// Forget the pane's last-seen timestamp when the pane closes so
    /// a new pane reusing the same id (rare but possible across a
    /// restore) sees a clean slate. The store-level file is dropped
    /// here too. Wired from `TabActions.closeTab` for parity with the
    /// session trackers; the per-scan sweep below catches anything
    /// closed outside that path.
    func didClosePane(_ paneID: UUID) {
        seen[paneID] = nil
        store.delete(paneID: paneID)
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
            self?.scanAndDispatch()
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

    private func scanAndDispatch() {
        let records = store.allRecords()
        // Build alive set so cleanup can drop records for panes that
        // closed across a launch. Same cleanup contract as the agent
        // tracker's apply pass.
        var alive: Set<UUID> = []
        if let session {
            for tab in session.tabs {
                for paneID in tab.splitTree.allLeafIDs() {
                    alive.insert(paneID)
                }
            }
        }
        for rec in records {
            guard let id = UUID(uuidString: rec.paneId) else { continue }
            if seen[id] == rec.updatedAt { continue }
            seen[id] = rec.updatedAt
            // Don't suggest for panes that no longer exist; the
            // event is moot.
            guard alive.contains(id) else { continue }
            handler?(rec)
        }
        store.cleanup(keeping: alive)
        // Drop seen entries for panes that closed without going
        // through `didClosePane` (e.g. window-level close paths that
        // don't thread the tracker through). Pure in-memory hygiene —
        // the on-disk side is already covered by `store.cleanup`.
        seen = seen.filter { alive.contains($0.key) }
    }
}
