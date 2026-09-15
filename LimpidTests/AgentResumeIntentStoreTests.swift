// AgentResumeIntentStoreTests.swift
// Limpid — the migration that keeps a restore working across the move of the
// intent directory.
//
// An intent is the only evidence that Limpid killed a run rather than losing
// it, so an intent left behind in the old location is a restore the user was
// promised and silently does not get.

import Foundation
import Testing
@testable import Limpid

@Suite("AgentResumeIntentStore")
struct AgentResumeIntentStoreTests {
    private static let runID = "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2"

    private func intent(runID: String, pid: String) -> AgentResumeIntent {
        AgentResumeIntent(
            runID: runID,
            paneID: UUID(),
            sessionID: "session-\(pid)",
            ownerRunID: nil,
            pid: pid,
            createdAt: Date(timeIntervalSince1970: 1_757_000_000)
        )
    }

    @Test("an intent the previous build left behind is adopted")
    func adoptLegacyIntents_movesTheIntentAndMakesItReadable() throws {
        try withTempDir { root in
            let legacyStore = AgentResumeIntentStore(
                directory: root.appendingPathComponent("legacy", isDirectory: true)
            )
            try legacyStore.save(intent(runID: Self.runID, pid: "4242"))
            let store = AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            )

            store.adoptLegacyIntents(from: legacyStore.directory)

            #expect(store.record(runID: Self.runID)?.pid == "4242")
            #expect(!FileManager.default.fileExists(atPath: legacyStore.directory.path))
        }
    }

    @Test("an intent this build already wrote is not replaced by the old one")
    func adoptLegacyIntents_keepsTheCurrentIntent() throws {
        try withTempDir { root in
            let legacyStore = AgentResumeIntentStore(
                directory: root.appendingPathComponent("legacy", isDirectory: true)
            )
            try legacyStore.save(intent(runID: Self.runID, pid: "1111"))
            let store = AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            )
            try store.save(intent(runID: Self.runID, pid: "2222"))

            store.adoptLegacyIntents(from: legacyStore.directory)

            #expect(store.record(runID: Self.runID)?.pid == "2222")
            // Left where it is: it is still the only copy of what it says, and
            // removing the directory would take it with it.
            #expect(FileManager.default.fileExists(atPath: legacyStore.directory.path))
        }
    }

    @Test("a legacy directory that was never used is nothing to migrate")
    func adoptLegacyIntents_missingDirectory_isANoOp() throws {
        try withTempDir { root in
            let store = AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            )

            store.adoptLegacyIntents(
                from: root.appendingPathComponent("never-there", isDirectory: true)
            )

            #expect(store.allIntents().isEmpty)
        }
    }
}
