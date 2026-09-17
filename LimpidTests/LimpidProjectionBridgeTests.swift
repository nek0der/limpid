// LimpidProjectionBridgeTests.swift
// Limpid — the boundary itself: what crosses it and what comes back.

import Foundation
import Testing
@testable import Limpid

@Suite("LimpidProjectionBridge")
struct LimpidProjectionBridgeTests {
    @Test("the registry reports the providers this build has")
    func providers_areReported() throws {
        let body = try LimpidProjectionBridge.providers()
        let registry = try JSONDecoder().decode([String: AgentProviderDescriptor].self, from: body)
        #expect(registry["claude"]?.stateDirectory == "agent-states")
        #expect(registry["codex"]?.stateDirectory == "codex-agent-states")
        // The rules branch on capabilities, so the host must be able to read
        // them rather than holding a list of its own.
        #expect(registry["claude"]?.capabilities.contains("session_title") == true)
        #expect(registry["codex"]?.capabilities.contains("session_title") == false)
    }

    @Test("an empty pass round-trips and carries state forward")
    func emptyPass_roundTrips() throws {
        let now = Data(#"{"wall":"2026-09-14T12:00:00Z","monotonicMs":0}"#.utf8)
        let input = try JSONEncoder().encode(AgentProjectionInput())
        let body = try LimpidProjectionBridge.project(state: nil, input: input, now: now)
        let response = try JSONDecoder().decode(AgentProjectionResponse.self, from: body)
        #expect(response.projection.runtimes.isEmpty)

        // Both clocks are required: the rules compare records against wall
        // time and age pending notifications against uptime, and guessing
        // either would make a retention rule depend on the wrong one.
        let halfAnEnvelope = Data(#"{"wall":"2026-09-14T12:00:00Z"}"#.utf8)
        #expect(throws: LimpidProjectionError.self) {
            try LimpidProjectionBridge.project(state: nil, input: input, now: halfAnEnvelope)
        }
    }

    @Test("a tmux-hosted run reaches the pane the host says its endpoint is in")
    func tmuxEndpointKey_matchesWhatTheRulesBuild() throws {
        let pane = UUID()
        let socket = "/tmp/tmux-\(getuid())/default"
        let record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": UUID().uuidString,
            "runId": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "revision": 4,
            "stateEpisodeToken": "4",
            "state": "running",
            "updatedAt": "2026-09-14T12:00:00Z",
            "pid": "4242",
            "tmuxSocketPath": socket,
            "tmuxPaneId": "%7"
        ]
        var input = AgentProjectionInput()
        input.providers = try JSONDecoder().decode(
            [String: AgentProviderDescriptor].self,
            from: LimpidProjectionBridge.providers()
        )
        input.records = try [AgentProjectionFile(
            provider: "claude",
            name: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            content: String(data: JSONSerialization.data(withJSONObject: record), encoding: .utf8)
        )]
        input.pidStatus = ["4242": "alive"]
        input.tabs = [AgentProjectionTabPanes(id: UUID(), panes: [pane])]
        // The host writes this key; the rules rebuild it from the record's own
        // socket and pane. If the two spellings ever diverge the run simply
        // stops appearing, with nothing logged anywhere, so the agreement is
        // what this asserts.
        input.presence.attachments[
            AgentProjectionPresence.key(socketPath: socket, pane: "%7")
        ] = [pane]

        let body = try LimpidProjectionBridge.project(
            state: nil,
            input: JSONEncoder().encode(input),
            now: Data(#"{"wall":"2026-09-14T12:01:00Z","monotonicMs":60000}"#.utf8)
        )
        let response = try JSONDecoder().decode(AgentProjectionResponse.self, from: body)

        #expect(response.projection.badgesByPane[pane]?["claude"]?.state == "running")
    }
}
