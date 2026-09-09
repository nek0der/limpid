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
    ) -> CodexAgentStateRecord {
        CodexAgentStateRecord(
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
            tmuxSocketPath: "/private/tmp/tmux-501/default",
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
            let store = CodexAgentStateStore(directory: directory)
            let launchPaneID = UUID()
            try store.save(record(
                runID: UUID(),
                launchPaneID: launchPaneID,
                state: "running",
                revision: 1
            ))
            let presence = TmuxPanePresence(bindingsByPaneID: [
                displayPaneID: TmuxBinding(
                    socketPath: "/tmp/tmux-501/default",
                    sessionID: "$2",
                    sessionName: "work"
                )
            ], topology: topology())
            let tracker = CodexAgentStateTracker(
                store: store,
                sessionStore: CodexSessionStore(
                    directory: directory.appendingPathComponent("sessions")
                )
            )

            #expect(store.allRecords().count == 1)
            #expect(presence.paneIDs(
                socketPath: "/private/tmp/tmux-501/default",
                sessionID: "$2"
            ) == [displayPaneID])

            tracker.bootstrap(into: session, tmuxPresence: presence)

            #expect(session.tab(tab.id)?.codexAgentBadges[displayPaneID]?.state == .running)
            #expect(session.tab(tab.id)?.codexAgentBadges[launchPaneID] == nil)
        }
    }

    @Test("aggregates multiple agents in one tmux session by priority")
    func bootstrap_multipleAgents_usesDominantState() throws {
        try withTempDir { directory in
            let (session, tab, displayPaneID) = WindowSessionFixture.withLooseTab()
            let store = CodexAgentStateStore(directory: directory)
            try store.save(record(
                runID: UUID(),
                launchPaneID: UUID(),
                state: "running",
                revision: 4
            ))
            try store.save(record(
                runID: UUID(),
                launchPaneID: UUID(),
                state: "needsInput",
                revision: 1
            ))
            let presence = TmuxPanePresence(bindingsByPaneID: [
                displayPaneID: TmuxBinding(
                    socketPath: "/tmp/tmux-501/default",
                    sessionID: "$2",
                    sessionName: "work"
                )
            ], topology: topology())
            let tracker = CodexAgentStateTracker(
                store: store,
                sessionStore: CodexSessionStore(
                    directory: directory.appendingPathComponent("sessions")
                )
            )

            #expect(store.allRecords().count == 2)
            #expect(presence.paneIDs(
                socketPath: "/private/tmp/tmux-501/default",
                sessionID: "$2"
            ) == [displayPaneID])

            tracker.bootstrap(into: session, tmuxPresence: presence)

            #expect(session.tab(tab.id)?.codexAgentBadges[displayPaneID]?.state == .needsInput)
        }
    }

    private func topology(sessionID: String = "$2", start: String = "100") -> TmuxTopology {
        TmuxTopology(panes: TmuxTopology.parsePanes(
            "42\t\(start)\t\(sessionID)\t@3\t%4\t1\t1\n",
            socketPath: "/private/tmp/tmux-501/default"
        ), socketAliases: ["/tmp/tmux-501/default": "/private/tmp/tmux-501/default"])
    }

    @Test func unresolvedTmux_doesNotUseLaunchPaneOrSavedBinding() throws {
        try withTempDir { directory in
            let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
            let store = CodexAgentStateStore(directory: directory)
            var runtime = record(runID: UUID(), launchPaneID: paneID, state: "running", revision: 1)
            runtime.tmuxSocketPath = nil
            runtime.tmuxPaneId = nil
            try store.save(runtime)
            session.update(tab.id) {
                $0.tmuxBindings[paneID] = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "old")
            }
            let tracker = CodexAgentStateTracker(
                store: store,
                sessionStore: CodexSessionStore(directory: directory.appendingPathComponent("sessions"))
            )
            tracker.bootstrap(into: session, tmuxPresence: TmuxPanePresence())
            #expect(session.tab(tab.id)?.codexAgentBadges[paneID] == nil)
            #expect(store.allRecords().count == 1)
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

    @Test func notifications_arePerRunNotPerClientAndIgnoreReattach() throws {
        let record = record(runID: UUID(), launchPaneID: UUID(), state: "needsInput", revision: 2)
        let badge = try #require(CodexAgent.makeBadge(from: record))
        let runtime = AgentRuntimePresentation(
            kind: .codex,
            runID: record.storageID,
            revision: 2,
            badge: badge,
            paneIDs: [UUID(), UUID()],
            tmuxLocations: [:]
        )
        let transitions = AgentRuntimeTransition.notifications(current: [runtime], previous: [:])
        #expect(transitions.count == 1)
        #expect(AgentRuntimeTransition.notifications(current: [runtime], previous: [runtime.runID: badge]).isEmpty)
        let other = AgentRuntimePresentation(
            kind: .codex,
            runID: UUID().uuidString,
            revision: 1,
            badge: badge,
            paneIDs: runtime.paneIDs,
            tmuxLocations: [:]
        )
        #expect(AgentRuntimeTransition.notifications(current: [runtime, other], previous: [runtime.runID: badge]).count == 1)
    }

    @Test func backgroundTmuxPane_isNotMarkedViewedByOuterFocus() throws {
        let runtimeRecord = record(runID: UUID(), launchPaneID: UUID(), state: "finished", revision: 2)
        let badge = try #require(CodexAgent.makeBadge(from: runtimeRecord))
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
            let store = CodexAgentStateStore(directory: directory.appendingPathComponent("states"))
            let sessions = CodexSessionStore(directory: directory.appendingPathComponent("sessions"))
            let paneID = UUID()
            var old = record(runID: UUID(), launchPaneID: paneID, state: "idle", revision: 1)
            old.isTmuxHosted = false
            old.tmuxSocketPath = nil
            old.tmuxPaneId = nil
            old.pid = "2147483646"
            var current = old
            current.runId = UUID().uuidString
            current.pid = String(getpid())
            try store.save(old)
            try store.save(current)
            let hint = CodexSessionRecord(
                schemaVersion: 1,
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: current.updatedAt,
                runId: current.runId
            )
            try sessions.save(hint)
            let tracker = CodexAgentStateTracker(store: store, sessionStore: sessions)
            tracker.cleanupDeadSessionsOnLaunch()
            #expect(sessions.record(forPaneID: paneID) == hint)
            #expect(store.allRecords().map(\.storageID) == [current.storageID])
        }
    }

    @Test func multipleRuns_keepIndependentAttentionAndDoNotComparePeerRevisions() throws {
        try withTempDir { directory in
            let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
            let store = CodexAgentStateStore(directory: directory)
            let attention = AttentionState()
            let first = record(runID: UUID(), launchPaneID: paneID, state: "finished", revision: 99)
            var second = record(runID: UUID(), launchPaneID: paneID, state: "finished", revision: 1)
            second.updatedAt = "2026-09-09T00:01:00Z"
            try store.save(first)
            try store.save(second)
            let presence = TmuxPanePresence(bindingsByPaneID: [paneID: TmuxBinding(
                socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "work"
            )], topology: topology())
            let tracker = CodexAgentStateTracker(
                store: store,
                sessionStore: CodexSessionStore(directory: directory.appendingPathComponent("sessions"))
            )
            tracker.bootstrap(into: session, attention: attention, tmuxPresence: presence)
            #expect(attention.attentionEntries(in: session).count == 2)
            #expect(session.tab(tab.id)?.codexAgentBadges[paneID]?.updatedAt == AgentDateParsing.parseISO8601(second.updatedAt))
            attention.dismissRuntime(AgentRuntimePresentation.id(kind: .codex, runID: first.storageID))
            #expect(attention.attentionEntries(in: session).map(\.runtimeID) == [AgentRuntimePresentation.id(
                kind: .codex,
                runID: second.storageID
            )])
            second.state = "running"
            second.revision = 2
            try store.save(second)
            tracker.refreshPresentation()
            #expect(session.tab(tab.id)?.codexAgentBadges[paneID]?.state == .running)
            second.state = "error"
            second.revision = 1
            try store.save(second)
            tracker.refreshPresentation()
            #expect(session.tab(tab.id)?.codexAgentBadges[paneID]?.state == .running)
        }
    }
}
