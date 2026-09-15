// AgentStateRecordSchemaTests.swift
// Limpid — the projection accepts the version 3 records the Rust hook
// runtime writes, alongside the version 2 records the shell receivers wrote.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent state record schema")
@MainActor
struct AgentStateRecordSchemaTests {
    /// A record as `limpid-agent-hook` writes it after a turn finished: no
    /// `runStartedAt` and no `detail` rather than empty strings, a neutral
    /// `lastHookEvent`, and a field this build does not know.
    ///
    /// Written as text rather than through the fixture type because the point
    /// of these cases is what the reader does with the bytes a hook produced,
    /// including the shapes no Swift model would emit.
    private static let versionThree = """
    {"schemaVersion":3,"paneId":"%PANE%","runId":"6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",\
    "revision":4,"stateEpisodeToken":"4","state":"finished","updatedAt":"2026-09-14T00:00:05Z",\
    "lastHookEvent":"turn_finished","pid":"4242","lastPrompt":"first","firstPrompt":"first",\
    "sessionId":"00000000-0000-4000-8000-000000000001","providerSessionTitle":"Formal",\
    "sessionStartedAt":"2026-09-14T00:00:00Z","turnBaseTree":"0123456789abcdef0123456789abcdef01234567",\
    "turnRoot":"/tmp/example","futureField":{"nested":true}}
    """

    /// Runs one record through a projection pass and hands back the badge the
    /// pane ends up showing. The process is reported alive so the pass has no
    /// reason to retire the record before it is projected.
    private func badge(from json: String, provider: String) throws -> AgentBadge {
        try withTempDir { directory in
            let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
            try Data(json.replacingOccurrences(of: "%PANE%", with: paneID.uuidString).utf8)
                .write(to: states.appendingPathComponent(
                    "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11.state.json"
                ))
            let projection = ProjectionFixture.adapter(
                provider: provider,
                state: states,
                sessions: directory.appendingPathComponent("sessions"),
                processStatus: { _ in .alive }
            )
            projection.bootstrap(into: session)
            let kind: AgentKind = provider == "claude" ? .claude : .codex
            return try #require(session.tab(tab.id)?.agentBadges[kind]?[paneID])
        }
    }

    @Test("projects a version 3 record with absent optionals", arguments: ["claude", "codex"])
    func record_versionThree_projects(provider: String) throws {
        let badge = try badge(from: Self.versionThree, provider: provider)
        #expect(badge.state == .finished)
        // Absent rather than empty: the turn is over, so there is no start.
        #expect(badge.runStartedAt == nil)
        #expect(badge.detail == nil)
        #expect(badge.firstPrompt == "first")
        #expect(badge.turnRoot == "/tmp/example")
    }

    @Test("carries the Claude title observations through the projection")
    func claudeRecord_versionThree_carriesTitles() throws {
        let badge = try badge(from: Self.versionThree, provider: "claude")
        #expect(badge.conversationID == "00000000-0000-4000-8000-000000000001")
        #expect(badge.providerSessionTitle == "Formal")
    }

    @Test("treats a version 2 empty runStartedAt and a version 3 null alike")
    func runStartedAt_emptyAndAbsent_bothMeanNotRunning() throws {
        let versionTwo = Self.versionThree
            .replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":2")
            .replacingOccurrences(
                of: "\"state\":\"finished\"",
                with: "\"state\":\"finished\",\"runStartedAt\":\"\",\"detail\":\"\""
            )
        let two = try badge(from: versionTwo, provider: "claude")
        let three = try badge(from: Self.versionThree, provider: "claude")
        #expect(two.runStartedAt == nil)
        #expect(three.runStartedAt == nil)
        #expect(two.state == three.state)
    }
}
