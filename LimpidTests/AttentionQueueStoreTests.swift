// AttentionQueueStoreTests.swift
// Limpid — the attention list's input built from runtimes, the ledger, and what the person sees.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct AttentionQueueStoreTests {
    private static func runtime(
        _ state: AgentState,
        panes: Set<UUID>,
        tmux: [UUID: TmuxPaneLocation] = [:],
        id: String = "run"
    ) -> AgentRuntimePresentation {
        AgentRuntimePresentation.test(
            runID: id,
            badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: 100)),
            paneIDs: panes,
            tmuxLocations: tmux,
            stateEpisodeToken: "episode"
        )
    }

    private static func tmux(isActive: Bool) -> TmuxPaneLocation {
        TmuxPaneLocation(
            socketPath: "/tmp/s", serverPID: "1", serverStartedAt: "0",
            sessionID: "$1", windowID: "@1", paneID: "%1", isActive: isActive
        )
    }

    @Test func aRuntime_isShownInAPaneInATab() throws {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        let outside = UUID()
        let runtime = Self.runtime(.error, panes: [paneID, outside])

        let input = AttentionQueueStore.makeInput(
            runtimes: [runtime],
            isRead: { _ in false },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )

        let fact = try #require(input.runtimes.first)
        // The pane in no tab is left out.
        #expect(fact.paneIDs == [paneID])
        #expect(fact.tabID == tab.id)
        #expect(fact.episodeToken == "episode")
        #expect(fact.state == .error)
    }

    @Test func aRuntimeInNoTab_isLeftOut() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let input = AttentionQueueStore.makeInput(
            runtimes: [Self.runtime(.error, panes: [UUID()])],
            isRead: { _ in false },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        #expect(input.runtimes.isEmpty)
    }

    @Test func theReadMark_comesFromTheProjection() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let input = AttentionQueueStore.makeInput(
            runtimes: [Self.runtime(.finished, panes: [paneID])],
            isRead: { _ in true },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        #expect(input.runtimes.first?.isEpisodeRead == true)
    }

    @Test func onlyPanesComingIntoSight_areRead() {
        let stayed = UUID()
        let arrived = UUID()
        let left = UUID()
        let coming = AttentionQueueStore.panesComingIntoSight(previous: [stayed, left], current: [stayed, arrived])
        #expect(coming == [arrived])
    }

    @Test func aRuntimeInSeveralPanes_isShownInTheFocusedOne() {
        // A tmux session attached in two tabs; the active tab's pane has focus.
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        let panes: Set<UUID> = [fixture.paneA, fixture.paneB]

        let input = AttentionQueueStore.makeInput(
            runtimes: [Self.runtime(.error, panes: panes)],
            isRead: { _ in false },
            approvals: [],
            session: fixture.session,
            isApprovalServiceRunning: false
        )

        #expect(input.runtimes.first?.paneIDs.first == fixture.paneA)
        #expect(input.runtimes.first?.tabID == fixture.tabA.id)
        #expect(input.runtimes.first?.paneIDs.count == 2)
    }

    @Test func newItems_areAnnouncedOnlyOnceRuntimesAreMatched() {
        let store = AttentionQueueStore()
        var performed: [[AttentionEffect]] = []
        store.performEffects = { performed.append($0) }
        let stop = RuntimeFact.test("a", .error)
        let later = RuntimeFact.test("b", .error)

        store.apply(.init(runtimes: [stop]), announces: false)
        #expect(store.queue.items.count == 1)
        #expect(performed.isEmpty, "what was waiting at launch is not read out")

        store.apply(.init(runtimes: [stop, later]), announces: true)
        #expect(performed == [[.announce(.stop(EpisodeKey(origin: .runtime("b"), episodeToken: "1")))]])
    }

    /// With and without an earlier turn the person has not viewed, which
    /// the bar counts first: the bar reads "2 / 2" with one and has no
    /// count without.
    @Test(arguments: [false, true])
    func aRejectedHandOff_givesTheBarToTheNextRequest_notTheStaleOne(hasEarlierUnviewedTurn: Bool) {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
        }
        let epoch = UUID()
        func request() -> ApprovalPresentation {
            ApprovalPresentation.test(epoch: epoch, sessionID: "session", toolName: "Write")
        }
        func apply(pending: [ApprovalPresentation], terminals: [String: BrokerTerminal] = [:], seenAt: Date) {
            store.apply(
                ApprovalControllerConnection.Projection(
                    sequence: 1, requests: pending, terminals: terminals, missingIDs: [],
                    unevictableCount: pending.count, deadlines: [:]
                ),
                epoch: epoch,
                now: SuspendingClock.now,
                seenAt: seenAt
            )
        }
        /// The run, running since the prompt `promptAt` started its turn.
        func promptedRun(at promptAt: TimeInterval, revision: Int) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                revision: revision,
                badge: AgentBadge(state: .running, runStartedAt: Date(timeIntervalSince1970: promptAt), updatedAt: Date()),
                paneIDs: [paneID],
                stateEpisodeToken: "episode",
                sessionID: "session"
            )
        }
        // The first turn changed a file, ended before either request, and
        // was not viewed.
        let unviewed = UnreadTurnEntry(
            turn: UnreadTurn(turnID: TurnID("t1"), numbers: 1...1, changes: .changed(files: 1, added: 1, removed: 0)),
            arrivedAt: Date(timeIntervalSince1970: 990)
        )
        /// What the pane's bar is on, after the pass the app makes.
        func bar(_ run: AgentRuntimePresentation) -> DecisionBarContent {
            store.runtimes = { [run] }
            store.releaseStaleApprovals(in: session)
            let input = AttentionQueueStore.makeInput(
                runtimes: [run],
                isRead: { _ in false },
                unreadTurns: hasEarlierUnviewedTurn ? [run.id: [unviewed]] : [:],
                approvals: store.placedApprovals(in: session),
                session: session,
                isApprovalServiceRunning: true
            )
            let items = AttentionQueueReducer.reduce(AttentionQueue(), input: input).0.items(inPane: paneID)
            return DecisionBarContent.make(.init(items: items))
        }
        // An approval outranks the unviewed turn, and is counted after it.
        let position = hasEarlierUnviewedTurn ? DecisionBarContent.Position(index: 2, count: 2, higherKind: nil) : nil

        // The first request is handed to the TUI, where the person says "No".
        let rejected = request()
        apply(pending: [rejected], seenAt: Date(timeIntervalSince1970: 1000))
        apply(pending: [], terminals: [rejected.id: .resolved(.delegate)], seenAt: Date(timeIntervalSince1970: 1000))
        let before = bar(promptedRun(at: 995, revision: 1))
        #expect(before.itemID == .approval(rejected.key))
        #expect(before.position == position)

        // No hook follows the "No"; the next prompt does, and the request
        // it leads to arrives after it.
        let next = request()
        apply(pending: [next], seenAt: Date(timeIntervalSince1970: 1002))

        let after = bar(promptedRun(at: 1001, revision: 2))
        #expect(after.itemID == .approval(next.key))
        #expect(after.position == position, "the rejected request is gone, not counted beside the next one")
        #expect(store.ledger.entry(for: rejected) == nil)
    }
}
