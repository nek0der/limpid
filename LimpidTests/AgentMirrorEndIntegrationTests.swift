// AgentMirrorEndIntegrationTests.swift
// Limpid — what becomes of an agent's mirror tab when its tmux ends, against a real server.

import Foundation
import Testing
@testable import Limpid

/// An agent's mirror tab on a throwaway server, with the records the agent's
/// hooks would have written beside it and a projection reading them. The
/// registry hands out no views, so no libghostty runs.
@MainActor
private final class AgentEndHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry = RecordingSurfaceRegistry()
    let presence = TmuxPanePresence()
    let projection: AgentProjectionAdapter
    let directory: URL
    private(set) var notices: [String] = []

    /// The provider the records are written for. Codex resumes and has no
    /// session titles, which keeps the tab's name out of the way.
    static let kind = AgentKind.codex
    static let sessionID = "00000000-0000-4000-8000-0000000000C0"

    init(directory: URL) throws {
        self.directory = directory
        server = try TmuxServerFixture.launch()
        store = TmuxConnectionStore(registry: registry, secureInput: nil, tmuxExecutable: server.executable)
        projection = ProjectionFixture.adapter(
            provider: Self.kind.rawValue,
            state: directory.appendingPathComponent("states"),
            sessions: directory.appendingPathComponent("sessions"),
            processStatus: { _ in .alive }
        )
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
        store.onNotice = { [weak self] in self?.notices.append($0) }
        store.agentRuns = AgentTmuxRuns(projection: projection, presence: presence)
    }

    /// A detached session for the agent and the request naming it, as a shim
    /// leaves behind.
    func request(launchPaneID: UUID) throws -> AgentMirrorRequest {
        let name = "limpid-agent-\(UUID().uuidString.prefix(8))"
        let printed = try #require(server.run([
            "new-session", "-d", "-P",
            "-F", "#{session_id}\t#{window_id}\t#{pane_id}\t#{pid}\t#{start_time}",
            "-s", name, "-x", "80", "-y", "24",
            "sh", "-c", "PS1='$ ' exec sh"
        ]))
        let fields = printed.split(separator: "\t").map(String.init)
        try #require(fields.count == 5)
        return AgentMirrorRequest(
            socketPath: TmuxClientProbe.normalizeSocketPath(server.socketPath),
            sessionID: fields[0],
            sessionName: name,
            windowID: fields[1],
            paneID: fields[2],
            serverPID: fields[3],
            serverStartedAt: fields[4],
            leafID: UUID(),
            launchPaneID: launchPaneID,
            provider: Self.kind
        )
    }

    /// The record the agent's hooks would have written from inside that
    /// session, and the resume hint beside it. `hasEnded` is the difference
    /// between an agent that ended its own session and a tmux that went away
    /// under a run that was still going.
    func writeRecords(for request: AgentMirrorRequest, hasEnded: Bool) throws {
        try AgentRecordFixtures.write(
            AgentStateRecordFixture(
                runId: UUID().uuidString.uppercased(),
                revision: hasEnded ? 2 : 1,
                paneId: request.leafID.uuidString,
                state: hasEnded ? "unknown" : "running",
                updatedAt: "2026-09-18T00:00:00Z",
                lastHookEvent: hasEnded ? "session_ended" : "session_started",
                sessionId: Self.sessionID,
                isTmuxHosted: true,
                tmuxSocketPath: request.socketPath,
                tmuxSessionId: request.sessionID,
                tmuxPaneId: request.paneID,
                tmuxServerPID: request.serverPID,
                tmuxServerStartedAt: request.serverStartedAt
            ),
            to: directory.appendingPathComponent("states")
        )
        try AgentRecordFixtures.write(
            AgentSessionHintFixture(
                paneId: request.leafID.uuidString,
                sessionId: Self.sessionID,
                cwd: directory.path,
                updatedAt: "2026-09-18T00:00:00Z"
            ),
            to: directory.appendingPathComponent("sessions")
        )
    }

    /// Opens the tab the request asks for and waits until tmux has described
    /// its window.
    func openMirror(_ request: AgentMirrorRequest) async throws -> UUID {
        #expect(TmuxMirrorActions.openAgentMirror(request, session: session, store: store))
        let tabID = try #require(session.tab(containing: request.leafID)?.id)
        let mirror = try #require(store.liveMirror(for: tabID))
        #expect(await waitUntil { mirror.connection.state == .attached })
        return tabID
    }

    func tab(of request: AgentMirrorRequest) -> Tab? {
        session.tab(containing: request.leafID)
    }

    func tearDown() {
        store.stopAll()
        projection.stopWatching()
        server.tearDown()
    }
}

