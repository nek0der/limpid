// AgentMirrorPresenceTests.swift
// Limpid — a tmux-hosted run resolves to the mirror leaf that shows its pane.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Agent presence in mirror tabs")
struct AgentMirrorPresenceTests {
    private static let generation = TmuxServerGeneration.Recorded(pid: "42", startedAt: "100")

    private func record(socketPath: String, paneID: String, generation: TmuxServerGeneration.Recorded) -> AgentStateRecordFixture {
        AgentStateRecordFixture(
            schemaVersion: 2,
            runId: UUID().uuidString,
            revision: 1,
            // The launch pane is never a leaf here, so a badge can only
            // appear on the mirror leaf through the endpoint.
            paneId: UUID().uuidString,
            state: "running",
            updatedAt: "2026-09-09T00:00:00Z",
            isTmuxHosted: true,
            tmuxSocketPath: socketPath,
            tmuxSessionId: "$2",
            tmuxPaneId: paneID,
            tmuxServerPID: generation.pid,
            tmuxServerStartedAt: generation.startedAt
        )
    }

    /// Turns a fresh loose tab into a one-pane mirror of `paneID` and returns
    /// its tab and leaf ids.
    private func mirrorTab(
        in session: WindowSession,
        socketPath: String,
        paneID: String,
        generation: TmuxServerGeneration.Recorded?
    ) throws -> (tab: UUID, leaf: UUID) {
        let tab = session.openTab(container: .loose)
        let leaf = try #require(tab.splitTree.allLeafIDs().first)
        let binding = TmuxBinding(
            socketPath: socketPath,
            sessionID: "$2",
            sessionName: "agent",
            serverPID: generation?.pid,
            serverStartedAt: generation?.startedAt
        )
        session.update(tab.id) {
            $0.kind = .tmuxMirror
            $0.paneSources[leaf] = .tmux(TmuxPaneRef(binding: binding, windowID: "@3", paneID: paneID))
        }
        return (tab.id, leaf)
    }

    private func project(
        _ record: AgentStateRecordFixture,
        into session: WindowSession,
        presence: TmuxPanePresence = TmuxPanePresence(),
        in directory: URL
    ) throws -> AttentionState {
        let states = directory.appendingPathComponent("states")
        try AgentRecordFixtures.write(record, to: states)
        let attention = AttentionState()
        ProjectionFixture.adapter(
            state: states,
            sessions: directory.appendingPathComponent("sessions"),
            processStatus: { _ in .alive }
        ).bootstrap(into: session, attention: attention, tmuxPresence: presence)
        return attention
    }

    /// The record carries the socket as tmux resolved it, while the mirror
    /// holds whatever spelling the user's listing produced. No probe has
    /// seen this socket, so the match rests on the adapter's own
    /// normalization.
    @Test(arguments: [
        ("/private/tmp/limpid-mirror-presence/s", "/tmp/limpid-mirror-presence/s"),
        ("/tmp/limpid-mirror-presence/s", "/private/tmp/limpid-mirror-presence/s"),
        ("/tmp/limpid-mirror-presence/s", "/tmp/limpid-mirror-presence/s")
    ])
    func hostedRun_resolvesToTheMirrorLeaf(recordSocket: String, mirrorSocket: String) throws {
        try withTempDir { directory in
            let session = WindowSession()
            let mirror = try mirrorTab(in: session, socketPath: mirrorSocket, paneID: "%4", generation: Self.generation)
            let attention = try project(
                record(socketPath: recordSocket, paneID: "%4", generation: Self.generation),
                into: session,
                in: directory
            )

            #expect(session.tab(mirror.tab)?.agentBadges[.codex]?[mirror.leaf]?.state == .running)
            let runtime = try #require(attention.allRuntimes.first)
            #expect(runtime.paneIDs == [mirror.leaf])
            #expect(runtime.attachmentResolution == .attached)
            // A mirror shows every pane of its window, so the leaf has no
            // location: nothing may treat it as a background pane, and ⌘J has
            // no client of ours to `select-pane` for.
            #expect(runtime.tmuxLocations[mirror.leaf] == nil)
        }
    }

    @Test func otherPane_orUnrecordedServer_doesNotResolve() throws {
        try withTempDir { directory in
            let session = WindowSession()
            let socket = "/tmp/limpid-mirror-presence/s"
            let otherPane = try mirrorTab(in: session, socketPath: socket, paneID: "%5", generation: Self.generation)
            // Pane ids restart with the server, so a leaf that does not say
            // which server it showed must not claim the run.
            let unrecorded = try mirrorTab(in: session, socketPath: socket, paneID: "%4", generation: nil)
            let replaced = try mirrorTab(
                in: session, socketPath: socket, paneID: "%4",
                generation: .init(pid: "42", startedAt: "101")
            )
            let attention = try project(
                record(socketPath: socket, paneID: "%4", generation: Self.generation),
                into: session,
                in: directory
            )

            for mirror in [otherPane, unrecorded, replaced] {
                #expect(session.tab(mirror.tab)?.agentBadges[.codex, default: [:]][mirror.leaf] == nil)
            }
            // With no probe answer either, the run is where the rules cannot
            // tell yet, not detached and not on any pane.
            let runtime = try #require(attention.allRuntimes.first)
            #expect(runtime.paneIDs.isEmpty)
            #expect(runtime.attachmentResolution == .unresolved)
        }
    }

