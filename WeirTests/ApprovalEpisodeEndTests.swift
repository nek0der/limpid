// ApprovalEpisodeEndTests.swift
// Weir — when a request's episode ends: the release Weir sends once its
// turn is over without an answer, and the ledger letting go of a request that
// left the pending list.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ApprovalEpisodeEndTests {
    static let now = SuspendingClock.now
    /// When the fixture's request is first seen pending, on the wall clock.
    static let seenAt = Date(timeIntervalSince1970: 1000)
    /// The prompt that started the request's own turn: before it was seen.
    static let ownPrompt = seenAt.addingTimeInterval(-5)
    /// A prompt the run took after the request was seen.
    static let laterPrompt = seenAt.addingTimeInterval(1)

    private static let question = ApprovalQuestion(
        header: "Color",
        prompt: "Which color?",
        options: [.init(label: "Red", description: nil)],
        isMultiSelect: false
    )

    /// A loose tab whose one pane runs a Claude agent in `state`, having
    /// taken its last prompt at `runStartedAt`, in the conversation `session`.
    static func claudePane(
        _ state: AgentState,
        runStartedAt: Date? = nil,
        session sessionID: String = "session"
    ) -> (session: WorkspaceSession, paneID: UUID) {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: sessionID, cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: state, runStartedAt: runStartedAt, updatedAt: Date())]
        }
        return (session, paneID)
    }

    /// The agent in `paneID` moves to `state`, its last prompt taken at
    /// `runStartedAt`.
    static func move(_ session: WorkspaceSession, _ paneID: UUID, to state: AgentState, runStartedAt: Date? = nil) {
        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: state, runStartedAt: runStartedAt, updatedAt: Date())]
        }
    }

    /// A store holding `request` pending, first seen at `seenAt`.
    static func pendingStore(_ request: ApprovalPresentation, seenAt: Date) -> ApprovalPresentationStore {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        store.receive([request], seenAt: seenAt)
        return store
    }

    /// A store with one request from a pane whose agent is in `state`,
    /// having taken its last prompt at `runStartedAt`, and the request
    /// already gone from the pending list as `terminal` says; `nil` for a
    /// request whose record the broker lost.
    static func storeWithEndedRequest(
        state: AgentState,
        runStartedAt: Date? = nil,
        terminal: BrokerTerminal?,
        operationID: String? = nil,
        agentRunID: UUID? = nil
    ) -> EndedRequest {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, paneID) = claudePane(state, runStartedAt: runStartedAt)
        let request = ApprovalPresentation.test(sessionID: "session", operationID: operationID, agentRunID: agentRunID)
        store.apply(.test(pending: [request]), epoch: request.epoch, now: now, seenAt: seenAt)
        // Settled at `now`, which the hand-off state carries.
        let ended = terminal.map { ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: $0]) }
            ?? .test(pending: [], missing: [request.id])
        store.apply(ended, epoch: request.epoch, now: now, seenAt: seenAt.addingTimeInterval(1))
        return EndedRequest(store: store, session: session, request: request, paneID: paneID)
    }

    struct EndedRequest {
        let store: ApprovalPresentationStore
        let session: WorkspaceSession
        let request: ApprovalPresentation
        let paneID: UUID

        /// The pane's agent moves to `state`, its last prompt taken at
        /// `runStartedAt`.
        @MainActor
        func agent(_ state: AgentState, runStartedAt: Date?) {
            ApprovalEpisodeEndTests.move(session, paneID, to: state, runStartedAt: runStartedAt)
        }

        /// Whether the ledger still holds the request after a pass.
        @MainActor
        func isKeptAfterAPass() -> Bool {
            store.releaseStaleApprovals(in: session)
            return store.ledger.entry(for: request) != nil
        }
    }

    // MARK: - A request that left the pending list

    @Test func aRequestWhosePaneIsGone_leavesTheLedgerAtRelease() {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test(sessionID: "nowhere")
        store.receive([request])
        store.receive([], epoch: request.epoch, terminals: [request.id: .resolved(.delegate)])
        #expect(store.ledger.entry(for: request) != nil)

        store.releaseStaleApprovals(in: WorkspaceSession())

        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aHandedOverRequest_staysWhileItsTurnRuns_andLeavesWhenItIsOver() {
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))

        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        fixture.agent(.finished, runStartedAt: nil)
        #expect(!fixture.isKeptAfterAPass())
    }

    /// The agent quit at its dialog (`SessionEnd`) ends the request it
    /// left to the terminal: a run hosted in tmux keeps its record, so
    /// nothing else would. Only after its turn was seen under way, since an
    /// unknown state is also a run not yet heard from.
    @Test func aHandedOverRequest_leavesWhenItsSessionEnds() {
        let fixture = Self.storeWithEndedRequest(state: .unknown, terminal: .resolved(.delegate))
        #expect(fixture.isKeptAfterAPass())

        fixture.agent(.needsInput, runStartedAt: nil)
        #expect(fixture.isKeptAfterAPass())
        fixture.agent(.unknown, runStartedAt: nil)
        #expect(!fixture.isKeptAfterAPass())
    }

    @Test func aHandedOverRequest_isNotEndedByTheTurnBeforeItsOwn() {
        // The request reached the TUI before the projection read its turn:
        // the badge still shows the turn before, which says nothing about
        // this one. Its own turn, once seen, ends it.
        let fixture = Self.storeWithEndedRequest(state: .finished, terminal: .resolved(.delegate))
        #expect(fixture.isKeptAfterAPass())

        fixture.agent(.running, runStartedAt: Self.ownPrompt)
        fixture.store.releaseStaleApprovals(in: fixture.session)
        fixture.agent(.finished, runStartedAt: nil)
        #expect(!fixture.isKeptAfterAPass())
    }

    @Test func aHandedOverRequest_staysWhileItsOwnTurnRuns() {
        let fixture = Self.storeWithEndedRequest(state: .running, runStartedAt: Self.ownPrompt, terminal: .resolved(.delegate))
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        // The TUI asks, and another tool moves the run on: still its turn.
        fixture.agent(.needsInput, runStartedAt: Self.ownPrompt)
        fixture.store.releaseStaleApprovals(in: fixture.session)
        fixture.agent(.running, runStartedAt: Self.ownPrompt)
        #expect(fixture.isKeptAfterAPass())

        // A prompt stamped in the very second the request was seen may be
        // its own, cut to the second: it does not overtake it.
        fixture.agent(.running, runStartedAt: Self.seenAt)
        #expect(fixture.isKeptAfterAPass())
    }

    @Test func aHandedOverRequest_leavesWhenALaterPromptStartsAnotherTurn() {
        // "No" in Claude's dialog sends no hook: the run stays running, and
        // the next prompt is the first sign the request's turn is over.
        let fixture = Self.storeWithEndedRequest(state: .running, runStartedAt: Self.ownPrompt, terminal: .resolved(.delegate))
        #expect(fixture.isKeptAfterAPass())

        fixture.agent(.running, runStartedAt: Self.laterPrompt)

        #expect(!fixture.isKeptAfterAPass())
    }

    /// A request our clock or the broker timed out (`.expired`), and one
    /// whose record the broker lost (`nil`).
    @Test(arguments: [BrokerTerminal.expired, nil])
    func aTimedOutOrLostRequest_staysThroughItsTurn_andLeavesWhenALaterPromptStartsAnotherTurn(
        terminal: BrokerTerminal?
    ) {
        let fixture = Self.storeWithEndedRequest(state: .running, runStartedAt: Self.ownPrompt, terminal: terminal)
        let expected: ApprovalRequestState = terminal == nil ? .unknownResult : .timedOut
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == expected)

        fixture.agent(.running, runStartedAt: Self.laterPrompt)

        #expect(!fixture.isKeptAfterAPass())
    }

    @Test func aHandedOverRequest_readsItsRunsPrompt_notThePanesBadge() {
        // The pane's badge shows a later prompt, but the run the request
        // came from is still in the request's own turn.
        let fixture = Self.storeWithEndedRequest(state: .running, runStartedAt: Self.laterPrompt, terminal: .resolved(.delegate))
        let own = AgentRuntimePresentation.test(
            badge: AgentBadge(state: .running, runStartedAt: Self.ownPrompt, updatedAt: Date()),
            paneIDs: [fixture.paneID],
            sessionID: "session"
        )
        fixture.store.runtimes = { [own] }

        fixture.store.releaseStaleApprovals(in: fixture.session)

        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))
    }

    // MARK: - A scoped question

    /// A background agent's question outlives the root prompt. The pane's
    /// turn ending before it left the list may be another prompt's, and the
    /// run's next prompt does not end it either; the turn that ran after it
    /// left the list does, whether the TUI took it or the broker timed it out.
    @Test(arguments: [BrokerTerminal.resolved(.delegate), .expired])
    func aScopedQuestion_endsOnlyWithATurnThatRanAfterIt(terminal: BrokerTerminal) {
        let operation = AgentQuestionTurnCompletion.operationIDPrefix + "turn"
        let fixture = Self.storeWithEndedRequest(state: .finished, terminal: terminal, operationID: operation)
        #expect(fixture.isKeptAfterAPass())

        fixture.agent(.running, runStartedAt: Self.ownPrompt)
        #expect(fixture.isKeptAfterAPass())
        fixture.agent(.running, runStartedAt: Self.laterPrompt)
        #expect(fixture.isKeptAfterAPass())

        fixture.agent(.finished, runStartedAt: nil)
        #expect(!fixture.isKeptAfterAPass())
    }

    @Test func aScopedQuestion_endsWhenSettledOrWhenItsPaneIsGone() {
        let operation = AgentQuestionTurnCompletion.operationIDPrefix + "turn"
        let settled = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.allowOnce), operationID: operation)
        #expect(!settled.isKeptAfterAPass())

        let handed = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate), operationID: operation)
        handed.store.releaseStaleApprovals(in: WorkspaceSession())
        #expect(handed.store.ledger.entry(for: handed.request) == nil)
    }

    // MARK: - The release

    /// A store whose one request belongs to a pane whose turn has just ended,
    /// so `releaseStaleApprovals` sends a delegate for it.
    private static func releasingStore(
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
    ) -> Releasing {
        let store = ApprovalPresentationStore(decisionSender: sender)
        let (session, paneID) = claudePane(.running)
        let request = ApprovalPresentation.test(sessionID: "session")
        store.receive([request])
        store.releaseStaleApprovals(in: session)
        move(session, paneID, to: .finished)
        return Releasing(store: store, session: session, request: request)
    }

    private struct Releasing {
        let store: ApprovalPresentationStore
        let session: WorkspaceSession
        let request: ApprovalPresentation
    }

    /// A store whose decisions `recorded` keeps.
    private static func recordingStore(_ recorded: DecisionRecorder) -> ApprovalPresentationStore {
        ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append(approval.id, resolution)
        })
    }

    @Test func releaseStaleApprovals_delegatesOnceTheTurnIsOver() async {
        let recorded = DecisionRecorder()
        let store = Self.recordingStore(recorded)
        let (session, paneID) = Self.claudePane(.running)
        let request = ApprovalPresentation.test(sessionID: "session", deadlineMilliseconds: 0)
        store.receive([request])

        // An active turn alone proves no answer. We keep the request until
        // the turn ends, even if the needs-input projection is missed. A
        // release would be in flight as soon as the pass returns.
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)

        Self.move(session, paneID, to: .needsInput)
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)

        // A background subagent or another tool puts the session back into
        // `running` while the dialog is still open; that is no answer.
        Self.move(session, paneID, to: .running)
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)

        Self.move(session, paneID, to: .finished)
        store.releaseStaleApprovals(in: session)
        // A second projection that lands before the decision settles must
        // not send it again. Calling without a suspension point in between
        // keeps the first decision in flight regardless of scheduling.
        store.releaseStaleApprovals(in: session)
        await recorded.waitForCount(1)
        await store.waitUntilResolved(request)
        #expect(await recorded.entries.map(\.resolution) == [.delegate])
    }

    @Test func aReleaseThatSucceeds_endsTheEpisode() async {
        let releasing = Self.releasingStore { _, _ in }
        let (store, request) = (releasing.store, releasing.request)

        store.releaseStaleApprovals(in: releasing.session)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request) == nil)
    }

    /// Where the release reads the request's turn: the run whose hooks
    /// reported its session, or, before a run is known, the badge of the
    /// pane the session hint names.
    enum TurnSource: CaseIterable, Sendable {
        case run
        case hintedPane
    }

    @Test(arguments: TurnSource.allCases)
    func releaseStaleApprovals_releasesAPendingRequestOvertakenByANewPrompt(source: TurnSource) async {
        let recorded = DecisionRecorder()
        let store = Self.recordingStore(recorded)
        let (session, paneID) = Self.claudePane(.running, runStartedAt: Self.ownPrompt)
        func agent(runStartedAt: Date) {
            let badge = AgentBadge(state: .running, runStartedAt: runStartedAt, updatedAt: Date())
            switch source {
            case .run:
                // The pane's own badge keeps the request's turn, so only
                // the run can tell of the later prompt.
                store.runtimes = { [AgentRuntimePresentation.test(badge: badge, paneIDs: [paneID], sessionID: "session")] }
            case .hintedPane:
                session.applyAcrossTabs { tab in
                    tab.agentBadges[.claude] = [paneID: badge]
                }
            }
        }
        agent(runStartedAt: Self.ownPrompt)
        let request = ApprovalPresentation.test(sessionID: "session", deadlineMilliseconds: 0)
        store.receive([request], seenAt: Self.seenAt)

        // Its own turn runs: held for the person.
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)

        // A prompt stamped in the second the request was first seen may be
        // its own, cut to the second: it does not overtake it.
        agent(runStartedAt: Self.seenAt)
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)

        // The person answered in the TUI, and the run took another prompt
        // without ever reporting the first turn's end.
        agent(runStartedAt: Self.laterPrompt)
        store.releaseStaleApprovals(in: session)
        await recorded.waitForCount(1)
        await store.waitUntilResolved(request)

        #expect(await recorded.entries.map(\.resolution) == [.delegate])
        #expect(store.ledger.entry(for: request) == nil, "a release ends the episode")
        #expect(store.lastFailureID == nil)
    }

    @Test func releaseStaleApprovals_skipsRequestSettledBeforeProjectionDropsIt() async {
        let recorded = DecisionRecorder()
        let store = Self.recordingStore(recorded)
        let (session, paneID) = Self.claudePane(.needsInput)
        let request = ApprovalPresentation.test(sessionID: "session", deadlineMilliseconds: 0, questions: [Self.question])
        store.receive([request])
        store.releaseStaleApprovals(in: session)

        store.resolve(request, .answer(["Which color?": "Red"]))
        await recorded.waitForCount(1)
        await store.waitUntilResolved(request)

        // The turn ends before the broker projection drops the answered
        // request; a late `delegate` would be rejected as already terminal.
        Self.move(session, paneID, to: .finished)
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)
        #expect(await recorded.count == 1)
        #expect(store.lastFailureID == nil)
    }

    @Test func releaseStaleApprovals_releasesAfterRunningWithoutNeedsInput() async {
        let recorded = DecisionRecorder()
        let store = Self.recordingStore(recorded)
        let (session, paneID) = Self.claudePane(.running)
        let request = ApprovalPresentation.test(sessionID: "session", deadlineMilliseconds: 0, questions: [Self.question])
        store.receive([request])
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)

        Self.move(session, paneID, to: .finished)
        store.releaseStaleApprovals(in: session)
        await recorded.waitForCount(1)
        #expect(await recorded.entries.map(\.resolution) == [.delegate])
    }

    /// A scoped question waits for its own turn's completion receipt rather
    /// than the pane's turn end, which may be another prompt's or a
    /// background agent's: the turn running and ending releases nothing.
    @Test func releaseStaleApprovals_leavesScopedQuestionsToTheirOwnTurnCompletion() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, paneID) = Self.claudePane(.running)
        let request = ApprovalPresentation.test(
            sessionID: "session",
            operationID: AgentQuestionTurnCompletion.operationIDPrefix + "question",
            deadlineMilliseconds: 0,
            questions: [Self.question]
        )
        store.receive([request])
        store.releaseStaleApprovals(in: session)

        Self.move(session, paneID, to: .finished)
        store.releaseStaleApprovals(in: session)

        #expect(store.resolvingIDs.isEmpty)
        #expect(store.ledger.entry(for: request)?.state == .held)
    }

    /// A pane whose turn had ended before the request arrived says nothing
    /// about the request's own turn, which no pass has seen run yet.
    @Test func aTurnEndSeenBeforeItsTurnRan_releasesNothing() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, _) = Self.claudePane(.finished)
        let request = ApprovalPresentation.test(sessionID: "session", deadlineMilliseconds: 0, questions: [Self.question])
        store.receive([request])

        store.releaseStaleApprovals(in: session)

        #expect(store.resolvingIDs.isEmpty)
        #expect(store.ledger.entry(for: request)?.state == .held)
    }

    /// How a release can fail to go through.
    enum ReleaseSetback: CaseIterable, Sendable {
        /// The broker had already settled the request.
        case alreadySettled
        /// The broker no longer has the request.
        case recordMissing
        /// The send itself failed.
        case failed

        var error: any Error {
            switch self {
            case .alreadySettled: ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.allowOnce))
            case .recordMissing: ApprovalControllerConnection.DecisionRefusal.recordMissing
            case .failed: OfflineSender()
            }
        }
    }

    /// Nobody pressed anything, so the card does not ask to try again, and
    /// the next pass does not resend it. A refusal says the request was
    /// settled elsewhere, so its episode ends; a failed send leaves it.
    @Test(arguments: ReleaseSetback.allCases)
    func aReleaseThatDoesNotGoThrough_isNeitherReportedNorRetried(setback: ReleaseSetback) async {
        let sent = DecisionRecorder()
        let releasing = Self.releasingStore { _, _ in
            await sent.next()
            throw setback.error
        }
        let (store, request) = (releasing.store, releasing.request)

        store.releaseStaleApprovals(in: releasing.session)
        await sent.waitForCount(1)
        await store.waitUntilResolved(request)
        #expect(store.lastFailureID == nil)

        store.releaseStaleApprovals(in: releasing.session)
        #expect(store.resolvingIDs.isEmpty)
        #expect(await sent.count == 1)
        #expect((store.ledger.entry(for: request) == nil) == (setback != .failed))
    }
}

/// A sender that cannot reach the service.
private struct OfflineSender: Error {}
