// ClaudeAgentStateStoreTests.swift
// Limpid — covers the read / write / scan / cleanup pipeline that
// backs the agent-state visualisation feature. Mirrors the
// `ClaudeSessionStoreTests` shape so the per-pane record stores keep
// matching invariants (atomic write, paneId match, orphan cleanup).

import Foundation
import Testing
@testable import Limpid

@Suite("ClaudeAgentStateStore")
struct ClaudeAgentStateStoreTests {
    @Test("save → record(forPaneID:) round-trips every field")
    func save_roundTripsFields() throws {
        try withTempDir { dir in
            let store = ClaudeAgentStateStore(directory: dir)
            let id = UUID()
            let original = ClaudeAgentStateRecord(
                schemaVersion: 1,
                paneId: id.uuidString,
                state: "running",
                detail: "Edit",
                runStartedAt: "2026-05-26T00:00:00Z",
                updatedAt: "2026-05-26T00:00:01Z",
                lastHookEvent: "PreToolUse",
                contextTokens: 42000,
                pid: "12345",
                lastPrompt: "Add tests"
            )
            try store.save(original)
            #expect(store.record(forPaneID: id) == original)
        }
    }

    @Test("save throws when paneId is not a UUID")
    func save_rejectsNonUUIDPaneId() throws {
        try withTempDir { dir in
            let store = ClaudeAgentStateStore(directory: dir)
            let bad = ClaudeAgentStateRecord(
                schemaVersion: 1,
                paneId: "not-a-uuid",
                state: "idle",
                detail: nil,
                runStartedAt: nil,
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil,
                contextTokens: nil,
                pid: nil,
                lastPrompt: nil
            )
            #expect(throws: (any Error).self) { try store.save(bad) }
        }
    }

    @Test("allRecords skips hidden tmp / non-UUID / mismatched paneId files")
    func allRecords_skipsBadFiles() throws {
        try withTempDir { dir in
            let store = ClaudeAgentStateStore(directory: dir)
            let good = UUID()
            try store.save(ClaudeAgentStateRecord(
                schemaVersion: 1,
                paneId: good.uuidString,
                state: "idle",
                detail: nil,
                runStartedAt: nil,
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil,
                contextTokens: nil,
                pid: nil,
                lastPrompt: nil
            ))

            try Data("garbage".utf8).write(to: dir.appendingPathComponent(".\(UUID().uuidString).state.json.tmp"))
            try Data("ok".utf8).write(to: dir.appendingPathComponent("random.state.json"))
            try Data("{".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).state.json"))
            // paneId mismatched against filename — defense-in-depth check.
            let mismatchedFile = UUID()
            let mismatched = ClaudeAgentStateRecord(
                schemaVersion: 1,
                paneId: UUID().uuidString,
                state: "idle",
                detail: nil,
                runStartedAt: nil,
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil,
                contextTokens: nil,
                pid: nil,
                lastPrompt: nil
            )
            try Data(JSONEncoder().encode(mismatched)).write(
                to: dir.appendingPathComponent("\(mismatchedFile.uuidString).state.json")
            )

            let recs = store.allRecords()
            #expect(recs.count == 1)
            #expect(recs.first?.paneId == good.uuidString)
        }
    }

    @Test("delete removes the on-disk file and is idempotent on a missing one")
    func delete_isIdempotent() throws {
        try withTempDir { dir in
            let store = ClaudeAgentStateStore(directory: dir)
            let id = UUID()
            try store.save(ClaudeAgentStateRecord(
                schemaVersion: 1,
                paneId: id.uuidString,
                state: "idle",
                detail: nil,
                runStartedAt: nil,
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil,
                contextTokens: nil,
                pid: nil,
                lastPrompt: nil
            ))
            #expect(store.record(forPaneID: id) != nil)
            store.delete(paneID: id)
            #expect(store.record(forPaneID: id) == nil)
            store.delete(paneID: id)
        }
    }

    @Test("cleanup drops records whose pane is gone")
    func cleanup_dropsOrphans() throws {
        try withTempDir { dir in
            let store = ClaudeAgentStateStore(directory: dir)
            let live = UUID()
            let orphan = UUID()
            for id in [live, orphan] {
                try store.save(ClaudeAgentStateRecord(
                    schemaVersion: 1,
                    paneId: id.uuidString,
                    state: "idle",
                    detail: nil,
                    runStartedAt: nil,
                    updatedAt: "2026-05-26T00:00:00Z",
                    lastHookEvent: nil,
                    contextTokens: nil,
                    pid: nil,
                    lastPrompt: nil
                ))
            }
            store.cleanup(keeping: [live])
            #expect(store.record(forPaneID: live) != nil)
            #expect(store.record(forPaneID: orphan) == nil)
        }
    }
}
