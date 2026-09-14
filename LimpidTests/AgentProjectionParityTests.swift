// AgentProjectionParityTests.swift
// Limpid — the same records through both readers, compared.
//
// The reader cannot be swapped behind a flag the way the writer was: it runs
// in this process, and keeping both alive for a release would leave two
// implementations of one rule in the tree. So agreement is established here
// instead, and this file is deleted along with the trackers once it holds.
//
// Each case writes records for a real pane, runs the tracker that ships today,
// snapshots what the interface would show, resets, runs the projection over
// the same files, and compares.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentProjectionParity")
struct AgentProjectionParityTests {
    /// What both readers are expected to agree on: the badge each pane shows,
    /// what the tab is called, and which runs attention knows about.
    private struct Surface: Equatable, CustomStringConvertible {
        var badges: [String: String]
        var details: [String: String]
        var sessions: [String: String]
        var title: String
        var runtimes: [String]

        var description: String {
            "badges: \(badges), details: \(details), sessions: \(sessions), title: \(title), runtimes: \(runtimes)"
        }
    }

    private struct Harness {
        let session: WindowSession
        let tab: Tab
        let pane: UUID
        let state: URL
        let sessions: URL
        let alive: Set<String>
    }

    private func harness(root: URL, alive: Set<String> = ["4242"]) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for directory in [state, sessions] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        return Harness(session: session, tab: tab, pane: pane, state: state, sessions: sessions, alive: alive)
    }

    private func write(
        _ harness: Harness,
        run: String,
        state: String,
        revision: Int,
        updatedAt: String,
        extra: [String: Any] = [:]
    ) throws {
        var record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": harness.pane.uuidString,
            "runId": run,
            "revision": revision,
            "stateEpisodeToken": String(revision),
            "state": state,
            "updatedAt": updatedAt,
            "pid": "4242"
        ]
        record.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: record)
            .write(to: harness.state.appendingPathComponent("\(run).state.json"))
    }

    private func writeHint(_ harness: Harness, run: String, sessionID: String) throws {
        let hint: [String: Any] = [
            "schemaVersion": 1,
            "paneId": harness.pane.uuidString,
            "sessionId": sessionID,
            "cwd": "/repo",
            "updatedAt": "2026-09-14T12:00:00Z",
            "runId": run
        ]
        try JSONSerialization.data(withJSONObject: hint)
            .write(to: harness.sessions.appendingPathComponent("\(harness.pane.uuidString).json"))
    }

    private func status(_ harness: Harness) -> (String?) -> AgentProcessStatus {
        { pid in
            guard let pid else { return .unknown }
            return harness.alive.contains(pid) ? .alive : .dead
        }
    }

    private func snapshot(_ harness: Harness, attention: AttentionState) -> Surface {
        let tab = harness.session.tabs.first { $0.id == harness.tab.id }
        let badges = tab?.claudeAgentBadges ?? [:]
        return Surface(
            badges: Dictionary(uniqueKeysWithValues: badges.map {
                ($0.key.uuidString, $0.value.state.rawValue)
            }),
            details: Dictionary(uniqueKeysWithValues: badges.compactMap { pane, badge in
                badge.detail.map { (pane.uuidString, $0) }
            }),
            sessions: Dictionary(uniqueKeysWithValues: (tab?.claudeSessions ?? [:]).map {
                ($0.key.uuidString, $0.value.sessionId)
            }),
            title: tab?.title ?? "",
            runtimes: (attention.runtimesByKind[.claude] ?? [])
                .map { "\($0.id)|\($0.badge.state.rawValue)|\($0.attentionEventToken)" }
                .sorted()
        )
    }

    private func reset(_ harness: Harness, title: String) {
        harness.session.applyAcrossTabs { tab in
            tab.claudeAgentBadges = [:]
            tab.claudeSessions = [:]
            tab.title = title
        }
    }

    /// Runs the tracker that ships today, then the projection, over the same
    /// files, and returns both surfaces.
    private func bothReaders(_ harness: Harness, passes: Int = 1) -> (old: Surface, new: Surface) {
        let title = harness.session.tabs.first { $0.id == harness.tab.id }?.title ?? ""

        let oldAttention = AttentionState()
        let tracker = ClaudeAgentStateTracker(
            store: ClaudeAgentStateStore(directory: harness.state),
            sessionStore: ClaudeSessionStore(directory: harness.sessions),
            processStatus: status(harness)
        )
        let sessionTracker = ClaudeSessionTracker(store: ClaudeSessionStore(directory: harness.sessions))
        tracker.bootstrap(into: harness.session, attention: oldAttention)
        sessionTracker.bootstrap(into: harness.session)
        for _ in 1..<max(passes, 1) {
            tracker.refreshPresentation()
        }
        let old = snapshot(harness, attention: oldAttention)

        reset(harness, title: title)

        let newAttention = AttentionState()
        let descriptors = AgentProviderRegistry.descriptors
        let adapter = AgentProjectionAdapter(
            directories: ["claude": AgentDirectories(
                state: harness.state,
                sessions: harness.sessions,
                cwdEvents: nil
            )],
            descriptors: descriptors.filter { $0.key == "claude" },
            resumeIntents: AgentResumeIntentStore(
                directory: harness.state.appendingPathComponent("resume-intents")
            ),
            processStatus: status(harness)
        )
        adapter.bootstrap(into: harness.session, attention: newAttention)
        for _ in 1..<max(passes, 1) {
            adapter.refresh()
        }
        #expect(adapter.lastFailure == nil, "projection failed: \(adapter.lastFailure ?? "")")
        return (old, snapshot(harness, attention: newAttention))
    }

    @Test("a record landing on disk triggers a pass on its own")
    func watching_refreshesWhenTheDirectoryChanges() async throws {
        // Its own directory rather than the scoped helper: that helper hands
        // the body to a non-isolated context, which this actor-bound test
        // cannot cross.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let harness = try harness(root: root)
            let adapter = AgentProjectionAdapter(
                directories: ["claude": AgentDirectories(
                    state: harness.state,
                    sessions: harness.sessions,
                    cwdEvents: nil
                )],
                descriptors: AgentProviderRegistry.descriptors.filter { $0.key == "claude" },
                resumeIntents: AgentResumeIntentStore(
                    directory: harness.state.appendingPathComponent("resume-intents")
                ),
                processStatus: status(harness)
            )
            let attention = AttentionState()
            adapter.bootstrap(into: harness.session, attention: attention)
            adapter.startWatching()
            defer { adapter.stopWatching() }

            try write(
                harness,
                run: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                state: "running",
                revision: 2,
                updatedAt: "2026-09-14T12:01:00Z"
            )

            // The hook writes and the interface catches up on its own; nothing
            // asks it to. Polling rather than waiting a fixed time because the
            // file system decides when the event arrives.
            var badges: [UUID: AgentBadge] = [:]
            for _ in 0..<100 where badges.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                badges = harness.session.tabs.first { $0.id == harness.tab.id }?
                    .claudeAgentBadges ?? [:]
            }
            #expect(badges[harness.pane] != nil)
        }
    }

    @Test("a running turn reads the same through both")
    func runningTurn_agrees() throws {
        try withTempDir { root in
            let harness = try harness(root: root)
            try write(
                harness,
                run: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                state: "running",
                revision: 2,
                updatedAt: "2026-09-14T12:01:00Z",
                extra: ["lastPrompt": "list the files", "firstPrompt": "list the files"]
            )
            let (old, new) = bothReaders(harness)
            #expect(old == new, "old \(old)\nnew \(new)")
            #expect(new.badges[harness.pane.uuidString] == "running")
        }
    }

    @Test("a pane waiting for input reads the same through both")
    func needsInput_agrees() throws {
        try withTempDir { root in
            let harness = try harness(root: root)
            try write(
                harness,
                run: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                state: "needsInput",
                revision: 3,
                updatedAt: "2026-09-14T12:02:00Z",
                extra: ["detail": "Which colour?", "lastPrompt": "ask me"]
            )
            let (old, new) = bothReaders(harness)
            #expect(old == new, "old \(old)\nnew \(new)")
            #expect(new.details[harness.pane.uuidString] == "Which colour?")
        }
    }

    @Test("two runs on one pane pick the same winner")
    func dominance_agrees() throws {
        try withTempDir { root in
            let harness = try harness(root: root)
            // An unseen finish outranks a run still working, so the pane shows
            // the finish rather than the newer activity.
            try write(
                harness,
                run: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                state: "finished",
                revision: 4,
                updatedAt: "2026-09-14T12:03:00Z",
                extra: ["firstPrompt": "first"]
            )
            try write(
                harness,
                run: "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2",
                state: "running",
                revision: 2,
                updatedAt: "2026-09-14T12:05:00Z",
                extra: ["firstPrompt": "second"]
            )
            let (old, new) = bothReaders(harness)
            #expect(old == new, "old \(old)\nnew \(new)")
            #expect(new.badges[harness.pane.uuidString] == "finished")
            #expect(new.runtimes.count == 2)
        }
    }

    @Test("a resume hint reaches the pane and names the tab the same way")
    func sessionAndTitle_agree() throws {
        try withTempDir { root in
            let harness = try harness(root: root)
            let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"
            try write(
                harness,
                run: run,
                state: "finished",
                revision: 4,
                updatedAt: "2026-09-14T12:03:00Z",
                extra: [
                    "sessionId": "session-1",
                    "firstPrompt": "rename the thing",
                    "sessionStartedAt": "2026-09-14T12:00:00Z"
                ]
            )
            try writeHint(harness, run: run, sessionID: "session-1")
            let (old, new) = bothReaders(harness)
            #expect(old == new, "old \(old)\nnew \(new)")
            #expect(new.sessions[harness.pane.uuidString] == "session-1")
            #expect(new.title == "rename the thing")
        }
    }

    @Test("a run left in an unknown state reads the same through both")
    func unknownState_agrees() throws {
        try withTempDir { root in
            let harness = try harness(root: root)
            try write(
                harness,
                run: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                state: "unknown",
                revision: 5,
                updatedAt: "2026-09-14T12:04:00Z",
                extra: ["firstPrompt": "done"]
            )
            let (old, new) = bothReaders(harness)
            #expect(old == new, "old \(old)\nnew \(new)")
        }
    }

    @Test("a stale revision is ignored by both")
    func staleRevision_agrees() throws {
        try withTempDir { root in
            let harness = try harness(root: root)
            let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"
            try write(harness, run: run, state: "finished", revision: 4, updatedAt: "2026-09-14T12:03:00Z")

            // Both readers accept the record, then see it replaced by an older
            // revision on the second pass and keep what they have.
            let firstPass = bothReaders(harness)
            #expect(firstPass.old == firstPass.new)

            try write(harness, run: run, state: "running", revision: 2, updatedAt: "2026-09-14T12:01:00Z")
            let secondPass = bothReaders(harness, passes: 2)
            #expect(secondPass.old == secondPass.new, "old \(secondPass.old)\nnew \(secondPass.new)")
        }
    }
}
