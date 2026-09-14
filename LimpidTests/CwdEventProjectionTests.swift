// CwdEventProjectionTests.swift
// Limpid — the cwd dispatch rules the projection owns.
//
// The cases describe what the worktree-move banner depends on: which cwd
// changes are reported, once, and only for panes that still exist.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("CwdEventProjection")
struct CwdEventProjectionTests {
    private struct Harness {
        let adapter: AgentProjectionAdapter
        let session: WindowSession
        let pane: UUID
        let events: URL
        /// Every cwd change the projection reported, in order.
        let moves: Box<[(pane: UUID, newCwd: String)]>
    }

    /// A reference cell, because the adapter reports through a closure and the
    /// cases need to read what it reported after the fact.
    final class Box<T> {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private func harness(in root: URL) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let events = root.appendingPathComponent("cwd-events", isDirectory: true)
        for directory in [state, sessions, events] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let (session, _, pane) = WindowSessionFixture.withLooseTab()
        let adapter = AgentProjectionAdapter(
            directories: ["claude": AgentDirectories(state: state, sessions: sessions, cwdEvents: events)],
            descriptors: AgentProviderRegistry.descriptors.filter { $0.key == "claude" },
            resumeIntents: AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            ),
            processStatus: { _ in .dead }
        )
        let moves = Box<[(pane: UUID, newCwd: String)]>([])
        adapter.onCwdChanged = { pane, newCwd, _ in moves.value.append((pane, newCwd)) }
        return Harness(adapter: adapter, session: session, pane: pane, events: events, moves: moves)
    }

    private func write(
        _ harness: Harness,
        pane: UUID,
        newCwd: String = "/tmp/after",
        updatedAt: String
    ) throws {
        let record: [String: Any] = [
            "schemaVersion": 1,
            "paneId": pane.uuidString,
            "newCwd": newCwd,
            "oldCwd": "/tmp/before",
            "updatedAt": updatedAt
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: harness.events.appendingPathComponent("\(pane.uuidString).cwd.json"))
    }

    private func exists(_ harness: Harness, pane: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: harness.events.appendingPathComponent("\(pane.uuidString).cwd.json").path
        )
    }

    @Test("the first pass takes note of what is there without reporting it")
    func bootstrap_snapshotsWithoutDispatching() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:00:00Z")

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())
            #expect(harness.moves.value.isEmpty)

            // The note is what suppresses it: another pass over the same record
            // stays silent, so an event from a prior launch never fires.
            harness.adapter.refresh()
            #expect(harness.moves.value.isEmpty)
        }
    }

    @Test("a record with a new timestamp is reported exactly once")
    func freshRecord_dispatchesOnce() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:01:00Z")
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 1)
            #expect(harness.moves.value.first?.newCwd == "/tmp/after")

            // Freshness is the timestamp, not the file: another pass over the
            // same record does nothing even though the file is still there.
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 1)

            try write(harness, pane: harness.pane, newCwd: "/tmp/later", updatedAt: "2026-09-14T12:02:00Z")
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 2)
            #expect(harness.moves.value.last?.newCwd == "/tmp/later")
        }
    }

    @Test("an event for a pane that is gone is consumed, not reported")
    func recordForDeadPane_isSeenButNotDispatched() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            let absent = UUID()
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            try write(harness, pane: absent, updatedAt: "2026-09-14T12:01:00Z")
            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:01:00Z")
            harness.adapter.refresh()

            // Only the live pane's move is worth suggesting; the other pane's
            // event is moot because there is nothing left to move.
            #expect(harness.moves.value.count == 1)
            #expect(harness.moves.value.first?.pane == harness.pane)
            #expect(!exists(harness, pane: absent))
        }
    }

    @Test("a pass drops the files of panes that are no longer open")
    func scan_cleansUpRecordsForClosedPanes() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            let closed = UUID()
            try write(harness, pane: closed, updatedAt: "2026-09-14T12:00:00Z")
            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:00:00Z")

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            #expect(!exists(harness, pane: closed))
            #expect(exists(harness, pane: harness.pane))
        }
    }
}
