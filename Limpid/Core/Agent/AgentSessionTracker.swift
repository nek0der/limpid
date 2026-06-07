// AgentSessionTracker.swift
// Limpid — generic resume orchestrator for any `AgentSpec` flavour.
// Collapsed `ClaudeSessionTracker` and `CodexSessionTracker` (which
// were ~95% identical) into one parameterised class. On launch, scans
// the per-pane `PaneStore<S.SessionRecord>` for records written by
// the shim, reflects each surviving entry into the matching dict on
// the owning Tab (via `S.sessionsKeyPath`), then drops orphan records
// whose pane no longer exists. On pane / tab close, removes the
// on-disk record so a later launch doesn't try to resume a closed
// conversation.

import Foundation
import OSLog

@MainActor
final class AgentSessionTracker<S: AgentSpec> {
    typealias Store = PaneStore<S.SessionRecord>

    private let store: Store
    private let log: Logger

    init(store: Store) {
        self.store = store
        self.log = Logger.limpid("\(S.label).session.tracker")
    }

    /// Re-sync every pane's `AgentSessionInfo` with the on-disk
    /// session records. Disk is the authority; the cached mirror on
    /// `Tab` is just there so a launch without disk access still gets
    /// a best-effort resume command.
    ///
    /// Without the explicit "no record → clear" step, a pane whose
    /// previous SessionEnd hook deleted the record would still carry
    /// the old session id from `state.json` and the auto-resume
    /// builder would launch `claude --resume <id>` / `codex resume
    /// <id>` even though the user explicitly exited the conversation.
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
        var byPaneID: [UUID: S.SessionRecord] = [:]
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
                var current = mutTab[keyPath: S.sessionsKeyPath]
                // One walk per tab — feed both the per-pane apply
                // loop and the stale-cleanup membership check below.
                let leafIDs = mutTab.splitTree.allLeafIDs()
                for paneID in leafIDs {
                    if let record = byPaneID[paneID],
                       let info = Self.makeSessionInfo(from: record)
                    {
                        if current[paneID] != info {
                            current[paneID] = info
                        }
                        applied += 1
                    } else if current[paneID] != nil {
                        current[paneID] = nil
                        cleared += 1
                    }
                }
                // Drop any stale entries for panes that no longer
                // exist in this tab's split tree.
                let liveLeaves = Set(leafIDs)
                // Snapshot the keys before mutating — `current.keys`
                // is a view onto the dict's buffer; removing entries
                // mid-iteration is undefined.
                let staleIDs = current.keys.filter { !liveLeaves.contains($0) }
                for staleID in staleIDs {
                    current[staleID] = nil
                }
                if mutTab[keyPath: S.sessionsKeyPath] != current {
                    mutTab[keyPath: S.sessionsKeyPath] = current
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

    /// Pull `sessionId` + `cwd` off a session record into the
    /// in-memory `AgentSessionInfo`. Each agent's record carries the
    /// same two fields (the protocol requirement); the projection is
    /// generic over `S.SessionRecord` via runtime reflection on the
    /// record's `paneId` (which `PaneScopedRecord` guarantees) plus
    /// the `sessionId` / `cwd` accessors below.
    private static func makeSessionInfo(from record: S.SessionRecord) -> AgentSessionInfo? {
        // Both `ClaudeSessionRecord` and `CodexSessionRecord` already
        // expose `sessionId: String` + `cwd: String` directly; the
        // protocol layer projects them via Mirror so this generic
        // doesn't need a per-flavour adapter.
        let mirror = Mirror(reflecting: record)
        var sessionId: String?
        var cwd: String?
        for child in mirror.children {
            switch child.label {
            case "sessionId":
                sessionId = child.value as? String
            case "cwd":
                cwd = child.value as? String
            default:
                continue
            }
        }
        guard let sid = sessionId, !sid.isEmpty else { return nil }
        let normalisedCwd: String? = (cwd?.isEmpty ?? true) ? nil : cwd
        return AgentSessionInfo(sessionId: sid, cwd: normalisedCwd)
    }
}
