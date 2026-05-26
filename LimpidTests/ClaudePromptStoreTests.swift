// ClaudePromptStoreTests.swift
// Limpid — covers the read / write / scan / cleanup pipeline that
// backs the prompt-history sidebar feature. Mirrors
// `ClaudeAgentStateStoreTests` so the per-pane stores keep matching
// invariants (atomic write, paneId match, orphan cleanup, hidden
// file skipping).

import Foundation
import Testing
@testable import Limpid

@Suite("ClaudePromptStore")
struct ClaudePromptStoreTests {
    @Test("save → record(forPaneID:) round-trips every field")
    func save_roundTripsFields() throws {
        try withTempDir { dir in
            let store = ClaudePromptStore(directory: dir)
            let id = UUID()
            let original = ClaudePromptRecord(
                schemaVersion: 1,
                paneId: id.uuidString,
                updatedAt: "2026-05-27T00:00:00Z",
                prompts: [
                    ClaudePromptEntry(index: 0, submittedAt: "2026-05-27T00:00:00Z", text: "Write tests"),
                    ClaudePromptEntry(index: 1, submittedAt: "2026-05-27T00:01:00Z", text: "Run lint"),
                ]
            )
            try store.save(original)
            let loaded = try #require(store.record(forPaneID: id))
            #expect(loaded.schemaVersion == 1)
            #expect(loaded.paneId == id.uuidString)
            #expect(loaded.updatedAt == "2026-05-27T00:00:00Z")
            #expect(loaded.prompts.count == 2)
            #expect(loaded.prompts[0].index == 0)
            #expect(loaded.prompts[0].text == "Write tests")
            #expect(loaded.prompts[1].index == 1)
            #expect(loaded.prompts[1].text == "Run lint")
        }
    }

    @Test("save throws when paneId is not a UUID")
    func save_rejectsNonUUIDPaneId() throws {
        try withTempDir { dir in
            let store = ClaudePromptStore(directory: dir)
            let bad = ClaudePromptRecord(
                schemaVersion: 1,
                paneId: "not-a-uuid",
                updatedAt: "2026-05-27T00:00:00Z",
                prompts: []
            )
            #expect(throws: (any Error).self) { try store.save(bad) }
        }
    }

    @Test("allRecords skips hidden tmp / non-UUID / mismatched paneId files")
    func allRecords_skipsBadFiles() throws {
        try withTempDir { dir in
            let store = ClaudePromptStore(directory: dir)
            let good = UUID()
            try store.save(ClaudePromptRecord(
                schemaVersion: 1,
                paneId: good.uuidString,
                updatedAt: "2026-05-27T00:00:00Z",
                prompts: []
            ))

            try Data("garbage".utf8).write(to: dir.appendingPathComponent(".\(UUID().uuidString).prompts.json.tmp"))
            try Data("ok".utf8).write(to: dir.appendingPathComponent("random.prompts.json"))
            try Data("{".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).prompts.json"))

            // paneId mismatched against filename — defense-in-depth check.
            let mismatchedFile = UUID()
            let mismatched = ClaudePromptRecord(
                schemaVersion: 1,
                paneId: UUID().uuidString,
                updatedAt: "2026-05-27T00:00:00Z",
                prompts: []
            )
            let encoder = JSONEncoder()
            let data = try encoder.encode(mismatched)
            try data.write(to: dir.appendingPathComponent("\(mismatchedFile.uuidString).prompts.json"))

            let all = store.allRecords()
            #expect(all.count == 1)
            #expect(all[0].paneId == good.uuidString)
        }
    }

    @Test("delete removes the on-disk file and is idempotent")
    func delete_isIdempotent() throws {
        try withTempDir { dir in
            let store = ClaudePromptStore(directory: dir)
            let id = UUID()
            try store.save(ClaudePromptRecord(
                schemaVersion: 1,
                paneId: id.uuidString,
                updatedAt: "2026-05-27T00:00:00Z",
                prompts: []
            ))
            #expect(store.record(forPaneID: id) != nil)
            store.delete(paneID: id)
            #expect(store.record(forPaneID: id) == nil)
            // Second delete on a missing record must not throw.
            store.delete(paneID: id)
        }
    }

    @Test("cleanup drops records whose pane is no longer alive")
    func cleanup_dropsOrphans() throws {
        try withTempDir { dir in
            let store = ClaudePromptStore(directory: dir)
            let alive = UUID()
            let orphan = UUID()
            for id in [alive, orphan] {
                try store.save(ClaudePromptRecord(
                    schemaVersion: 1,
                    paneId: id.uuidString,
                    updatedAt: "2026-05-27T00:00:00Z",
                    prompts: []
                ))
            }
            store.cleanup(keeping: [alive])
            #expect(store.record(forPaneID: alive) != nil)
            #expect(store.record(forPaneID: orphan) == nil)
        }
    }

    @Test("cleanup caps survivors at maxRecords by mtime")
    func cleanup_capsAtMaxRecords() throws {
        try withTempDir { dir in
            let store = ClaudePromptStore(directory: dir, maxRecords: 2)
            var ids: [UUID] = []
            for i in 0..<5 {
                let id = UUID()
                ids.append(id)
                try store.save(ClaudePromptRecord(
                    schemaVersion: 1,
                    paneId: id.uuidString,
                    updatedAt: "2026-05-27T00:00:0\(i)Z",
                    prompts: []
                ))
                // Force distinct mtimes so the "newest 2 win" sort is
                // deterministic. `utimensat` semantics: pass via
                // setAttributes on the file URL.
                let url = dir.appendingPathComponent("\(id.uuidString).prompts.json")
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(TimeInterval(i))],
                    ofItemAtPath: url.path
                )
            }
            // Treat everything as "alive" so cleanup only trims by cap.
            store.cleanup(keeping: Set(ids))
            let surviving = store.allRecords().map(\.paneId)
            #expect(surviving.count == 2)
            // Newest two are the last two we wrote (ids[3], ids[4]).
            #expect(Set(surviving) == Set([ids[3].uuidString, ids[4].uuidString]))
        }
    }
}
