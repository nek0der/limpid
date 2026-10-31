// AttentionStateTests.swift
// Weir — `AttentionState`: when a run counts as viewed, which runs are at
// work, the pane a run is shown in, passes that change nothing, a new
// episode, and the count of running agents.

import Foundation
import Testing
@testable import Weir

@MainActor
struct AttentionStateTests {
    /// Build a Claude badge in a given state stamped at `epoch` seconds.
    private func badge(_ state: AgentState, at epoch: TimeInterval) -> AgentBadge {
        AgentBadge(
            state: state,
            detail: nil,
            // A run at work is in a turn here, as one that took a prompt is.
            runStartedAt: state.isMidTurn ? Date(timeIntervalSince1970: epoch) : nil,
            updatedAt: Date(timeIntervalSince1970: epoch),
            lastPrompt: nil
        )
    }

    /// Add a fresh tab carrying one pane with the given Claude badge;
    /// returns the pane id. Attention reads only the runtime projection,
    /// so the helper publishes a matching Claude runtime as well as
    /// writing the session badge.
    private func paneWithBadge(
        _ session: WorkspaceSession,
        _ attention: AttentionState,
        _ state: AgentState,
        at epoch: TimeInterval,
        in container: ContainerID = .loose
    ) -> UUID {
        let tab = session.openTab(container: container)
        let paneID = tab.splitTree.allLeafIDs()[0]
        setBadge(session, attention, paneID: paneID, state, at: epoch)
        return paneID
    }

    /// The runtime id `paneWithBadge` publishes for a pane. The run id is
    /// derived from the pane id so a test can address the runtime without
    /// threading an extra identifier through every helper.
    private func runtimeID(for paneID: UUID) -> String {
        AgentRuntimePresentation.id(kind: .claude, runID: paneID.uuidString)
    }

    /// Write a pane's Claude badge and republish its runtime. The episode
    /// token folds in the stamp, so restating a pane at a later epoch is a
    /// new attention episode and clears any earlier viewed mark.
    private func setBadge(
        _ session: WorkspaceSession,
        _ attention: AttentionState,
        paneID: UUID,
        _ state: AgentState,
        at epoch: TimeInterval
    ) {
        let written = badge(state, at: epoch)
        if let tab = session.tab(containing: paneID) {
            session.update(tab.id) { $0.agentBadges[.claude, default: [:]][paneID] = written }
        }
        let runtime = AgentRuntimePresentation.test(
            runID: paneID.uuidString,
            revision: Int(epoch),
            badge: written,
            paneIDs: [paneID],
            stateEpisodeToken: "\(paneID.uuidString):\(epoch)"
        )
        let others = (attention.runtimesByKind[.claude] ?? []).filter { $0.runID != paneID.uuidString }
        attention.replaceRuntimes(others + [runtime], kind: .claude)
    }

