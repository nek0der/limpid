// ApprovalEpisodeEndTests+RunBinding.swift
// Weir — which run a request belongs to when one conversation runs in two.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension ApprovalEpisodeEndTests {
    /// A Claude run of the fixture's conversation in `state`, having taken
    /// its last prompt at `runStartedAt` (`nil` once a turn has ended), shown
    /// in `pane`.
    private static func run(
        _ id: String,
        _ state: AgentState = .running,
        prompt runStartedAt: Date?,
        sessionStartedAt: Date? = nil,
        in pane: UUID
    ) -> AgentRuntimePresentation {
        var badge = AgentBadge(state: state, runStartedAt: runStartedAt, updatedAt: Date())
        badge.sessionStartedAt = sessionStartedAt
        return AgentRuntimePresentation.test(runID: id, badge: badge, paneIDs: [pane], sessionID: "session")
    }

    @Test func aRequestNamingItsRun_isBoundToThatRun_andAResumedRunsPromptLeavesIt() {
        // The conversation is resumed in a second run while the first still
        // has the request with its TUI. The second run is the likelier one by
        // every guess (in a turn, started last), but the request names the
        // first.
        let asking = UUID()
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate), agentRunID: asking)
        let pane = fixture.paneID
        let first = Self.run(asking.uuidString, prompt: Self.ownPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        let resumed = Self.run("resumed", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        fixture.store.runtimes = { [first, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [first.id])
        #expect(fixture.store.run(for: fixture.request, in: fixture.session)?.id == first.id)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        let resumedDone = Self.run("resumed", .finished, prompt: nil, sessionStartedAt: Self.laterPrompt, in: pane)
        fixture.store.runtimes = { [first, resumedDone] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) != nil)

        let firstAgain = Self.run(asking.uuidString, prompt: Self.laterPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [firstAgain, resumedDone] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aStuckRun_doesNotHoldTheRequestsOfAnotherRunOfItsConversation() async {
        // "No" in the first run's dialog left it running with no hook. The
        // conversation goes on in a second run, whose request goes to its
        // TUI while its pane is seen, and leaves with its turn.
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let resumedID = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: resumedID)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let stuck = Self.run("stuck", prompt: Self.ownPrompt.addingTimeInterval(-60), in: pane)
        store.runtimes = { [stuck, Self.run(resumedID.uuidString, .needsInput, prompt: Self.ownPrompt, in: pane)] }

        store.handOffSeenRequests(
            attention: AttentionVisibility(attendedPanes: [pane], isAppActive: true),
            session: session,
            holdsWhileHidden: true
        )
        await store.waitUntilResolved(request)
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.delegate)]),
            epoch: request.epoch,
            now: Self.now
        )
        guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be with its run's TUI")
            return
        }
        // A pass sees its turn under way before it ends.
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) != nil)

        store.runtimes = { [stuck, Self.run(resumedID.uuidString, .finished, prompt: nil, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aRequestAnsweredOnTheCard_endsWithItsTurn_thoughNoPassSawTheTurnRun() async {
        // The run wrote `running` before it asked; the next record it writes
        // is its Stop, so the first pass after the request already reads the
        // turn's end. The request's arrival is when its turn was seen.
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        let pane = UUID()
        store.runtimes = { [Self.run(asking.uuidString, prompt: Self.ownPrompt, in: pane)] }
        store.handOffSeenRequests(attention: AttentionVisibility(), session: session, holdsWhileHidden: true)

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.allowOnce)]),
            epoch: request.epoch,
            now: Self.now
        )
        store.runtimes = { [Self.run(asking.uuidString, .finished, prompt: nil, in: pane)] }
        store.releaseStaleApprovals(in: session)

        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aRequestsNamedRunGoingAway_endsItOnceHandedOver_andKeepsItWhileHeld() async {
        let asking = UUID()
        let handedOver = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate), agentRunID: asking)
        handedOver.store.runtimes = { [Self.run(asking.uuidString, prompt: Self.ownPrompt, in: handedOver.paneID)] }
        handedOver.store.releaseStaleApprovals(in: handedOver.session)
        #expect(handedOver.store.ledger.entry(for: handedOver.request) != nil)
        handedOver.store.runtimes = { [] }
        handedOver.store.releaseStaleApprovals(in: handedOver.session)
        #expect(handedOver.store.ledger.entry(for: handedOver.request) == nil)

        // A held request waits for the broker: its helper went with the run.
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let held = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        held.runtimes = { [Self.run(asking.uuidString, .needsInput, prompt: Self.ownPrompt, in: UUID())] }
        held.releaseStaleApprovals(in: session)
        held.runtimes = { [] }
        held.releaseStaleApprovals(in: session)
        await held.waitUntilResolved(request)
        #expect(held.ledger.entry(for: request)?.state == .held)
    }

    @Test func aRequestWhoseNamedRunIsNotListedYet_isKeptAndHeldWhilePending() {
        // The request reached us before the projection listed its run; the
        // other run of the conversation does not stand in for it.
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        store.runtimes = { [Self.run("other", prompt: Self.laterPrompt, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == nil)
        #expect(store.turnStanding(for: request, in: session) == .awaitingRun)

        store.handOffSeenRequests(
            attention: AttentionVisibility(attendedPanes: [pane], isAppActive: true),
            session: session,
            holdsWhileHidden: true
        )
        #expect(store.ledger.entry(for: request)?.state == .held)
    }

    @Test func aRequestWhoseNamedRunIsNeverListed_endsOnceTheBrokerIsDoneWithIt() {
        // The agent died while Weir was not running, and its record went
        // with it: the request's run is never listed. Once the broker has
        // timed the request out, nothing will place it.
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: UUID())
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.state == .held)

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .expired]),
            epoch: request.epoch,
            now: Self.now
        )
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aNamedRunListedLater_isBoundThen_andEndsTheRequestWithItsTurn() {
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        let pane = UUID()
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == nil)

        let run = Self.run(asking.uuidString, .needsInput, prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [run] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [run.id])

        // Answered in its TUI: the broker hands it over, and its turn ends.
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.delegate)]),
            epoch: request.epoch,
            now: Self.now
        )
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) != nil)
        store.runtimes = { [Self.run(asking.uuidString, .finished, prompt: nil, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aDetachedTmuxRunsRequest_isHeldWhileAPaneItsConversationHintsIsSeen() {
        // The run is bound, but detached: it shows nowhere. The hint names a
        // pane of another run of the conversation, or an older one.
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let (session, _, hinted) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [hinted: AgentSessionInfo(sessionId: "session", cwd: nil)]
        }
        store.runtimes = { [AgentRuntimePresentation.test(
            runID: asking.uuidString,
            badge: AgentBadge(state: .needsInput, runStartedAt: Self.ownPrompt, updatedAt: Date()),
            sessionID: "session"
        )] }

        store.handOffSeenRequests(
            attention: AttentionVisibility(attendedPanes: [hinted], isAppActive: true),
            session: session,
            holdsWhileHidden: true
        )

        #expect(store.panes(for: request, in: session).isEmpty)
        #expect(store.ledger.entry(for: request)?.state == .held)
    }

    // MARK: - Requests that name no run

    @Test func aHandedOverRequest_endsWithItsOwnRunsNextPrompt_notWithAResumedRuns() {
        // A request that names no run is bound to the run in a turn when it
        // was seen; a run that started later is not a candidate.
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let pane = fixture.paneID
        let first = Self.run("first", prompt: Self.ownPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [first] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [first.id])

        let resumed = Self.run("resumed", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        fixture.store.runtimes = { [first, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))
        #expect(fixture.store.run(for: fixture.request, in: fixture.session)?.id == first.id)

        let firstAgain = Self.run("first", prompt: Self.laterPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [firstAgain, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aHeldRequest_isNotReleasedByAResumedRunsPrompt() async {
        let request = ApprovalPresentation.test(sessionID: "session")
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        let pane = UUID()
        let first = Self.run("first", .needsInput, prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [first] }
        store.releaseStaleApprovals(in: session)

        let resumed = Self.run("resumed", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        store.runtimes = { [first, resumed] }
        store.releaseStaleApprovals(in: session)
        await store.waitUntilResolved(request)
        #expect(store.ledger.entry(for: request)?.state == .held)

        // Its own run's next prompt releases it, and the release ends it.
        store.runtimes = { [Self.run("first", prompt: Self.laterPrompt, in: pane), resumed] }
        store.releaseStaleApprovals(in: session)
        await store.waitUntilResolved(request)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aRequestSeenBeforeAnyRunIsInATurn_isBoundToTheRunThatThenIs() {
        // The projection can reach us after the request: the run's badge
        // still shows its last turn. A run started after the request is not
        // the one that asked.
        let request = ApprovalPresentation.test(sessionID: "session")
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        let pane = UUID()
        store.runtimes = { [Self.run("asking", .finished, prompt: nil, sessionStartedAt: Self.ownPrompt, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == nil)

        let asking = Self.run("asking", .needsInput, prompt: Self.ownPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        let later = Self.run("later", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        store.runtimes = { [asking, later] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [asking.id])
    }

    @Test func aRequestEitherOfTwoRunsCouldHaveAsked_endsOnceBothTurnsHaveEnded() {
        // Both runs of the conversation were in a turn when the request was
        // seen: which one asked cannot be told. One run's prompt or turn end
        // alone does not end it; both turns ending, in either order, does.
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let pane = fixture.paneID
        let one = Self.run("one", prompt: Self.ownPrompt, in: pane)
        let other = Self.run("other", prompt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [one, other] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [one.id, other.id])

        fixture.store.runtimes = { [one, Self.run("other", prompt: Self.laterPrompt, in: pane)] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) != nil)

        // The later turn ends, and its prompt time goes with it.
        let otherDone = Self.run("other", .finished, prompt: nil, in: pane)
        fixture.store.runtimes = { [one, otherDone] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) != nil)

        fixture.store.runtimes = { [Self.run("one", .finished, prompt: nil, in: pane), otherDone] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aRequestEitherOfTwoRunsCouldHaveAsked_followsTheOtherOnceOneHasGone() {
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let pane = fixture.paneID
        let one = Self.run("one", prompt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [one, Self.run("other", prompt: Self.ownPrompt, in: pane)] }
        fixture.store.releaseStaleApprovals(in: fixture.session)

        fixture.store.runtimes = { [one] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.turnStanding(for: fixture.request, in: fixture.session) == .known(one.badge))
        #expect(fixture.store.ledger.entry(for: fixture.request) != nil)

        fixture.store.runtimes = { [Self.run("one", .finished, prompt: nil, in: pane)] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aRequestNamingNoRun_beforeAnyRunReportsItsSession_isBoundToTheOneRunInItsHintedPane() {
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let unnamed = AgentRuntimePresentation.test(
            runID: "unnamed",
            badge: AgentBadge(state: .running, runStartedAt: Self.ownPrompt, updatedAt: Date()),
            paneIDs: [fixture.paneID]
        )
        fixture.store.runtimes = { [unnamed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [unnamed.id])
    }

    @Test func aScopedQuestionEitherOfTwoRunsCouldHaveAsked_endsOnceNeitherIsInATurn() {
        // A background agent's question ends with a turn that ran after it
        // left the list. Which run asked cannot be told, so it ends only once
        // neither run is in a turn.
        let fixture = Self.storeWithEndedRequest(
            state: .running, terminal: .resolved(.delegate),
            operationID: AgentQuestionTurnCompletion.operationIDPrefix + "turn"
        )
        let pane = fixture.paneID
        let one = Self.run("one", prompt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [one, Self.run("other", prompt: Self.ownPrompt, in: pane)] }
        fixture.store.releaseStaleApprovals(in: fixture.session)

        fixture.store.runtimes = { [one, Self.run("other", .finished, prompt: nil, in: pane)] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) != nil)

        fixture.store.runtimes = {
            [Self.run("one", .finished, prompt: nil, in: pane), Self.run("other", .finished, prompt: nil, in: pane)]
        }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aRequestEitherOfTwoRunsCouldHaveAsked_isHeldWhileItsPaneIsSeen() {
        let request = ApprovalPresentation.test(sessionID: "session")
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let runs = [Self.run("one", prompt: Self.ownPrompt, in: pane), Self.run("other", prompt: Self.ownPrompt, in: pane)]
        store.runtimes = { runs }

        store.handOffSeenRequests(
            attention: AttentionVisibility(attendedPanes: [pane], isAppActive: true),
            session: session,
            holdsWhileHidden: true
        )

        #expect(store.ledger.entry(for: request)?.state == .held)
    }
}
