// CodexSessionTracker.swift
// Limpid — orchestrates Codex session resume across app restarts.
// Mirror of `ClaudeSessionTracker`: on launch, scans `CodexSessionStore`
// for records written by the hook on the previous run, reflects each
// surviving entry into the matching `Tab.codexSessions[paneID]`, then
// drops orphan records whose pane no longer exists.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "codex.session.tracker")

@MainActor
final class CodexSessionTracker {
    private let store: CodexSessionStore

    init(store: CodexSessionStore = CodexSessionStore()) {
        self.store = store
    }

    /// Re-sync every pane's `CodexSessionInfo` with the on-disk
    /// session records. Disk is the authority; `Tab.codexSessions` in
    /// `state.json` is just a cached mirror.
    func bootstrap(into session: WindowSession) {
        let records = store.allRecords()

        var paneToTab: [UUID: UUID] = [:]
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                paneToTab[paneID] = tab.id
            }
        }
        let alivePaneIDs = Set(paneToTab.keys)

        var byPaneID: [UUID: CodexSessionRecord] = [:]
        byPaneID.reserveCapacity(records.count)
        for record in records {
            guard let id = UUID(uuidString: record.paneId) else { continue }
            byPaneID[id] = record
        }

        var applied = 0
        var cleared = 0
        for tab in session.tabs {
            let tabID = tab.id
            session.update(tabID) { mutTab in
                var current = mutTab.codexSessions
                for paneID in mutTab.splitTree.allLeafIDs() {
                    if let record = byPaneID[paneID] {
                        let cwd: String? = record.cwd.isEmpty ? nil : record.cwd
                        let next = CodexSessionInfo(sessionId: record.sessionId, cwd: cwd)
                        if current[paneID] != next {
                            current[paneID] = next
                        }
                        applied += 1
                    } else if current[paneID] != nil {
                        current[paneID] = nil
                        cleared += 1
                    }
                }
                let liveLeaves = Set(mutTab.splitTree.allLeafIDs())
                for staleID in current.keys where !liveLeaves.contains(staleID) {
                    current[staleID] = nil
                }
                if mutTab.codexSessions != current {
                    mutTab.codexSessions = current
                }
            }
        }

        store.cleanup(keeping: alivePaneIDs)
        log.notice(
            "bootstrap applied=\(applied) cleared=\(cleared) records=\(records.count)"
        )
    }

    /// Drop the on-disk record for a pane that has been closed for
    /// good. Idempotent.
    func didClosePane(_ paneID: UUID) {
        store.delete(paneID: paneID)
    }
}
