// AgentRuntimeProjectionTests.swift
// Weir — runtime records follow live tmux clients instead of launch panes.

import Foundation
import Testing
@testable import Weir

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
            pid: nil,
            lastPrompt: nil,
            firstPrompt: nil,
            sessionStartedAt: "2026-09-09T00:00:00Z",
            killedByWeirAt: nil,
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
            let (session, tab, displayPaneID) = WorkspaceSessionFixture.withLooseTab()
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
                    socketPath: "/tmp/tmux-501/default",
                    sessionID: "$2",
                    sessionName: "work"
                )
            ], topology: TmuxTopology.onePane())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )

            projection.bootstrap(into: session, tmuxPresence: presence)

            #expect(session.tab(tab.id)?.agentBadges[.codex]?[displayPaneID]?.state == .running)
            #expect(session.tab(tab.id)?.agentBadges[.codex, default: [:]][launchPaneID] == nil)
        }
    }

    @Test("aggregates multiple agents in one tmux session by priority")
    func bootstrap_multipleAgents_usesDominantState() throws {
        try withTempDir { directory in
            let (session, tab, displayPaneID) = WorkspaceSessionFixture.withLooseTab()
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
                    socketPath: "/tmp/tmux-501/default",
                    sessionID: "$2",
                    sessionName: "work"
                )
            ], topology: TmuxTopology.onePane())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )

            projection.bootstrap(into: session, tmuxPresence: presence)

            #expect(session.tab(tab.id)?.agentBadges[.codex]?[displayPaneID]?.state == .needsInput)
        }
    }

    @Test func unresolvedTmux_doesNotUseLaunchPaneOrSavedBinding() throws {
        try withTempDir { directory in
            let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            var runtime = record(runID: UUID(), launchPaneID: paneID, state: "running", revision: 1)
            runtime.tmuxSocketPath = nil
            runtime.tmuxPaneId = nil
            try AgentRecordFixtures.write(runtime, to: states)
            session.update(tab.id) {
                $0.tmuxBindings[paneID] = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "old")
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

    @Test func multipleRuns_keepIndependentAttentionAndDoNotComparePeerRevisions() throws {
        try withTempDir { directory in
            let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            let attention = AttentionState()
            let first = record(runID: UUID(), launchPaneID: paneID, state: "finished", revision: 99)
            var second = record(runID: UUID(), launchPaneID: paneID, state: "finished", revision: 1)
            second.updatedAt = "2026-09-09T00:01:00Z"
            try AgentRecordFixtures.write(first, to: states)
            try AgentRecordFixtures.write(second, to: states)
            let presence = TmuxPanePresence(bindingsByPaneID: [paneID: TmuxBinding(
                socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "work"
            )], topology: TmuxTopology.onePane())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )
            projection.bootstrap(into: session, attention: attention, tmuxPresence: presence)
            #expect(attention.queueItems(in: session).count == 2)
            #expect(session.tab(tab.id)?.agentBadges[.codex]?[paneID]?.updatedAt == AgentDateParsing.parseISO8601(second.updatedAt))
            // Reading one run's finish leaves the other's waiting.
            let firstID = AgentRuntimePresentation.id(kind: .codex, runID: first.storageID)
            let firstToken = try #require(attention.allRuntimes.first { $0.id == firstID }?.attentionEventToken)
            attention.markFinishedRuntimesViewed(matching: [firstID: [firstToken]])
            #expect(attention.queueItems(in: session).map(\.subject.runtimeID) == [AgentRuntimePresentation.id(
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

    @Test func twoRunsInOneTmuxSession_eachKeepsItsOwnLocationInTheirSharedPane() throws {
        // Both runs reach the pane through one tmux client: the front run
        // from the active tmux pane, the other from a pane behind it. The
        // front run's record is read last (its file name sorts after), which
        // used to leave its location on the pane for both runs.
        try withTempDir { directory in
            let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            let attention = AttentionState()
            let behindRunID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let frontRunID = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
            var behind = record(runID: behindRunID, launchPaneID: paneID, state: "finished", revision: 1)
            behind.tmuxPaneId = "%5"
            let front = record(runID: frontRunID, launchPaneID: paneID, state: "finished", revision: 1)
            try AgentRecordFixtures.write(behind, to: states)
            try AgentRecordFixtures.write(front, to: states)
            let topology = TmuxTopology(panes: TmuxTopology.parsePanes(
                "42\t100\t$2\t@3\t%4\t1\t1\n42\t100\t$2\t@3\t%5\t1\t0\n",
                socketPath: "/private/tmp/tmux-501/default"
            ), socketAliases: ["/tmp/tmux-501/default": "/private/tmp/tmux-501/default"])
            let presence = TmuxPanePresence(bindingsByPaneID: [paneID: TmuxBinding(
                socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "work"
            )], topology: topology)
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )
            projection.bootstrap(into: session, attention: attention, tmuxPresence: presence)

            let runs = Dictionary(uniqueKeysWithValues: attention.allRuntimes.map { ($0.runID, $0) })
            let frontRun = try #require(runs[front.storageID])
            let behindRun = try #require(runs[behind.storageID])
            #expect(frontRun.paneIDs == [paneID] && behindRun.paneIDs == [paneID])
            #expect(frontRun.tmuxLocations[paneID]?.paneID == "%4")
            #expect(frontRun.activeAttachmentPaneIDs == [paneID])
            #expect(behindRun.tmuxLocations[paneID]?.paneID == "%5")
            #expect(behindRun.activeAttachmentPaneIDs.isEmpty)

            // Both turns are finished. Looking at the pane reads the front
            // run's turn and not the turn of the run behind it.
            projection.seenPanes = { [paneID] }
            projection.refresh()
            #expect(attention.isViewed(frontRun))
            #expect(!attention.isViewed(behindRun))
        }
    }

    @Test func aRecordOfAnEarlierTmuxServer_doesNotHideTheNewRunInItsPane() throws {
        // The tmux server was started again on the same socket and numbered
        // its panes from the start. The old server's run left its record,
        // which is read first (its file name sorts first) and names the same
        // tmux pane as the new run.
        try withTempDir { directory in
            let (session, tab, displayPaneID) = WorkspaceSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            let attention = AttentionState()
            let staleRunID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let freshRunID = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
            var stale = record(runID: staleRunID, launchPaneID: UUID(), state: "finished", revision: 1)
            stale.tmuxServerPID = "41"
            stale.tmuxServerStartedAt = "90"
            let fresh = record(runID: freshRunID, launchPaneID: UUID(), state: "running", revision: 1)
            try AgentRecordFixtures.write(stale, to: states)
            try AgentRecordFixtures.write(fresh, to: states)
            var probed = TmuxTopology.onePane()
            // The socket answered, so a run it does not list is detached.
            probed.outcomes = ["/private/tmp/tmux-501/default": .success("")]
            let presence = TmuxPanePresence(bindingsByPaneID: [displayPaneID: TmuxBinding(
                socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "work"
            )], topology: probed)
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )
            projection.bootstrap(into: session, attention: attention, tmuxPresence: presence)

            let runs = Dictionary(uniqueKeysWithValues: attention.allRuntimes.map { ($0.runID, $0) })
            #expect(runs[fresh.storageID]?.paneIDs == [displayPaneID])
            #expect(runs[stale.storageID]?.paneIDs.isEmpty == true)
            #expect(session.tab(tab.id)?.agentBadges[.codex]?[displayPaneID]?.state == .running)
        }
    }

    @Test func aRecordWithoutARunID_keepsItsTmuxLocation() throws {
        // A record from before run IDs is the run of its launch pane, and
        // the rules name the run by that pane. Where its tmux pane sits must
        // reach the run all the same.
        try withTempDir { directory in
            let (session, _, displayPaneID) = WorkspaceSessionFixture.withLooseTab()
            let states = directory.appendingPathComponent("states")
            let attention = AttentionState()
            var legacy = record(runID: UUID(), launchPaneID: UUID(), state: "running", revision: 1)
            legacy.runId = nil
            try AgentRecordFixtures.write(legacy, to: states)
            let presence = TmuxPanePresence(bindingsByPaneID: [displayPaneID: TmuxBinding(
                socketPath: "/tmp/tmux-501/default", sessionID: "$2", sessionName: "work"
            )], topology: TmuxTopology.onePane())
            let projection = ProjectionFixture.adapter(
                state: states,
                sessions: directory.appendingPathComponent("sessions")
            )
            projection.bootstrap(into: session, attention: attention, tmuxPresence: presence)

            let run = try #require(attention.allRuntimes.first)
            #expect(run.id == "codex:\(legacy.paneId)")
            #expect(run.tmuxLocations[displayPaneID]?.paneID == "%4")
            #expect(run.activeAttachmentPaneIDs == [displayPaneID])
        }
    }
}