    /// While both paths exist, a pane attached through its own tty client and
    /// a mirror leaf both show the run. Both are listed, and only the tty
    /// pane carries a location.
    @Test func mirrorLeafAndClientPane_bothShowTheRun() throws {
        try withTempDir { directory in
            let (session, clientTab, clientPane) = WindowSessionFixture.withLooseTab()
            let socket = "/private/tmp/tmux-501/limpid-test"
            let mirror = try mirrorTab(in: session, socketPath: socket, paneID: "%4", generation: Self.generation)
            let presence = TmuxPanePresence(
                bindingsByPaneID: [clientPane: TmuxBinding(socketPath: socket, sessionID: "$2", sessionName: "agent")],
                topology: TmuxTopology(
                    panes: TmuxTopology.parsePanes("42\t100\t$2\t@3\t%4\t1\t0\n", socketPath: socket),
                    socketAliases: [socket: socket]
                )
            )
            let attention = try project(
                record(socketPath: socket, paneID: "%4", generation: Self.generation),
                into: session,
                presence: presence,
                in: directory
            )

            let runtime = try #require(attention.allRuntimes.first)
            #expect(Set(runtime.paneIDs) == [mirror.leaf, clientPane])
            #expect(runtime.tmuxLocations[clientPane]?.isActive == false)
            #expect(runtime.tmuxLocations[mirror.leaf] == nil)
            #expect(session.tab(clientTab.id)?.agentBadges[.codex]?[clientPane]?.state == .running)
            #expect(session.tab(mirror.tab)?.agentBadges[.codex]?[mirror.leaf]?.state == .running)
        }
    }
}

@MainActor
@Suite(
    "Agent presence in mirror tabs against a real server",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
struct AgentMirrorPresenceSmokeTests {
    /// The fixture's socket sits under `/var/folders`, which tmux reports
    /// through its `/private` realpath in `$TMUX`, the value a hook records.
    /// The probe's aliases for the socket are what the adapter matches with.
    @Test func hostedRun_resolvesThroughTheProbedAliases() throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let generation = try server.generation()
        let window = try #require(server.windowIDs().first)
        let pane = try server.paneID(inWindow: window)
        let recorded = try #require(TmuxSocketPath(server.socketPath)?.value)
        #expect(recorded != server.socketPath, "the fixture socket no longer differs from its realpath")

        let session = WindowSession()
        let tab = session.openTab(container: .loose)
        let leaf = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.kind = .tmuxMirror
            $0.paneSources[leaf] = .tmux(TmuxPaneRef(
                binding: TmuxBinding(
                    socketPath: server.socketPath,
                    sessionID: (try? server.format("#{session_id}")) ?? "",
                    sessionName: "t",
                    serverPID: generation.pid,
                    serverStartedAt: generation.startedAt
                ),
                windowID: window,
                paneID: pane
            ))
        }
        let topology = TmuxClientProbe.topology(
            tmuxPath: server.executable,
            socketPaths: [URL(fileURLWithPath: recorded)],
            timeout: TmuxServerFixture.commandTimeout
        )
        #expect(topology.socketAliases[recorded] == recorded)

        try withTempDir { directory in
            let states = directory.appendingPathComponent("states")
            try AgentRecordFixtures.write(AgentStateRecordFixture(
                runId: UUID().uuidString,
                revision: 1,
                paneId: UUID().uuidString,
                state: "needsInput",
                updatedAt: "2026-09-09T00:00:00Z",
                isTmuxHosted: true,
                tmuxSocketPath: recorded,
                tmuxSessionId: "$0",
                tmuxPaneId: pane,
                tmuxServerPID: generation.pid,
                tmuxServerStartedAt: generation.startedAt
            ), to: states)
            let attention = AttentionState()
            ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions"),
                processStatus: { _ in .alive }
            ).bootstrap(
                into: session,
                attention: attention,
                tmuxPresence: TmuxPanePresence(topology: topology)
            )

            #expect(session.tab(tab.id)?.agentBadges[.codex]?[leaf]?.state == .needsInput)
            let runtime = try #require(attention.allRuntimes.first)
            #expect(runtime.paneIDs == [leaf])
            #expect(runtime.tmuxLocations.isEmpty)
        }
    }
}
