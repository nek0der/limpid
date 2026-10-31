// PlanUsageRecordsTests.swift
// Weir — the usage directory the status line relay writes into: reading a record, and noticing a new one.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Plan usage records")
struct PlanUsageRecordsTests {
    @Test("reads an agent's record from the usage directory, and nothing before one")
    func record_readsTheFile() throws {
        try withTempDir { dir in
            let records = PlanUsageRecordDirectory(directory: dir)
            #expect(records.record(for: .claude) == nil)
            let record = #"{"windows":[{"kind":"five_hour","usedPercent":81}],"observedAt":"2026-10-29T02:13:20Z"}"#
            try Data(record.utf8).write(to: PlanUsageRecordDirectory.recordURL(for: .claude, in: dir))
            #expect(records.record(for: .claude)?.windows.first?.usedPercent == 81)
            try Data("not json".utf8).write(to: PlanUsageRecordDirectory.recordURL(for: .claude, in: dir))
            #expect(records.record(for: .claude) == nil)
        }
    }

    /// The relay writes through a temporary file and a rename, which is
    /// what the directory watch has to catch.
    @Test("says so when a record is written by rename")
    func watch_seesARenamedRecord() async throws {
        try await withTempDir { dir in
            let records = PlanUsageRecordDirectory(directory: dir)
            var changes = 0
            records.watch { changes += 1 }
            let record = #"{"windows":[],"observedAt":"2026-10-29T02:13:20Z"}"#
            try Data(record.utf8).write(to: PlanUsageRecordDirectory.recordURL(for: .claude, in: dir), options: .atomic)
            // The event and the debounce after it both wait on the main actor,
            // which a parallel run can stall past a short deadline, so only a
            // change never reported should reach this one.
            await pollUntil(timeout: .seconds(30), interval: .milliseconds(20)) { changes > 0 }
            #expect(changes > 0)
        }
    }
}