@Suite(
    "Agent mirror tabs when tmux ends",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct AgentMirrorEndIntegrationTests {
    /// The agent ended its own session, which its record says. Nothing is
    /// left to show and nothing happened the user did not watch happen.
    @Test func anAgentThatEndedItsSession_closesItsTabWithoutANotice() async throws {
        try await withTempDir { directory in
            let harness = try AgentEndHarness(directory: directory)
            defer { harness.tearDown() }
            let launch = harness.session.openTab(container: .loose)
            let leaf = try #require(launch.splitTree.allLeafIDs().first)
            let request = try harness.request(launchPaneID: leaf)
            try harness.writeRecords(for: request, hasEnded: true)
            harness.projection.bootstrap(into: harness.session, tmuxPresence: harness.presence)
            let tabID = try await harness.openMirror(request)

            harness.server.run(["kill-session", "-t", request.sessionID])

            #expect(await waitUntil(.seconds(5)) { harness.session.tab(tabID) == nil })
            #expect(harness.notices.isEmpty)
            // Nor kept for reopening: its window is gone.
            #expect(harness.session.closedTabStack.isEmpty)
        }
    }

    /// The server was killed under a run that was still going. The record
    /// says nothing, because nothing ran to write it, so the conversation is
    /// what is left: the tab keeps its leaf and resumes it.
    @Test func aKilledServer_leavesTheTabAsATerminalThatResumes() async throws {
        try await withTempDir { directory in
            let harness = try AgentEndHarness(directory: directory)
            defer { harness.tearDown() }
            let launch = harness.session.openTab(container: .loose)
            let leaf = try #require(launch.splitTree.allLeafIDs().first)
            let request = try harness.request(launchPaneID: leaf)
            try harness.writeRecords(for: request, hasEnded: false)
            harness.projection.bootstrap(into: harness.session, tmuxPresence: harness.presence)
            let tabID = try await harness.openMirror(request)
            // While tmux holds the run, its conversation is not offered
            // anywhere: resuming it would run it twice.
            #expect(harness.tab(of: request)?.agentResumeCandidates[request.leafID] == nil)

            harness.server.run(["kill-server"])

            #expect(await waitUntil(.seconds(5)) { harness.session.tab(tabID)?.kind == .terminal })
            let tab = try #require(harness.session.tab(tabID))
            // The same leaf, which is what the agent's records name, so the
            // conversation's hint still belongs to it.
            #expect(tab.splitTree.allLeafIDs() == [request.leafID])
            #expect(tab.paneSources.isEmpty)
            #expect(tab.mirrorOrigin == .user)
            #expect(tab.mirroredAgent == nil)
            #expect(harness.notices.isEmpty)
            #expect(harness.store.mirror(for: tabID) == nil)
            #expect(harness.store.tabConnections[tabID] == nil)
            // The surface that read tmux was let go, so the leaf's next one
            // starts a shell.
            #expect(harness.registry.unregisteredIDs.contains(request.leafID))

            let command = try #require(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: request.leafID))
            #expect(command.contains(AgentEndHarness.sessionID))
        }
    }
}
