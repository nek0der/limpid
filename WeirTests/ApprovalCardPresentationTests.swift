// ApprovalCardPresentationTests.swift
// Weir — a window's approval card: which request it shows, its focus and
// draft, and when it closes.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalCardPresentationTests {
    private nonisolated static let now = SuspendingClock.now

    private static func approval(
        epoch: UUID = UUID(),
        sessionID: String? = nil,
        questions: [ApprovalQuestion] = []
    ) -> ApprovalPresentation {
        ApprovalPresentation.test(epoch: epoch, sessionID: sessionID, summary: "rm -rf build", questions: questions)
    }

    // MARK: - Which request the card shows

    @Test func newRequest_opensNoCardByItself() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let first = Self.approval(epoch: epoch)
        let second = Self.approval(epoch: epoch)

        store.receive([first])
        #expect(card.presentedApproval == nil)
        card.present(first)
        #expect(card.presentedApproval == first)
        store.receive([first, second])
        #expect(card.presentedApproval == first)
        card.dismissCard()
        let third = Self.approval(epoch: epoch)
        store.receive([first, second, third])
        #expect(card.presentedApproval == nil)

        // Nor does one coming back over a reconnect, or a restarted service's.
        store.receive([], epoch: epoch)
        store.receive([first, second, third])
        #expect(card.presentedApproval == nil)
        store.receive([Self.approval(epoch: UUID())])
        #expect(card.presentedApproval == nil)
    }

    @Test func aPresentedRequestLeavingTheList_promotesNoOtherRequest() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let first = Self.approval(epoch: epoch)
        let second = Self.approval(epoch: epoch)
        store.receive([first, second])
        card.present(first)

        // Still held, so its card stays on it rather than moving on.
        store.receive([second])
        #expect(card.presentedApproval == first)

        // Withdrawn: its card closes, and no other request's opens.
        store.receive([second], terminals: [first.id: .canceled])
        #expect(card.presentedApproval == nil)
        #expect(!card.isCardOpen)
    }

    @Test func present_requestsCardFocusOnlyWhenAsked() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval()

        store.receive([request])
        card.present(request, shouldFocusCard: false)
        #expect(card.presentedApproval == request)
        #expect(card.cardFocusRequestID == nil)

        card.present(request)
        #expect(card.cardFocusRequestID == request.id)
    }

    @Test func aCardHoldsTheKeyboardOnlyWhileFocusIsInIt() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval()
        store.receive([request])
        card.present(request)
        #expect(!card.isCardFocused, "focus arrives a turn after the click")

        card.cardFocusChanged(true, for: request)
        #expect(card.isCardFocused)

        // The person went to the terminal: the card stays, keys go there.
        card.cardFocusChanged(false, for: request)
        #expect(!card.isCardFocused)
        #expect(card.isCardOpen)
        #expect(card.presentedApproval == request)

        // Escape or the close button.
        card.dismissCard()
        #expect(card.presentedApproval == nil)
        #expect(!card.isCardOpen)
    }

    @Test func staleFocusLoss_leavesTheReplacementCardAlone() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let first = Self.approval()
        let second = Self.approval(epoch: first.epoch)

        store.receive([first, second])
        card.present(first)
        card.present(second)
        card.cardFocusChanged(true, for: first)
        card.cardFocusChanged(false, for: first)

        #expect(card.presentedApproval == second)
        #expect(!card.isCardFocused)
    }

    @Test func aCardThatGotNoFocus_staysOpen() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval()

        store.receive([request])
        card.present(request)
        card.cardFocusRequestCompleted(for: request)

        #expect(card.presentedApproval == request)
        #expect(card.cardFocusRequestID == nil)
    }

    @Test func questionCard_closesLikeAnyCardAndKeepsItsDraft() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval(questions: [Self.question])
        store.receive([request])
        card.present(request)
        var draft = store.answerDraft(for: request)
        draft.toggle(label: "Red", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: request)

        card.dismissCard()
        #expect(card.presentedApproval == nil)

        card.present(request)
        #expect(store.answerDraft(for: request).answers(for: [Self.question]) == ["Which color?": "Red"])
    }

    @Test func anotherRowsCard_replacesQuestionCardWithoutLosingDraft() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let first = Self.approval(questions: [Self.question])
        let second = Self.approval(epoch: first.epoch)
        store.receive([first, second])
        card.present(first)
        var draft = store.answerDraft(for: first)
        draft.setFreeText("Green", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: first)

        card.present(second)
        #expect(card.presentedApproval == second)
        #expect(store.answerDraft(for: first).freeText[0] == "Green")
    }

    @Test func answerDraft_leavesWithItsRequest() {
        let store = ApprovalPresentationStore()
        let request = Self.approval(questions: [Self.question])
        store.receive([request])
        var draft = store.answerDraft(for: request)
        draft.toggle(label: "Red", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: request)

        // Withdrawn, then the service restarted: a settled request does not
        // outlive its epoch.
        store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])
        store.receive([], epoch: UUID())
        #expect(store.answerDraft(for: request) == ApprovalAnswerDraft())

        // A request the store no longer knows cannot gain a draft either.
        store.updateAnswerDraft(draft, for: request)
        #expect(store.answerDraft(for: request) == ApprovalAnswerDraft())
    }

    private static let question = ApprovalQuestion(
        header: "Color",
        prompt: "Which color?",
        options: [.init(label: "Red", description: nil)],
        isMultiSelect: false
    )

    // MARK: - When the card closes

    private struct Presented {
        let store: ApprovalPresentationStore
        let card: TestApprovalCard
        let request: ApprovalPresentation
        let epoch: UUID
    }

    /// A store with one request presented on its card.
    private static func presentedStore(
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void = { _, _ in }
    ) -> Presented {
        let store = ApprovalPresentationStore(decisionSender: sender)
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let request = approval(epoch: epoch)
        store.apply(.test(pending: [request]), epoch: epoch, now: now)
        card.present(request)
        return Presented(store: store, card: card, request: request, epoch: epoch)
    }

    @Test(arguments: [BrokerTerminal.resolved(.delegate), .expired])
    func aRequestThatLeavesThePendingList_keepsItsCardWhileOpen(_ terminal: BrokerTerminal) {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: terminal]),
            epoch: epoch,
            now: Self.now
        )

        #expect(card.presentedApproval == request)
        #expect(card.isCardOpen)
    }

    @Test(arguments: [BrokerTerminal.resolved(.allowOnce), .canceled])
    func aSettledRequest_closesItsCard(_ terminal: BrokerTerminal) {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: terminal]),
            epoch: epoch,
            now: Self.now
        )

        #expect(card.presentedApproval == nil)
        #expect(card.presentedID == nil)
    }

    @Test func aRequestTheBrokerLost_closesItsCard() {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card

        store.apply(ApprovalControllerConnection.Projection.test(pending: [], missing: [request.id]), epoch: epoch, now: Self.now)

        #expect(!card.isCardOpen)
    }

    @Test func anAnswerThatLost_keepsTheCardToSaySo() async {
        let presented = Self.presentedStore { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.deny))
        }
        let (store, request) = (presented.store, presented.request)
        let card = presented.card

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(card.presentedApproval == request)
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == true)
    }

    @Test func anAcceptedAnswer_closesTheCard() async {
        let presented = Self.presentedStore()
        let (store, request) = (presented.store, presented.request)
        let card = presented.card

        store.resolve(request, .allowOnce)
        #expect(card.isCardOpen, "the card says Sending until the broker accepts")
        await store.waitUntilResolved(request)

        #expect(!card.isCardOpen)
    }

    @Test func aCardHandedToTheTerminal_closesWhenTheTurnEnds() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let card = TestApprovalCard(store)
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .running, updatedAt: Date())]
        }
        let epoch = UUID()
        let request = Self.approval(epoch: epoch, sessionID: "session")
        store.apply(ApprovalControllerConnection.Projection.test(pending: [request]), epoch: epoch, now: Self.now)
        card.present(request)
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.delegate)]),
            epoch: epoch,
            now: Self.now
        )

        store.releaseStaleApprovals(in: session)
        #expect(card.isCardOpen, "the TUI has not answered while the turn runs")

        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        #expect(!card.isCardOpen)
    }

    @Test func aRequestThatLeftThePendingList_hasNoRowToPointAt() {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card
        #expect(store.hasRow(for: request))

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .expired]),
            epoch: epoch,
            now: Self.now
        )

        #expect(card.isCardOpen)
        #expect(!store.hasRow(for: request))
    }

    @Test func anEndedRequestAStaleProjectionStillLists_getsNoCard() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let request = Self.approval(epoch: epoch)
        store.apply(ApprovalControllerConnection.Projection.test(pending: [request]), epoch: epoch, now: Self.now)
        store.ledger.endEpisode(id: request.id)

        store.receive([request], epoch: epoch)
        card.present(request)

        #expect(!card.isCardOpen)
    }

    @Test func theCardModel_readsTheStore() async {
        struct Offline: Error {}
        let presented = Self.presentedStore { _, _ in throw Offline() }
        let (store, request) = (presented.store, presented.request)

        store.resolve(request, .deny)
        await store.waitUntilResolved(request)

        #expect(ApprovalCardModel(approval: request, in: store)?.status == .sendFailed)
    }

    @Test func anAnchorAndDraftOutliveThePendingList() {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.delegate)]),
            epoch: epoch,
            now: Self.now
        )

        let row = CGRect(x: 0, y: 100, width: 280, height: 40)
        card.updateRowAnchor(row, for: request)
        var draft = ApprovalAnswerDraft()
        draft.activeQuestionIndex = 1
        store.updateAnswerDraft(draft, for: request)

        #expect(card.rowAnchor(for: request) == row)
        #expect(store.answerDraft(for: request).activeQuestionIndex == 1)
    }
}
