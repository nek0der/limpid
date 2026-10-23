// CwdEventProjectionTests.swift
// Limpid — the host's half of the cwd events behind the worktree-move banner.
//
// Which moves are reported, and when, is the Rust rules' and is tested in
// `events.rs`. These check what the host adds: a reported move reaches
// `onCwdChanged`, and the files the rules sweep are removed from disk.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("CwdEventProjection")
struct CwdEventProjectionTests {
    private struct Harness {
        let adapter: AgentProjectionAdapter
        let session: WorkspaceSession
        let pane: UUID
        let events: URL
        /// Every cwd change the projection reported, in order.
        let moves: Recorded<[(pane: UUID, newCwd: String)]>
    }

    private func harness(in root: URL) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let events = root.appendingPathComponent("cwd-events", isDirectory: true)
        for directory in [state, sessions, events] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let adapter = ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            cwdEvents: events,
            processStatus: { _ in .dead }
        )
        let moves = Recorded<[(pane: UUID, newCwd: String)]>([])
        adapter.onCwdChanged = { pane, newCwd, _ in moves.update { $0.append((pane, newCwd)) } }
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
            .write(to: harness.events.appendingPathComponent(AgentRecordFixtures.cwdEventFileName(pane.uuidString)))
    }

    private func exists(_ harness: Harness, pane: UUID) throws -> Bool {
        try FileManager.default.fileExists(
            atPath: harness.events.appendingPathComponent(AgentRecordFixtures.cwdEventFileName(pane.uuidString)).path
        )
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

    @Test("a pass drops the files of panes that are no longer open")
    func scan_cleansUpRecordsForClosedPanes() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            let closed = UUID()
            try write(harness, pane: closed, updatedAt: "2026-09-14T12:00:00Z")
            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:00:00Z")

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            #expect(try !exists(harness, pane: closed))
            #expect(try exists(harness, pane: harness.pane))
        }
    }
}
