// AgentRuntimeProjectionTests.swift
// Limpid — runtime records follow live tmux clients instead of launch panes.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent runtime projection")
@MainActor
struct AgentRuntimeProjectionTests {
    private func record(
        runID: UUID,
        launchPaneID: UUID,
        state: String,
        revision: Int
    ) -> AgentStateRecordFixture {
        AgentStateRecordFixture(
            schemaVersion: 2,
            runId: runID.uuidString,
            revision: revision,
            paneId: launchPaneID.uuidString,
            state: state,
            detail: nil,
            runStartedAt: nil,
            updatedAt: "2026-09-09T00:00:00Z",
            lastHookEvent: "UserPromptSubmit",
            contextTokens: nil,
            pid: nil,
            lastPrompt: nil,
            firstPrompt: nil,
            sessionStartedAt: "2026-09-09T00:00:00Z",
            killedByLimpidAt: nil,
            isTmuxHosted: true,
            tmuxSocketPath: "/private/tmp/tmux-\(getuid())/default",
            tmuxSessionId: "$2",
            tmuxPaneId: "%4",
            tmuxServerPID: "42",
            tmuxServerStartedAt: "100"
        )
    }

    @Test("projects a reattached runtime onto the displaying pane")
    func bootstrap_crossPaneAttach_usesLiveClientBinding() throws {
        try withTempDir { directory in
            let (session, tab, displayPaneID) = WindowSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            let launchPaneID = UUID()
            try AgentRecordFixtures.write(record(
                runID: UUID(),
                launchPaneID: launchPaneID,
                state: "running",
                revision: 1
            ), to: states)
            let presence = TmuxPanePresence(bindingsByPaneID: [
                displayPaneID: TmuxBinding(
                    socketPath: "/tmp/tmux-\(getuid())/default",
                    sessionID: "$2",
                    sessionName: "work"
                )
            ], topology: topology())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )

            #expect(AgentRecordFixtures.records(in: states).count == 1)
            #expect(presence.paneIDs(
                socketPath: "/private/tmp/tmux-\(getuid())/default",
                sessionID: "$2"
            ) == [displayPaneID])

            projection.bootstrap(into: session, tmuxPresence: presence)

            #expect(session.tab(tab.id)?.agentBadges[.codex]?[displayPaneID]?.state == .running)
            #expect(session.tab(tab.id)?.agentBadges[.codex, default: [:]][launchPaneID] == nil)
        }
    }

    @Test("aggregates multiple agents in one tmux session by priority")
    func bootstrap_multipleAgents_usesDominantState() throws {
        try withTempDir { directory in
            let (session, tab, displayPaneID) = WindowSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            try AgentRecordFixtures.write(record(
                runID: UUID(),
                launchPaneID: UUID(),
                state: "running",
                revision: 4
            ), to: states)
            try AgentRecordFixtures.write(record(
                runID: UUID(),
                launchPaneID: UUID(),
                state: "needsInput",
                revision: 1
            ), to: states)
            let presence = TmuxPanePresence(bindingsByPaneID: [
                displayPaneID: TmuxBinding(
                    socketPath: "/tmp/tmux-\(getuid())/default",
                    sessionID: "$2",
                    sessionName: "work"
                )
            ], topology: topology())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )

            #expect(AgentRecordFixtures.records(in: states).count == 2)
            #expect(presence.paneIDs(
                socketPath: "/private/tmp/tmux-\(getuid())/default",
                sessionID: "$2"
            ) == [displayPaneID])

            projection.bootstrap(into: session, tmuxPresence: presence)

            #expect(session.tab(tab.id)?.agentBadges[.codex]?[displayPaneID]?.state == .needsInput)
        }
    }

    private func topology(sessionID: String = "$2", start: String = "100") -> TmuxTopology {
        TmuxTopology(panes: TmuxTopology.parsePanes(
            "42\t\(start)\t\(sessionID)\t@3\t%4\t1\t1\n",
            socketPath: "/private/tmp/tmux-\(getuid())/default"
        ), socketAliases: ["/tmp/tmux-\(getuid())/default": "/private/tmp/tmux-\(getuid())/default"])
    }

    @Test func unresolvedTmux_doesNotUseLaunchPaneOrSavedBinding() throws {
        try withTempDir { directory in
            let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            var runtime = record(runID: UUID(), launchPaneID: paneID, state: "running", revision: 1)
            runtime.tmuxSocketPath = nil
            runtime.tmuxPaneId = nil
            try AgentRecordFixtures.write(runtime, to: states)
            session.update(tab.id) {
                $0.tmuxBindings[paneID] = TmuxBinding(socketPath: "/tmp/tmux-\(getuid())/default", sessionID: "$2", sessionName: "old")
            }
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )
            projection.bootstrap(into: session, tmuxPresence: TmuxPanePresence())
            #expect(session.tab(tab.id)?.agentBadges[.codex, default: [:]][paneID] == nil)
            #expect(AgentRecordFixtures.records(in: states).count == 1)
        }
    }

    @Test func topology_followsMovedPaneAndRejectsReusedServerIDs() {
        let runtime = record(runID: UUID(), launchPaneID: UUID(), state: "running", revision: 1)
        #expect(topology(sessionID: "$9").locations(for: runtime.tmuxEndpoint).map(\.sessionID) == ["$9"])
        #expect(topology(start: "101").locations(for: runtime.tmuxEndpoint).isEmpty)
        var shared = topology()
        shared.panes += topology(sessionID: "$9").panes
        #expect(shared.locations(for: runtime.tmuxEndpoint).count == 2)
    }

    @Test func attentionEpisodeToken_survivesSameStateRevisionsAndChangesAfterResolution() {
        let runID = UUID().uuidString
        let paneID = UUID()
        func runtime(_ state: AgentState, revision: Int) -> AgentRuntimePresentation {
            AgentRuntimePresentation(
                kind: .codex,
                runID: runID,
                revision: revision,
                badge: AgentBadge(state: state, updatedAt: Date()),
                paneIDs: [paneID],
                tmuxLocations: [:]
            )
        }

        var tracker = AgentStateEpisodeTracker()
        let firstWait = tracker.stamp([runtime(.needsInput, revision: 2)])[0]
        let updatedWait = tracker.stamp([runtime(.needsInput, revision: 3)])[0]
        let running = tracker.stamp([runtime(.running, revision: 4)])[0]
        let nextWait = tracker.stamp([runtime(.needsInput, revision: 5)])[0]

        #expect(firstWait.attentionEventToken == "2")
        #expect(updatedWait.attentionEventToken == firstWait.attentionEventToken)
        #expect(running.attentionEventToken == "4")
        #expect(nextWait.attentionEventToken == "5")
    }

    @Test func attentionEpisodeToken_usesPersistedTokenAfterTrackerRestart() {
        let persisted = AgentRuntimePresentation(
            kind: .codex,
            runID: UUID().uuidString,
            revision: 3,
            badge: AgentBadge(state: .needsInput, updatedAt: Date()),
            paneIDs: [UUID()],
            tmuxLocations: [:],
            stateEpisodeToken: "2"
        )

        var restartedTracker = AgentStateEpisodeTracker()
        #expect(restartedTracker.stamp([persisted])[0].attentionEventToken == "2")
    }

    @Test func backgroundTmuxPane_isNotMarkedViewedByOuterFocus() {
        let runtimeRecord = record(runID: UUID(), launchPaneID: UUID(), state: "finished", revision: 2)
        let badge = AgentBadge(state: .finished, updatedAt: Date())
        let paneID = UUID()
        let location = TmuxPaneLocation(
            socketPath: "/tmp/s",
            serverPID: "42",
            serverStartedAt: "100",
            sessionID: "$2",
            windowID: "@3",
            paneID: "%4",
            isActive: false
        )
        let runtime = AgentRuntimePresentation(
            kind: .codex,
            runID: runtimeRecord.storageID,
            revision: 2,
            badge: badge,
            paneIDs: [paneID],
            tmuxLocations: [paneID: location]
        )
        let attention = AttentionState()
        attention.replaceRuntimes([runtime], kind: .codex)
        attention.markVisibleRuntimesViewed(paneID: paneID)
        #expect(!attention.isViewed(runtime))
    }

    @Test func cleanupOldRun_preservesNewRunsResumeHint() throws {
        try withTempDir { directory in
            let states = directory.appendingPathComponent("states")
            let sessions = directory.appendingPathComponent("sessions")
            let paneID = UUID()
            var old = record(runID: UUID(), launchPaneID: paneID, state: "idle", revision: 1)
            old.isTmuxHosted = false
            old.tmuxSocketPath = nil
            old.tmuxPaneId = nil
            old.pid = "2147483646"
            var current = old
            current.runId = UUID().uuidString
            current.pid = String(getpid())
            try AgentRecordFixtures.write(old, to: states)
            try AgentRecordFixtures.write(current, to: states)
            let hint = AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: current.updatedAt,
                runId: current.runId
            )
            try AgentRecordFixtures.write(hint, to: sessions)
            let projection = ProjectionFixture.adapter(state: states, sessions: sessions)
            projection.prepareForLaunch()
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: sessions) == hint)
            #expect(AgentRecordFixtures.records(in: states).map(\.storageID) == [current.storageID])
        }
    }

    @Test func multipleRuns_keepIndependentAttentionAndDoNotComparePeerRevisions() throws {
        try withTempDir { directory in
            let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            let attention = AttentionState()
            let first = record(runID: UUID(), launchPaneID: paneID, state: "finished", revision: 99)
            var second = record(runID: UUID(), launchPaneID: paneID, state: "finished", revision: 1)
            second.updatedAt = "2026-09-09T00:01:00Z"
            try AgentRecordFixtures.write(first, to: states)
            try AgentRecordFixtures.write(second, to: states)
            let presence = TmuxPanePresence(bindingsByPaneID: [paneID: TmuxBinding(
                socketPath: "/tmp/tmux-\(getuid())/default", sessionID: "$2", sessionName: "work"
            )], topology: topology())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )
            projection.bootstrap(into: session, attention: attention, tmuxPresence: presence)
            #expect(attention.attentionEntries(in: session).count == 2)
            #expect(session.tab(tab.id)?.agentBadges[.codex]?[paneID]?.updatedAt == AgentDateParsing.parseISO8601(second.updatedAt))
            attention.dismissRuntime(AgentRuntimePresentation.id(kind: .codex, runID: first.storageID))
            #expect(attention.attentionEntries(in: session).map(\.runtimeID) == [AgentRuntimePresentation.id(
                kind: .codex,
                runID: second.storageID
            )])
            second.state = "running"
            second.revision = 2
            try AgentRecordFixtures.write(second, to: states)
            projection.refresh()
            #expect(session.tab(tab.id)?.agentBadges[.codex]?[paneID]?.state == .running)
            second.state = "error"
            second.revision = 1
            try AgentRecordFixtures.write(second, to: states)
            projection.refresh()
            #expect(session.tab(tab.id)?.agentBadges[.codex]?[paneID]?.state == .running)
        }
    }
}
