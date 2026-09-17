// AgentTmuxGoneEndpointTests.swift
// Limpid — how this process decides a run's tmux is gone, and what the rules do with that.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Agent runs whose tmux is gone")
struct AgentTmuxGoneEndpointTests {
    private static let socket = "/tmp/limpid-gone-endpoint/s"
    private static let generation = TmuxServerGeneration.Recorded(pid: "42", startedAt: "100")

    private func endpoint(
        paneID: String = "%4",
        generation: TmuxServerGeneration.Recorded? = AgentTmuxGoneEndpointTests.generation
    ) -> TmuxRuntimeEndpoint {
        TmuxRuntimeEndpoint(
            socketPath: Self.socket,
            serverPID: generation?.pid ?? "",
            serverStartedAt: generation?.startedAt ?? "",
            paneID: paneID
        )
    }

    private func location(paneID: String, generation: TmuxServerGeneration.Recorded) -> TmuxPaneLocation {
        TmuxPaneLocation(
            socketPath: Self.socket,
            serverPID: generation.pid,
            serverStartedAt: generation.startedAt,
            sessionID: "$2",
            windowID: "@3",
            paneID: paneID,
            isActive: true
        )
    }

    @Test func noServerOnTheSocket_isGone() {
        var topology = TmuxTopology()
        // Nothing probed yet says nothing: a socket this process has not
        // reached is not a socket it found empty.
        #expect(!topology.isGone(endpoint()))
        topology.servers[Self.socket] = .absent
        #expect(topology.isGone(endpoint()))
    }

    @Test func anotherServerRun_isGone() {
        var topology = TmuxTopology()
        topology.servers[Self.socket] = .running(pid: "43", startedAt: "100")
        #expect(topology.isGone(endpoint()))
        // A run that never said which server it was on cannot be told from a
        // later server's pane of the same number, so it is not called gone.
        #expect(!topology.isGone(endpoint(generation: nil)))
    }

    @Test func theRecordedServerWithoutThePane_isGone() {
        var topology = TmuxTopology()
        topology.servers[Self.socket] = .running(pid: Self.generation.pid, startedAt: Self.generation.startedAt)
        topology.panes = [location(paneID: "%9", generation: Self.generation)]
        #expect(topology.isGone(endpoint()))

        topology.panes.append(location(paneID: "%4", generation: Self.generation))
        #expect(!topology.isGone(endpoint()))
    }

    /// What a mirror tab reports when the session check it ran said the
    /// session is gone, before the poll next visits that socket.
    @Test func aReportedEndpoint_isGoneWithoutAProbe() {
        let presence = TmuxPanePresence()
        #expect(!presence.isGone(endpoint()))

        presence.reportGone(endpoint())

        #expect(presence.isGone(endpoint()))
        #expect(!presence.isGone(endpoint(paneID: "%9")))
        // Pane ids start again with each server, so a report about one server
        // run says nothing about the next.
        #expect(!presence.isGone(endpoint(generation: .init(pid: "43", startedAt: "100"))))
        // A report that names no server run is not one we could match later.
        presence.reportGone(endpoint(paneID: "%5", generation: nil))
        #expect(!presence.isGone(endpoint(paneID: "%5", generation: nil)))
    }

    /// The whole of the reason the report exists: the rules hold a hosted
    /// run's conversation out of resume, and a killed server writes no record
    /// to say the run is over.
    @Test func aGoneEndpoint_freesTheConversationForResume() async throws {
        try await withTempDir { directory in
            let session = WindowSession()
            let tab = session.openTab(container: .loose)
            let leaf = try #require(tab.splitTree.allLeafIDs().first)
            let sessionID = "00000000-0000-4000-8000-0000000000C0"
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(
                AgentStateRecordFixture(
                    runId: UUID().uuidString.uppercased(),
                    revision: 1,
                    paneId: leaf.uuidString,
                    state: "running",
                    updatedAt: "2026-09-18T00:00:00Z",
                    lastHookEvent: "session_started",
                    sessionId: sessionID,
                    isTmuxHosted: true,
                    tmuxSocketPath: Self.socket,
                    tmuxSessionId: "$2",
                    tmuxPaneId: "%4",
                    tmuxServerPID: Self.generation.pid,
                    tmuxServerStartedAt: Self.generation.startedAt
                ),
                to: states
            )
            try AgentRecordFixtures.write(
                AgentSessionHintFixture(
                    paneId: leaf.uuidString,
                    sessionId: sessionID,
                    cwd: directory.path,
                    updatedAt: "2026-09-18T00:00:00Z"
                ),
                to: hints
            )
            let presence = TmuxPanePresence()
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: hints,
                processStatus: { _ in .alive }
            )
            projection.bootstrap(into: session, tmuxPresence: presence)
            #expect(session.tab(tab.id)?.agentResumeCandidates[leaf] == nil)

            AgentTmuxRuns(projection: projection, presence: presence).reportGone(endpoint())

            #expect(session.tab(tab.id)?.agentResumeCandidates[leaf] == [.codex])
        }
    }
}
