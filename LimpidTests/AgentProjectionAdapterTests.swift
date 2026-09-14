// AgentProjectionAdapterTests.swift
// Limpid — what the adapter has to tell the rules, and what it must not.
//
// The rules read only what this process hands them. A field the adapter does
// not fill is not an error on the other side, it is a fact the rules never
// learn, so the cases here are the ones where staying silent would look like
// a decision.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentProjectionAdapter")
struct AgentProjectionAdapterTests {
    private static let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"

    private struct Harness {
        let adapter: AgentProjectionAdapter
        let session: WindowSession
        let state: URL
        let intents: AgentResumeIntentStore
        let recordURL: URL
    }

    /// One pane holding one run whose process is gone, which is the shape the
    /// sweep retires unless something says otherwise.
    private func harness(in root: URL, paneID: UUID) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": paneID.uuidString,
            "runId": Self.run,
            "revision": 4,
            "stateEpisodeToken": "4",
            "state": "finished",
            "updatedAt": "2026-09-14T12:00:00Z",
            "pid": "4242"
        ]
        let recordURL = state.appendingPathComponent("\(Self.run).state.json")
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)

        let intents = AgentResumeIntentStore(
            directory: root.appendingPathComponent("resume-intents", isDirectory: true)
        )
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        let adapter = AgentProjectionAdapter(
            directories: ["claude": AgentDirectories(state: state, sessions: sessions, cwdEvents: nil)],
            descriptors: AgentProviderRegistry.descriptors.filter { $0.key == "claude" },
            resumeIntents: intents,
            processStatus: { _ in .dead }
        )
        return Harness(
            adapter: adapter,
            session: session,
            state: state,
            intents: intents,
            recordURL: recordURL
        )
    }

    @Test("a run an intent has claimed survives the sweep")
    func resumeIntent_keepsTheRecordTheRestoreNeeds() throws {
        try withTempDir { root in
            let paneID = UUID()
            let harness = try harness(in: root, paneID: paneID)
            try harness.intents.save(AgentResumeIntent(
                runID: Self.run,
                paneID: paneID,
                sessionID: "session-1",
                ownerRunID: nil,
                pid: "4242",
                createdAt: Date()
            ))

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            // The intent is the only evidence that Limpid killed this run at
            // quit rather than losing it. Retiring the record now would take
            // away what the restore rebuilds from.
            #expect(harness.adapter.lastFailure == nil)
            #expect(FileManager.default.fileExists(atPath: harness.recordURL.path))
        }
    }

    @Test("the same run with no intent is retired")
    func withoutAnIntent_theDeadRunIsRetired() throws {
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID())

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            // The contrast is the point: without this the case above would
            // pass even if the sweep never ran.
            #expect(harness.adapter.lastFailure == nil)
            #expect(!FileManager.default.fileExists(atPath: harness.recordURL.path))
        }
    }

    @Test("a restored pane keeps the resume hint of a run that crashed")
    func launch_keepsTheHintOfAProviderThatReportsItsOwnEnds() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WindowSessionFixture.withLooseTab()
            let record: [String: Any] = [
                "schemaVersion": 3,
                "paneId": pane.uuidString,
                "runId": Self.run,
                "revision": 4,
                "stateEpisodeToken": "4",
                "state": "running",
                "updatedAt": "2026-09-14T12:00:00Z",
                "pid": "4242"
            ]
            try JSONSerialization.data(withJSONObject: record)
                .write(to: state.appendingPathComponent("\(Self.run).state.json"))
            let hint: [String: Any] = [
                "schemaVersion": 1,
                "paneId": pane.uuidString,
                "sessionId": "S",
                "cwd": "/tmp",
                "updatedAt": "2026-09-14T12:00:00Z",
                "runId": Self.run
            ]
            let hintURL = sessions.appendingPathComponent("\(pane.uuidString).json")
            try JSONSerialization.data(withJSONObject: hint).write(to: hintURL)

            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .dead }
            )
            adapter.prepareForLaunch()
            adapter.bootstrap(into: session, attention: AttentionState())

            // Claude reports the end of a session itself, so a hint that is
            // still here with a dead process means the process died without
            // saying so. That is the case resuming exists for, and dropping
            // the hint would take away what brings it back.
            #expect(adapter.lastFailure == nil)
            #expect(FileManager.default.fileExists(atPath: hintURL.path))
        }
    }

    @Test("a lock file beside the worktree events is not read as an event")
    func worktreeEvents_ignoreWhatIsNotAnEvent() throws {
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID())
            let events = harness.state.appendingPathComponent("worktree-events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            // The first pass only takes note of what is already there, so the
            // files have to arrive after it for this to reach the rule that
            // consumes them.
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            let planted: Set = [
                "1757000000-1-a-create.json.flock",
                ".1757000000-1-a-create.json.tmp.42"
            ]
            for name in planted {
                try Data("{}".utf8).write(to: events.appendingPathComponent(name))
            }
            harness.adapter.refresh()

            // Consuming either of these would delete it and, for the lock
            // file, create another one under a longer name every pass. Compare
            // the names rather than the count: deleting both and leaving two
            // new lock files behind would keep the count the same.
            #expect(harness.adapter.lastFailure == nil)
            let left = try Set(FileManager.default.contentsOfDirectory(atPath: events.path))
            #expect(left == planted, "left: \(left.sorted())")
        }
    }
}
