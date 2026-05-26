// ClaudeSessionTracker.swift
// Limpid — orchestrates Claude Code session resume across app
// restarts. On launch, scans `ClaudeSessionStore` for records written
// by the shim's hook on the previous run, reflects each surviving
// entry into the matching `Tab.claudeSessions[paneID]`, then drops
// orphan records whose pane no longer exists. On pane / tab close,
// removes the on-disk record so a later launch doesn't try to resume
// a closed conversation.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.session.tracker")

@MainActor
final class ClaudeSessionTracker {
    private let store: ClaudeSessionStore

    init(store: ClaudeSessionStore = ClaudeSessionStore()) {
        self.store = store
    }

    /// Re-sync every pane's `ClaudeSessionInfo` with the on-disk
    /// session records. The disk side is the authority — the
    /// `Tab.claudeSessions` map in `state.json` is just a cached
    /// mirror. Called once per launch after `SessionStore` has
    /// restored the snapshot.
    ///
    /// Without the explicit "no record → clear" step, a pane whose
    /// previous SessionEnd hook deleted the record would still carry
    /// the old session id from `state.json` and the auto-resume
    /// builder would launch `claude --resume <id>` even though the
    /// user explicitly exited the conversation.
    func bootstrap(into session: WindowSession) {
        let records = store.allRecords()

        // Map every pane (split leaf) to its owning Tab so we can
        // reflect records and clean up orphans in one pass.
        var paneToTab: [UUID: UUID] = [:]
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                paneToTab[paneID] = tab.id
            }
        }
        let alivePaneIDs = Set(paneToTab.keys)

        // Index records by paneID for O(1) lookup.
        var byPaneID: [UUID: ClaudeSessionRecord] = [:]
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
                var current = mutTab.claudeSessions
                for paneID in mutTab.splitTree.allLeafIDs() {
                    if let record = byPaneID[paneID] {
                        let cwd: String? = record.cwd.isEmpty ? nil : record.cwd
                        let next = ClaudeSessionInfo(sessionId: record.sessionId, cwd: cwd)
                        if current[paneID] != next {
                            current[paneID] = next
                        }
                        applied += 1
                    } else if current[paneID] != nil {
                        current[paneID] = nil
                        cleared += 1
                    }
                }
                // Drop any stale entries for panes that no longer
                // exist in this tab's split tree (e.g. closed pane).
                let liveLeaves = Set(mutTab.splitTree.allLeafIDs())
                for staleID in current.keys where !liveLeaves.contains(staleID) {
                    current[staleID] = nil
                }
                if mutTab.claudeSessions != current {
                    mutTab.claudeSessions = current
                }
            }
        }

        store.cleanup(keeping: alivePaneIDs)
        log.notice(
            "bootstrap applied=\(applied) cleared=\(cleared) records=\(records.count)"
        )
    }

    /// Drop the on-disk record for a pane that has been closed for
    /// good. Idempotent — safe to call even when no record ever
    /// existed.
    func didClosePane(_ paneID: UUID) {
        store.delete(paneID: paneID)
    }
}
