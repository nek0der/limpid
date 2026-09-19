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

    /// What the agent's hooks would have left behind from inside that
    /// session. `hasEnded` is the difference between an agent that ended its
    /// own session and a tmux that went away under a run that was still
    /// going; either way the run started one, so its resume hint is there.
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
        try writeHostedHint(for: request)
    }

    /// The resume hint a hosted run writes when its session starts, where
    /// the hook keeps the hints of runs Limpid hosts in tmux.
    func writeHostedHint(for request: AgentMirrorRequest) throws {
        try AgentRecordFixtures.write(
            AgentSessionHintFixture(
                paneId: request.leafID.uuidString,
                sessionId: Self.sessionID,
                cwd: directory.path,
                updatedAt: "2026-09-18T00:00:00Z"
            ),
            to: AgentDirectories(
                state: directory.appendingPathComponent("states"),
                sessions: directory.appendingPathComponent("sessions"),
                cwdEvents: nil
            ).hostedSessions
        )
    }

    /// Where the hosted hints are kept, for asserting on the file itself.
    var hostedHintsDirectory: URL {
        AgentDirectories(
            state: directory.appendingPathComponent("states"),
            sessions: directory.appendingPathComponent("sessions"),
            cwdEvents: nil
        ).hostedSessions
    }

    /// What an agent the user ran on an earlier server on the same socket
    /// left behind: it ended its session, and its record names the same pane
    /// number as `request`, because pane ids start again with every server.
    /// Its leaf is in no tab, which is how such a run looks once its tab
    /// closed with it. The run id sorts first, so a pass reads it before the
    /// live run's record.
    func writeEarlierServerRecord(like request: AgentMirrorRequest) throws {
        try AgentRecordFixtures.write(
            AgentStateRecordFixture(
                runId: "00000000-0000-4000-8000-00000000E001",
                revision: 2,
                paneId: UUID().uuidString,
                state: "unknown",
                updatedAt: "2026-09-17T00:00:00Z",
                lastHookEvent: "session_ended",
                sessionId: "00000000-0000-4000-8000-0000000000E0",
                isTmuxHosted: true,
                tmuxSocketPath: request.socketPath,
                tmuxPaneId: request.paneID,
                tmuxServerPID: "1",
                tmuxServerStartedAt: "1000000000"
            ),
            to: directory.appendingPathComponent("states")
        )
    }

    /// A presence whose probe has answered for the fixture's server as the
    /// real poll would: the server run `request` names is the one on the
    /// socket, and it lists the request's pane. Built rather than polled, so
    /// no tmux but the throwaway one is asked anything.
    static func presence(serving request: AgentMirrorRequest) -> TmuxPanePresence {
        let socket = request.socketPath
        return TmuxPanePresence(topology: TmuxTopology(
            panes: [TmuxPaneLocation(
                socketPath: socket,
                serverPID: request.serverPID,
                serverStartedAt: request.serverStartedAt,
                sessionID: request.sessionID,
                windowID: request.windowID,
                paneID: request.paneID,
                isActive: true
            )],
            outcomes: [socket: .success("")],
            servers: [socket: .running(pid: request.serverPID, startedAt: request.serverStartedAt)]
        ))
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
    .tags(.smoke, .slow),
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
            // Told, unlike the close above: what the user sees is the
            // conversation they were reading replaced, in an instant and
            // with no input of theirs, by a shell starting a resume. The
            // notice names the agent the tab was opened for.
            #expect(harness.notices == [
                TmuxConnectionStore.agentServerGoneNotice(
                    name: AgentProviderRegistry.displayName(for: .codex)
                )
            ])
            #expect(harness.store.mirror(for: tabID) == nil)
            #expect(harness.store.tabConnections[tabID] == nil)
            // The surface that read tmux was let go, so the leaf's next one
            // starts a shell.
            #expect(harness.registry.unregisteredIDs.contains(request.leafID))

            let command = try #require(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: request.leafID))
            #expect(command.contains(AgentEndHarness.sessionID))
        }
    }

    /// The agent exited before it started a session — Claude Code asks
    /// whether to trust the folder before its session-start hook runs, and
    /// the user declined — and it was the server's only session, so tmux
    /// ended with it. Nothing was written, so there is no conversation to
    /// resume: the tab closes as quietly as the agent did, not as a server
    /// that went away.
    @Test func anAgentThatExitedBeforeItsSession_closesItsTabWithoutANotice() async throws {
        try await withTempDir { directory in
            let harness = try AgentEndHarness(directory: directory)
            defer { harness.tearDown() }
            let launch = harness.session.openTab(container: .loose)
            let leaf = try #require(launch.splitTree.allLeafIDs().first)
            let request = try harness.request(launchPaneID: leaf)
            harness.projection.bootstrap(into: harness.session, tmuxPresence: harness.presence)
            let tabID = try await harness.openMirror(request)

            harness.server.run(["kill-server"])

            #expect(await waitUntil(.seconds(5)) { harness.session.tab(tabID) == nil })
            #expect(harness.notices.isEmpty)
            #expect(harness.session.closedTabStack.isEmpty)
            // The launching tab is left as it was.
            #expect(harness.session.tab(launch.id) != nil)
        }
    }

    /// A hosted hint with no record beside it — one the hook wrote but that
    /// cannot be read — still names the conversation the run started, so
    /// the tab resumes it rather than closing on it.
    @Test func aHostedHintWithoutARecord_leavesTheTabAsATerminalThatResumes() async throws {
        try await withTempDir { directory in
            let harness = try AgentEndHarness(directory: directory)
            defer { harness.tearDown() }
            let launch = harness.session.openTab(container: .loose)
            let leaf = try #require(launch.splitTree.allLeafIDs().first)
            let request = try harness.request(launchPaneID: leaf)
            harness.projection.bootstrap(into: harness.session, tmuxPresence: harness.presence)
            let tabID = try await harness.openMirror(request)
            // Written once the tab holds the leaf, as a session start would
            // be: with no record to keep it, a hint for a leaf no tab holds
            // is swept.
            try harness.writeHostedHint(for: request)

            harness.server.run(["kill-server"])

            #expect(await waitUntil(.seconds(5)) { harness.session.tab(tabID)?.kind == .terminal })
            let tab = try #require(harness.session.tab(tabID))
            #expect(tab.splitTree.allLeafIDs() == [request.leafID])
            #expect(harness.notices == [
                TmuxConnectionStore.agentServerGoneNotice(
                    name: AgentProviderRegistry.displayName(for: .codex)
                )
            ])
            let command = try #require(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: request.leafID))
            #expect(command.contains(AgentEndHarness.sessionID))
        }
    }

    /// The order the user went through on a real machine (2026-09-19): an
    /// agent run on a server that replaced an earlier one on the same
    /// socket, whose own agent left a record naming the same pane number.
    /// The run's tab is closed and opened again from the Waiting list, and
    /// then the server is killed. The conversation is still the one to
    /// resume, where it ran: its hint survives the closed tab, the Waiting
    /// list offers the run once, and the terminal the tab becomes resumes it
    /// in its own directory.
    @Test func aRunOnALaterServer_isOfferedOnceAndResumesAfterItsTabWasClosedAndReopened() async throws {
        try await withTempDir { directory in
            let harness = try AgentEndHarness(directory: directory)
            defer { harness.tearDown() }
            let launch = harness.session.openTab(container: .loose)
            let leaf = try #require(launch.splitTree.allLeafIDs().first)
            let request = try harness.request(launchPaneID: leaf)
            try harness.writeEarlierServerRecord(like: request)
            try harness.writeRecords(for: request, hasEnded: false)
            let presence = AgentEndHarness.presence(serving: request)
            let attention = AttentionState()
            harness.store.agentRuns = AgentTmuxRuns(projection: harness.projection, presence: presence)
            harness.projection.bootstrap(into: harness.session, attention: attention, tmuxPresence: presence)
            let tabID = try await harness.openMirror(request)

            // Closed with ×. tmux keeps the agent, so its hint is kept too.
            TabActions.closeTab(
                harness.session,
                registry: harness.registry,
                tabID: tabID,
                confirm: false,
                agentProjection: harness.projection
            )
            harness.projection.refresh()
            #expect(AgentRecordFixtures.hint(
                forPaneID: request.leafID,
                in: harness.hostedHintsDirectory
            ) != nil)

            // One agent is running in tmux, so the Waiting list has one row,
            // and it is that agent's. The earlier server's run ended.
            let detached = attention.detachedAgentRuns(in: harness.session)
            #expect(detached.compactMap(\.tmuxRun?.leafID) == [request.leafID])
            let run = try #require(detached.first?.tmuxRun)

            await TmuxMirrorActions.openDetachedAgentRun(
                run,
                session: harness.session,
                store: harness.store,
                toastCenter: nil
            )?.value
            let reopened = try #require(harness.tab(of: request)?.id)
            let mirror = try #require(harness.store.liveMirror(for: reopened))
            #expect(await waitUntil { mirror.connection.state == .attached })
            #expect(attention.detachedAgentRuns(in: harness.session).isEmpty)

            harness.server.run(["kill-server"])

            #expect(await waitUntil(.seconds(5)) { harness.session.tab(reopened)?.kind == .terminal })
            let tab = try #require(harness.session.tab(reopened))
            #expect(tab.splitTree.allLeafIDs() == [request.leafID])
            let command = try #require(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: request.leafID))
            #expect(command == CodexAgent.resumeCommand(sessionId: AgentEndHarness.sessionID, cwd: directory.path))
        }
    }
}