    private func runtime(
        _ state: AgentState,
        paneID: UUID,
        revision: Int,
        episode: String
    ) -> AgentRuntimePresentation {
        AgentRuntimePresentation.test(
            kind: .codex,
            revision: revision,
            badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: TimeInterval(revision))),
            paneIDs: [paneID],
            stateEpisodeToken: episode
        )
    }

    /// The Claude runtime `paneWithBadge` published for a pane.
    private func publishedRuntime(_ attention: AttentionState, for paneID: UUID) -> AgentRuntimePresentation? {
        attention.allRuntimes.first { $0.id == runtimeID(for: paneID) }
    }

    @Test func focusMoved_marksAFinishedRunViewed() throws {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        let runtime = try #require(publishedRuntime(attention, for: pane))
        #expect(!attention.isViewed(runtime))

        attention.focusMoved(to: pane, in: session)

        // Viewing is not completing: the run is only flagged viewed.
        #expect(attention.isViewed(runtime))
    }

    /// Items are keyed by runtime, not by pane: a pane where the user ran
    /// both Claude and Codex in the same shell lists both finished turns.
    /// Keying by pane would collapse them into one item and hide a freshly
    /// finished Codex turn behind a stale Claude one.
    @Test func claudeAndCodexFinishedInOnePane_areBothListed() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .finished, at: 200)
        let codexID = AgentRuntimePresentation.id(kind: .codex, runID: "run")
        attention.replaceRuntimes(
            [runtime(.finished, paneID: pane, revision: 100, episode: "codex-100")],
            kind: .codex
        )

        let items = attention.queueItems(in: session)
        #expect(Set(items.compactMap(\.subject.runtimeID)) == [codexID, runtimeID(for: pane)])
        #expect(Set(items.compactMap(\.subject.paneID)) == [pane])
    }

    @Test func focusMoved_takesThatRunOffTheList_andLeavesTheOther() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let looked = paneWithBadge(session, attention, .finished, at: 100)
        let other = paneWithBadge(session, attention, .finished, at: 200)
        #expect(attention.queueItems(in: session).count == 2)

        attention.focusMoved(to: looked, in: session)

        #expect(attention.queueItems(in: session).compactMap(\.subject.runtimeID) == [runtimeID(for: other)])
    }

    @Test func aRunWhoseTurnsAreRecorded_isViewedAsItsTurnsSay_notByLooking() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        let recorded = runtimeID(for: pane)
        var isRead = false
        attention.turnReadDecision = { $0.id == recorded ? isRead : nil }

        attention.focusMoved(to: pane, in: session)
        let runtime = attention.allRuntimes.first { $0.id == recorded }

        #expect(runtime.map(attention.isViewed) == false, "a changed turn is not read by looking")
        isRead = true
        #expect(runtime.map(attention.isViewed) == true)
    }

    @Test func focusMoved_notifiesPaneHistorySync() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .running, at: 100)
        var focusedPane: UUID?
        attention.onPaneFocused = { focusedPane = $0 }

        attention.focusMoved(to: pane, in: session)

        #expect(focusedPane == pane)
    }

    @Test func focusMoved_doesNotMarkNeedsInputAsViewed() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .needsInput, at: 100)

        attention.focusMoved(to: pane, in: session)

        // Only finished turns carry the viewed state; needsInput stays at
        // full strength until it actually resolves.
        #expect(attention.viewedRuntimeTokens[runtimeID(for: pane)] == nil)
    }

    // MARK: - A run at work, and the pane it is shown in

    /// Every run in the workspace's panes counts, not only the one each
    /// pane's header names: a newer run resting in a pane hides an older one
    /// still at work there, which the request would not hold.
    @Test func anAgentMidTurn_isAnyRunInThePanes_notOnlyTheHeaders() {
        let pane = UUID()
        func runtime(_ id: String, _ state: AgentState, at seconds: TimeInterval) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                runID: id,
                badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: seconds)),
                paneIDs: [pane],
                stateEpisodeToken: "1"
            )
        }
        let runtimes = [runtime("working", .running, at: 100), runtime("resting", .idle, at: 200)]
        #expect(AttentionState.isAgentMidTurn(runtimes, inPanes: [pane]))
        #expect(!AttentionState.isAgentMidTurn(runtimes, inPanes: [UUID()]), "another workspace's panes")
        #expect(!AttentionState.isAgentMidTurn([runtimes[1]], inPanes: [pane]))
    }

    /// "Create PR", the new workspace sheet, and an approval card's place
    /// share one meaning of an agent at work: a run waiting on an answer
    /// has not ended its turn, so it holds the request too, even before
    /// its wait reaches the attention list.
    @Test func aRunWaitingOnAnAnswer_isAtWork_asEveryPlaceThatWaitsReadsIt() {
        let pane = UUID()
        func runtime(_ state: AgentState) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                kind: .codex,
                runID: "r",
                badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: 0)),
                paneIDs: [pane],
                stateEpisodeToken: "1"
            )
        }
        let atWork = AgentState.allCases.filter { AttentionState.isAgentMidTurn([runtime($0)], inPanes: [pane]) }
        #expect(Set(atWork) == [.running, .compacting, .needsInput])
    }

    @Test func aRuntimeIsShownInTheFocusedPane_elseItsFirstPaneInATab() throws {
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        let stale = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        func runtime(_ panes: Set<UUID>) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(kind: .codex, badge: AgentBadge(state: .finished, updatedAt: Date()), paneIDs: panes)
        }

        // A pane no tab holds any more is passed over.
        #expect(AttentionState.shownPane(of: runtime([stale, fixture.paneB]), in: fixture.session) == fixture.paneB)
        // The focused pane wins when the runtime shows there.
        #expect(AttentionState.shownPane(of: runtime([fixture.paneA, fixture.paneB]), in: fixture.session) == fixture.paneA)
        #expect(AttentionState.shownPane(of: runtime([stale]), in: fixture.session) == nil)
    }

    @Test func aRuntimeIsShownInAPaneFocusedInAnyWindow() throws {
        let session = WorkspaceSession()
        let tabs = (0..<3).map { _ in session.openTab(container: .loose) }
        let panes = try tabs.map { try #require($0.splitTree.allLeafIDs().first) }
        // Of the last two, the one sorting first is in no window's tab, so
        // only the window that shows the other can make that one win.
        let pair = [(tabs[1], panes[1]), (tabs[2], panes[2])].sorted { $0.1.uuidString < $1.1.uuidString }
        let (shownTab, shownPane) = pair[1]
        session.setActiveTab(tabs[0].id)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(shownTab.id, in: other)
        let runtime = AgentRuntimePresentation.test(
            kind: .codex,
            badge: AgentBadge(state: .finished, updatedAt: Date()),
            paneIDs: [pair[0].1, shownPane]
        )

        #expect(AttentionState.shownPane(of: runtime, in: session) == shownPane)
    }

    // MARK: - Observation hygiene

    @Test func replaceRuntimes_identicalPass_doesNotNotifyObservers() {
        // Every sidebar row and pane header derives its badge from the
        // runtimes, so a pass that found nothing new must not invalidate
        // them. `@Observable` reports every write, so the store has to
        // decline the write itself.
        let session = WorkspaceSession()
        let attention = AttentionState()
        let paneID = paneWithBadge(session, attention, .running, at: 100)
        let same = attention.runtimesByKind[.claude] ?? []

        let notified = Recorded(false)
        withObservationTracking {
            _ = attention.runtimesByKind
            _ = attention.viewedRuntimeTokens
        } onChange: {
            notified.value = true
        }
        attention.replaceRuntimes(same, kind: .claude)
        attention.replaceMarks(viewed: attention.viewedRuntimeTokens)
        #expect(!notified.value)

        // Control: a genuinely different pass must still notify, so the
        // assertion above cannot pass by the tracking being dead.
        setBadge(session, attention, paneID: paneID, .finished, at: 200)
        #expect(notified.value)
    }

    @Test func replaceRuntimes_firstPass_createsTheKeyEvenWhenEmpty() {
        // The review surface tells "no runs" from "never projected" by
        // whether the provider's key exists, so the guard must not swallow
        // the first, empty write.
        let attention = AttentionState()
        #expect(attention.runtimesByKind[.codex] == nil)

        attention.replaceRuntimes([], kind: .codex)

        #expect(attention.runtimesByKind[.codex] != nil)
    }

    // MARK: - A new episode

    @Test func aNewEpisode_startsUnviewed() throws {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        attention.replaceRuntimes([
            runtime(.finished, paneID: paneID, revision: 100, episode: "100")
        ], kind: .codex)
        attention.markVisibleRuntimesViewed(paneID: paneID)
        #expect(try attention.isViewed(#require(attention.allRuntimes.first)))

        // A new finished episode carries its own token, so the mark taken
        // against the old one no longer applies.
        attention.replaceRuntimes([
            runtime(.finished, paneID: paneID, revision: 200, episode: "new")
        ], kind: .codex)
        let next = try #require(attention.allRuntimes.first)
        #expect(!attention.isViewed(next))
    }

    // MARK: - Running agents in a project

    /// The project menu counts the runs taking a turn: running and
    /// compacting, in this project's tabs only.
    @Test func runningAgentCount_countsRunningAndCompactingRunsInTheProject() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let attention = AttentionState()
        _ = paneWithBadge(session, attention, .running, at: 100, in: .project(project.id))
        _ = paneWithBadge(session, attention, .compacting, at: 110, in: .project(project.id))
        _ = paneWithBadge(session, attention, .needsInput, at: 120, in: .project(project.id))
        _ = paneWithBadge(session, attention, .running, at: 130)
        // Work outside a turn (a stop hook's continuation) is the agent's
        // own work in the foreground, counted as a turn is.
        let outside = session.openTab(container: .project(project.id)).splitTree.allLeafIDs()[0]
        attention.replaceRuntimes((attention.runtimesByKind[.claude] ?? []) + [AgentRuntimePresentation.test(
            runID: outside.uuidString,
            badge: AgentBadge(state: .running, updatedAt: Date(timeIntervalSince1970: 140)),
            paneIDs: [outside]
        )], kind: .claude)

        #expect(attention.runningAgentCount(inProject: project.id, session: session) == 3)
        #expect(attention.runningAgentCount(inProject: UUID(), session: session) == 0)
    }

    /// One run shown in two tabs (a tmux session attached twice) is one
    /// item on the list and one running agent in the project.
    @Test func oneRunInTwoTabs_countsOnce() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let paneA = session.openTab(container: .project(project.id)).splitTree.allLeafIDs()[0]
        let paneB = session.openTab(container: .project(project.id)).splitTree.allLeafIDs()[0]
        let attention = AttentionState()
        let finished = AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 100))
        attention.replaceRuntimes([AgentRuntimePresentation.test(
            kind: .codex,
            runID: UUID().uuidString,
            badge: finished,
            paneIDs: [paneA, paneB]
        )], kind: .codex)
        #expect(attention.queueItems(in: session).count == 1)

        let running = AgentBadge(
            state: .running,
            runStartedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        attention.replaceRuntimes([AgentRuntimePresentation.test(
            kind: .codex,
            runID: UUID().uuidString,
            revision: 2,
            badge: running,
            paneIDs: [paneA, paneB]
        )], kind: .codex)
        #expect(attention.runningAgentCount(inProject: project.id, session: session) == 1)
    }

    /// The episode token comes from the rules (`episode_token` in
    /// `projection.rs`, pinned by `lifecycle.rs`'s tests); the host keys
    /// attention by it, and by the record's own token only when it has none.
    @Test func attentionEventToken_isTheEpisodesTokenWhenThereIsOne() {
        func runtime(episode: String?) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                kind: .codex,
                runID: UUID().uuidString,
                revision: 3,
                badge: AgentBadge(state: .needsInput, updatedAt: Date()),
                paneIDs: [UUID()],
                stateEpisodeToken: episode
            )
        }

        #expect(runtime(episode: "2").attentionEventToken == "2")
        #expect(runtime(episode: nil).attentionEventToken == "3")
    }

    /// Focus on the Weir pane shows only the tmux pane in front there; a
    /// run in a tmux pane behind it has not been seen.
    @Test func backgroundTmuxPane_isNotMarkedViewedByOuterFocus() {
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
        let runtime = AgentRuntimePresentation.test(
            kind: .codex,
            runID: UUID().uuidString,
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
}
