// ApprovalDelegationTests.swift
// Weir — decisions sent through the ledger, and decisions another answer beat.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ApprovalDelegationTests {
    private struct Offline: Error {}

    /// A store holding one pending request, whose decisions `sender` answers.
    private static func store(
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
    ) -> (ApprovalPresentationStore, ApprovalPresentation) {
        let store = ApprovalPresentationStore(decisionSender: sender)
        let request = ApprovalPresentation.test()
        store.receive([request])
        return (store, request)
    }

    @Test func aDecision_goesThroughSendingToAnswered() async {
        let (store, request) = Self.store { _, _ in }

        store.resolve(request, .allowOnce)
        guard case .sending(.allowOnce, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be sending")
            return
        }
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
    }

    @Test func aFailedSend_canBeRetried() async {
        let attempts = DecisionRecorder()
        let (store, request) = Self.store { _, _ in
            if await attempts.next() == 1 {
                throw Offline()
            }
        }

        store.resolve(request, .deny)
        await store.waitUntilResolved(request)
        guard case .sendFailed(.deny, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected a failed send")
            return
        }
        #expect(store.lastFailureID == request.id)

        store.resolve(request, .deny)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .answered(.deny))
        #expect(store.lastFailureID == nil)
    }

    @Test(arguments: [
        (BrokerTerminal.resolved(.deny), ApprovalRequestState.answered(.deny), true),
        (.canceled, .withdrawn, false),
        (.expired, .timedOut, false)
    ])
    func alreadyTerminal_mapsState(
        terminal: BrokerTerminal,
        expected: ApprovalRequestState,
        isAnsweredElsewhere: Bool
    ) async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(terminal)
        }

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == expected)
        // Only an answer beat the decision; a timeout or a withdrawal is told
        // as what it is.
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == isAnsweredElsewhere)
        #expect(store.lastFailureID == nil)
    }

    @Test func alreadyTerminal_byADelegation_isHandedToTheTerminal() async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.delegate))
        }

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be with the TUI")
            return
        }
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == false)
    }

    @Test func aLateResult_doesNotUndoWhatTheBrokerSaid() async {
        let gate = Gate<Void>()
        let (store, request) = Self.store { _, _ in await gate.wait() }

        store.resolve(request, .allowOnce)
        // While the send is in flight, the broker reports the request
        // withdrawn. Settled on the ledger directly, so the send stays in
        // flight; `waitUntilResolved` then waits for its late success to
        // land.
        store.ledger.settle(id: request.id, by: .canceled, now: SuspendingClock.now)
        gate.open()
        await store.waitUntilResolved(request)

        // The send finished, so its late success had its chance to land.
        #expect(!store.resolvingIDs.contains(request.id))
        #expect(store.ledger.entry(for: request)?.state == .withdrawn)
    }

    @Test func aRequestTheBrokerLost_hasAnUnknownResult() async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.recordMissing
        }

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .unknownResult)
        #expect(store.lastFailureID == nil)
    }

    @Test func aSettledRequest_takesNoSecondDecision() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in await sent.next() }
        store.ledger.settle(id: request.id, by: .expired, now: SuspendingClock.now)

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(await sent.count == 0)
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
    }

    // MARK: - Handing a held request to the TUI

    /// A store with one held request from the agent in `paneID`'s pane, and
    /// in `otherPaneID`'s when `inTwoPanes` (a tmux session attached twice).
    /// `requestSessionID` nil makes a request that names no session.
    private static func handOffStore(
        requestSessionID: String? = "session",
        inTwoPanes: Bool = false,
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
    ) -> HandOff {
        let store = ApprovalPresentationStore(decisionSender: sender)
        // The second pane is a real one, in a tab of its own, so a run
        // attached to it is placed there.
        let session: WorkspaceSession
        let paneID: UUID
        let otherPaneID: UUID
        if inTwoPanes {
            let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
            (session, paneID, otherPaneID) = (fixture.session, fixture.paneA, fixture.paneB)
        } else {
            let fixture = WorkspaceSessionFixture.withLooseTab()
            (session, paneID, otherPaneID) = (fixture.session, fixture.paneID, UUID())
        }
        let hinted = inTwoPanes ? [paneID, otherPaneID] : [paneID]
        session.applyAcrossTabs { tab in
            let leaves = tab.splitTree.allLeafIDs()
            tab.agentSessions[.claude] = Dictionary(uniqueKeysWithValues: hinted.filter(leaves.contains).map {
                ($0, AgentSessionInfo(sessionId: "session", cwd: nil))
            })
        }
        let request = ApprovalPresentation.test(sessionID: requestSessionID)
        store.receive([request])
        return HandOff(store: store, session: session, request: request, paneID: paneID, otherPaneID: otherPaneID)
    }

    @MainActor
    private struct HandOff {
        let store: ApprovalPresentationStore
        let session: WorkspaceSession
        let request: ApprovalPresentation
        let paneID: UUID
        let otherPaneID: UUID

        func seen(isVoiceOverRunning: Bool = false) -> AttentionVisibility {
            AttentionVisibility(attendedPanes: [paneID], isAppActive: true, isVoiceOverRunning: isVoiceOverRunning)
        }

        func handOff(_ attention: AttentionVisibility) {
            store.handOffSeenRequests(attention: attention, session: session, holdsWhileHidden: true)
        }
    }

    /// A Claude run of `sessionID` in a turn, attached to `inFront` and
    /// `behind` through tmux: its tmux pane is the active one in the first
    /// and behind another tmux pane in the second.
    private static func tmuxRun(
        id: String,
        sessionID: String = "session",
        inFront: Set<UUID> = [],
        behind: Set<UUID> = []
    ) -> AgentRuntimePresentation {
        func location(isActive: Bool) -> TmuxPaneLocation {
            TmuxPaneLocation(
                socketPath: "/tmp/s", serverPID: "42", serverStartedAt: "100", sessionID: "$2",
                windowID: "@3", paneID: "%\(id)", isActive: isActive
            )
        }
        var locations: [UUID: TmuxPaneLocation] = [:]
        for pane in inFront {
            locations[pane] = location(isActive: true)
        }
        for pane in behind {
            locations[pane] = location(isActive: false)
        }
        return AgentRuntimePresentation.test(
            runID: id,
            badge: AgentBadge(state: .needsInput, updatedAt: Date()),
            paneIDs: inFront.union(behind),
            tmuxLocations: locations,
            sessionID: sessionID
        )
    }

    @Test func aHeldRequestWhosePaneIsSeen_goesToTheTerminal() async {
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore { _, resolution in
            #expect(resolution == .delegate)
            await sent.next()
        }

        fixture.handOff(fixture.seen())
        await fixture.store.waitUntilResolved(fixture.request)

        #expect(await sent.count == 1)
        guard case .handedToTerminal? = fixture.store.ledger.entry(for: fixture.request)?.state else {
            Issue.record("expected the request to be with the TUI")
            return
        }
    }

    @Test func aRequestNobodySees_isHeld() async {
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore { _, _ in await sent.next() }
        let cases: [AttentionVisibility] = [
            // Another app in front.
            AttentionVisibility(attendedPanes: [fixture.paneID], isAppActive: false),
            // The pane is not on screen.
            AttentionVisibility(attendedPanes: [], isAppActive: true),
            // VoiceOver does not read the terminal.
            fixture.seen(isVoiceOverRunning: true)
        ]

        for attention in cases {
            fixture.handOff(attention)
        }
        // The pane is attached to the tmux session, but another window of
        // it is in front.
        fixture.store.runtimes = { [Self.tmuxRun(id: "1", behind: [fixture.paneID])] }
        fixture.handOff(fixture.seen())
        #expect(fixture.store.resolvingIDs.isEmpty)

        #expect(await sent.count == 0)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .held)
    }

    @Test func withoutHolding_everyRequestGoesToTheTerminal() async {
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore { _, _ in await sent.next() }

        fixture.store.handOffSeenRequests(attention: AttentionVisibility(), session: fixture.session, holdsWhileHidden: false)
        await fixture.store.waitUntilResolved(fixture.request)

        #expect(await sent.count == 1)
    }

    @Test func aRequestTheBrokerIsAnswering_isNotHandedOver() async {
        let gate = Gate<Void>()
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore { _, _ in
            await sent.next()
            await gate.wait()
        }
        fixture.store.resolve(fixture.request, .allowOnce)

        fixture.handOff(fixture.seen())
        gate.open()
        await fixture.store.waitUntilResolved(fixture.request)

        // Only the person's answer went out.
        #expect(await sent.count == 1)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .answered(.allowOnce))
    }

    @Test func aRequestWhosePaneIsUnknown_isHeld() async {
        let sent = DecisionRecorder()
        let unnamed = Self.handOffStore(requestSessionID: nil) { _, _ in await sent.next() }
        let elsewhere = Self.handOffStore(requestSessionID: "another session") { _, _ in await sent.next() }

        unnamed.handOff(unnamed.seen())
        elsewhere.handOff(elsewhere.seen())
        #expect(unnamed.store.resolvingIDs.isEmpty)
        #expect(elsewhere.store.resolvingIDs.isEmpty)

        #expect(await sent.count == 0)
        #expect(unnamed.store.ledger.entry(for: unnamed.request)?.state == .held)
        #expect(elsewhere.store.ledger.entry(for: elsewhere.request)?.state == .held)
    }

    @Test func aSessionInTwoPanes_goesOverOnlyFromThePaneShowingTheAgent() async {
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore(inTwoPanes: true) { _, _ in await sent.next() }
        fixture.store.runtimes = { [Self.tmuxRun(id: "1", inFront: [fixture.otherPaneID], behind: [fixture.paneID])] }

        // The seen pane is attached to the session, but shows another window.
        fixture.handOff(fixture.seen())
        #expect(fixture.store.resolvingIDs.isEmpty)
        #expect(await sent.count == 0)

        fixture.handOff(AttentionVisibility(attendedPanes: [fixture.otherPaneID], isAppActive: true))
        await fixture.store.waitUntilResolved(fixture.request)
        #expect(await sent.count == 1)
    }

    @Test func aPaneOnlyTheHintNames_isHeldWhileARunIsBehindAnotherTmuxPaneThere() async {
        // No run reports the request's session, so its pane comes from the
        // hint alone, and which run asked cannot be told there.
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore { _, _ in await sent.next() }
        fixture.store.runtimes = { [Self.tmuxRun(id: "1", sessionID: "elsewhere", behind: [fixture.paneID])] }
        fixture.handOff(fixture.seen())
        #expect(fixture.store.resolvingIDs.isEmpty)
        #expect(await sent.count == 0)

        fixture.store.runtimes = { [Self.tmuxRun(id: "1", sessionID: "elsewhere", inFront: [fixture.paneID])] }
        fixture.handOff(fixture.seen())
        await fixture.store.waitUntilResolved(fixture.request)
        #expect(await sent.count == 1)
    }

    @Test func twoRunsInOnePane_holdTheRequestOfTheRunBehind() async {
        func runs(in pane: UUID) -> [AgentRuntimePresentation] {
            [
                Self.tmuxRun(id: "1", sessionID: "front", inFront: [pane]),
                Self.tmuxRun(id: "2", sessionID: "session", behind: [pane])
            ]
        }
        // One tmux session runs two agents, and the seen pane shows the
        // front one's tmux pane. The request of the one behind it stays held;
        // the front one's goes to its TUI.
        let sent = DecisionRecorder()
        let behind = Self.handOffStore { _, _ in await sent.next() }
        behind.store.runtimes = { runs(in: behind.paneID) }
        behind.handOff(behind.seen())
        #expect(behind.store.resolvingIDs.isEmpty)
        #expect(await sent.count == 0)
        #expect(behind.store.ledger.entry(for: behind.request)?.state == .held)

        let front = Self.handOffStore(requestSessionID: "front") { _, _ in await sent.next() }
        front.store.runtimes = { runs(in: front.paneID) }
        front.handOff(front.seen())
        await front.store.waitUntilResolved(front.request)
        #expect(await sent.count == 1)
    }

    @Test func aFailedHandOff_staysForThePersonAndIsNotResent() async {
        let sent = DecisionRecorder()
        let fixture = Self.handOffStore { _, _ in
            await sent.next()
            throw Offline()
        }

        fixture.handOff(fixture.seen())
        await fixture.store.waitUntilResolved(fixture.request)
        fixture.handOff(fixture.seen())
        #expect(fixture.store.resolvingIDs.isEmpty)

        #expect(await sent.count == 1)
        guard case .sendFailed(.delegate, _)? = fixture.store.ledger.entry(for: fixture.request)?.state else {
            Issue.record("expected the failed hand-off to stay open")
            return
        }
        // Nobody pressed anything, so the card shows no failure line.
        #expect(fixture.store.lastFailureID == nil)
    }

    @Test func aHandOffAnAnswerBeat_isAnsweredButNotByAnotherPerson() async {
        let fixture = Self.handOffStore { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.allowOnce))
        }

        fixture.handOff(fixture.seen())
        await fixture.store.waitUntilResolved(fixture.request)

        let entry = fixture.store.ledger.entry(for: fixture.request)
        #expect(entry?.state == .answered(.allowOnce))
        #expect(entry?.isAnsweredElsewhere == false)
    }
}
