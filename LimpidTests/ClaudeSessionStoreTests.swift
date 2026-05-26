// ClaudeSessionStoreTests.swift
// Limpid — verifies the read / write / scan / cleanup pipeline that
// backs the Claude Code resume feature. All tests inject a temp dir
// via `init(directory:)` so a missed `WithTempDir` would still land
// in `Limpid Tests Stray/`, not the user's real data.

import Foundation
import Testing
@testable import Limpid

@Suite("ClaudeSessionStore")
struct ClaudeSessionStoreTests {
    @Test("save → record(forPaneID:) round-trips every field")
    func save_andRecord_roundtripsFields() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let id = UUID()
            let original = ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: id.uuidString,
                sessionId: "abc-123",
                cwd: "/tmp/repo",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: "SessionStart"
            )
            try store.save(original)

            let loaded = store.record(forPaneID: id)
            #expect(loaded == original)
        }
    }

    @Test("save throws when paneId is not a UUID")
    func save_rejectsNonUUIDPaneId() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let bad = ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: "not-a-uuid",
                sessionId: "x",
                cwd: "/tmp",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil
            )
            #expect(throws: (any Error).self) {
                try store.save(bad)
            }
        }
    }

    @Test("allRecords skips hidden tmp / non-UUID / malformed / paneId-mismatch files")
    func allRecords_skipsBadFiles() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let goodID = UUID()
            try store.save(ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: goodID.uuidString,
                sessionId: "ok",
                cwd: "/tmp",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil
            ))

            // Files that should be ignored on scan:
            // - hidden tmp from a hook in flight
            // - non-UUID stem
            // - well-formed UUID stem but malformed JSON
            // - UUID stem with mismatched paneId in payload
            try Data("garbage".utf8).write(to: dir.appendingPathComponent(".\(UUID().uuidString).json.tmp"))
            try Data("ok".utf8).write(to: dir.appendingPathComponent("random.json"))
            try Data("{".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
            let mismatchedID = UUID()
            let mismatched = ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: UUID().uuidString,
                sessionId: "x",
                cwd: "/tmp",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil
            )
            try Data(JSONEncoder().encode(mismatched)).write(
                to: dir.appendingPathComponent("\(mismatchedID.uuidString).json")
            )

            let recs = store.allRecords()
            #expect(recs.count == 1)
            #expect(recs.first?.paneId == goodID.uuidString)
        }
    }

    @Test("delete removes the on-disk file and is idempotent on a missing one")
    func delete_removesFileAndIsIdempotent() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let id = UUID()
            try store.save(ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: id.uuidString,
                sessionId: "x",
                cwd: "/tmp",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil
            ))
            #expect(store.record(forPaneID: id) != nil)
            store.delete(paneID: id)
            #expect(store.record(forPaneID: id) == nil)
            // Idempotent: deleting again is a no-op, not a throw.
            store.delete(paneID: id)
        }
    }

    @Test("cleanup drops records whose pane is gone")
    func cleanup_dropsOrphanRecords() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let live = UUID()
            let orphan = UUID()
            for id in [live, orphan] {
                try store.save(ClaudeSessionRecord(
                    schemaVersion: 1,
                    paneId: id.uuidString,
                    sessionId: "x",
                    cwd: "/tmp",
                    updatedAt: "2026-05-26T00:00:00Z",
                    lastHookEvent: nil
                ))
            }
            store.cleanup(keeping: [live])
            #expect(store.record(forPaneID: live) != nil)
            #expect(store.record(forPaneID: orphan) == nil)
        }
    }

    @Test("cleanup caps the surviving set at maxRecords (newest by mtime wins)")
    func cleanup_capsAtMaxRecordsKeepingNewest() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir, maxRecords: 2)
            var ids: [UUID] = []
            for _ in 0..<4 {
                let id = UUID()
                ids.append(id)
                try store.save(ClaudeSessionRecord(
                    schemaVersion: 1,
                    paneId: id.uuidString,
                    sessionId: "x",
                    cwd: "/tmp",
                    updatedAt: "2026-05-26T00:00:00Z",
                    lastHookEvent: nil
                ))
                // Force a measurable mtime gap so the cleanup pass can
                // pick a deterministic "newest first" ordering.
                let url = dir.appendingPathComponent("\(id.uuidString).json")
                let now = Date()
                try FileManager.default.setAttributes(
                    [.modificationDate: now],
                    ofItemAtPath: url.path
                )
                Thread.sleep(forTimeInterval: 0.01)
            }
            store.cleanup(keeping: Set(ids))
            let remaining = store.allRecords().compactMap { UUID(uuidString: $0.paneId) }
            #expect(remaining.count == 2)
            // Newest two = the last two we saved.
            #expect(Set(remaining) == Set(ids.suffix(2)))
        }
    }
}
