// ClaudePromptTracker.swift
// Limpid — keeps `Tab.claudePrompts` in sync with the per-pane
// `<paneID>.prompts.json` files written by `claude-shim/limpid-hook`
// on every `UserPromptSubmit`. On launch we boot from disk; while
// the app is running we watch the prompts directory with
// `DispatchSource.makeFileSystemObjectSource` so the sidebar's
// `@Observable` view reflects the on-disk record within a few
// hundred milliseconds.
//
// Simpler than `ClaudeAgentStateTracker`:
//   - no PID sweep (prompts persist even after claude exits — the
//     sidebar still shows the history)
//   - no notification firing (prompts are passive UI, not events)
//   - no priority diff (the prompts array is monotonic — additions
//     only — so we just replace the slot when the on-disk
//     `updatedAt` is newer)

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.prompt.tracker")

@MainActor
final class ClaudePromptTracker {
    private let store: ClaudePromptStore
    private weak var session: WindowSession?

    /// `nonisolated(unsafe)` so the nonisolated `deinit` can cancel
    /// the dispatch source / close the fd. Mutation is confined to
    /// MainActor methods so there is no real concurrent access.
    private nonisolated(unsafe) var dirSource: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var dirFD: Int32 = -1

    init(store: ClaudePromptStore = ClaudePromptStore()) {
        self.store = store
    }

    deinit {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Bootstrap

    /// Sync every alive pane's prompt history against the on-disk
    /// records, then arm the directory watcher. Called once per
    /// launch after `SessionStore` has restored the snapshot.
    func bootstrap(into session: WindowSession) {
        self.session = session
        applyAllRecordsToSession()
        startDirectoryWatch()
    }

    /// Drop the on-disk record for a pane that has been closed for
    /// good. Idempotent.
    func didClosePane(_ paneID: UUID) {
        store.delete(paneID: paneID)
        session?.applyAcrossTabs { tab in
            if tab.claudePrompts[paneID] != nil {
                tab.claudePrompts[paneID] = nil
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

    // MARK: - Apply records to session

    private func applyAllRecordsToSession() {
        guard let session else { return }
        let records = store.allRecords()
        var byPaneID: [UUID: ClaudePromptRecord] = [:]
        byPaneID.reserveCapacity(records.count)
        for record in records {
            guard let id = UUID(uuidString: record.paneId) else { continue }
            byPaneID[id] = record
        }

        for tab in session.tabs {
            session.update(tab.id) { mutTab in
                var current = mutTab.claudePrompts
                for paneID in mutTab.splitTree.allLeafIDs() {
                    if let record = byPaneID[paneID] {
                        // The prompts array is monotonic (UserPromptSubmit
                        // only ever appends), so a length difference is
                        // sufficient to detect a meaningful change. Skip
                        // the dictionary write otherwise to avoid spurious
                        // SwiftUI rebuilds.
                        let incoming = record.prompts
                        let existing = current[paneID] ?? []
                        if incoming.count != existing.count {
                            current[paneID] = incoming
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
                if mutTab.claudePrompts != current {
                    mutTab.claudePrompts = current
                }
            }
        }
    }
}
