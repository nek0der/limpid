// ApprovalPresentationStoreTests.swift
// Limpid — transient native approval card selection tests.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct ApprovalPresentationStoreTests {
    @Test func newRequest_waitsForRowPreview() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let first = approval(epoch: epoch)
        let second = approval(epoch: epoch)

        store.updatePending([first])
        #expect(store.presentedApproval == nil)
        store.previewBegan(first)
        #expect(store.presentedApproval == first)
        store.updatePending([first, second])
        #expect(store.presentedApproval == first)
        store.dismissCard()
        let third = approval(epoch: epoch)
        store.updatePending([first, second, third])
        #expect(store.presentedApproval == nil)
    }

    @Test func removedPresentedRequest_doesNotPromoteExistingRequest() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let first = approval(epoch: epoch)
        let second = approval(epoch: epoch)

        store.updatePending([first, second])
        store.present(first)
        store.updatePending([second])
        #expect(store.presentedApproval == nil)
    }

    @Test func reconnectSameEpoch_doesNotOpenRequestWithoutPreview() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let request = approval(epoch: epoch)

        store.updatePending([request], epoch: epoch)
        store.dismissCard()
        store.updatePending([], epoch: epoch)
        store.updatePending([request], epoch: epoch)
        #expect(store.presentedApproval == nil)
    }

    @Test func changedEpoch_doesNotOpenRequestWithoutPreview() {
        let store = ApprovalPresentationStore()
        let firstEpoch = UUID()
        let secondEpoch = UUID()

        store.updatePending([approval(epoch: firstEpoch)], epoch: firstEpoch)
        store.dismissCard()
        let replacement = approval(epoch: secondEpoch)
        store.updatePending([replacement], epoch: secondEpoch)
        #expect(store.presentedApproval == nil)
    }

    @Test func hoverPresentation_doesNotRequestCardFocus_untilExplicitlyPresented() {
        let store = ApprovalPresentationStore()
        let request = approval()

        store.updatePending([request])
        store.dismissCard()
        store.previewBegan(request)
        #expect(store.presentedApproval == request)
        #expect(store.cardFocusRequestID == nil)

        store.present(request)
        #expect(store.cardFocusRequestID == request.id)
    }

    @Test func firstSeenTime_survivesReconnectWithinSameEpoch() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let request = approval(epoch: epoch)

        store.updatePending([request], epoch: epoch)
        let firstSeenAt = store.firstSeenAt(for: request)
        store.updatePending([], epoch: epoch)
        store.updatePending([request], epoch: epoch)

        #expect(store.firstSeenAt(for: request) == firstSeenAt)
    }

    @Test func hoverPreview_dismissesAfterLeavingRowAndCard() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let request = approval()

        store.updatePending([request])
        store.dismissCard()
        store.previewBegan(request)
        store.cardHoverChanged(true)
        store.previewEnded(request)
        await Task.yield()
        #expect(store.presentedApproval == request)

        store.cardHoverChanged(false)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(store.presentedApproval == nil)
    }

    @Test func passivePreview_replacesClickedCardLikePRHover() {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let first = approval()
        let second = approval(epoch: first.epoch)

        store.updatePending([first, second])
        store.present(first)
        store.previewBegan(second)

        #expect(store.presentedApproval == second)
        #expect(store.cardFocusRequestID == nil)
    }

    @Test func clickedCard_dismissesAfterFocusHandoffAndFocusLoss() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let request = approval()

        store.updatePending([request])
        store.present(request)
        store.cardFocusChanged(true, for: request)
        store.previewEnded(request)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(store.presentedApproval == request)

        store.cardFocusChanged(false, for: request)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(store.presentedApproval == nil)
    }

    @Test func focusLoss_doesNotDismissWhileCardIsHovered() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let request = approval()

        store.updatePending([request])
        store.present(request)
        store.cardFocusChanged(true, for: request)
        store.cardHoverChanged(true)
        store.cardFocusChanged(false, for: request)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(store.presentedApproval == request)
    }

    @Test func staleFocusLoss_doesNotDismissReplacementCard() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let first = approval()
        let second = approval(epoch: first.epoch)

        store.updatePending([first, second])
        store.present(first)
        store.previewBegan(second)
        store.cardFocusChanged(false, for: first)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(store.presentedApproval == second)
    }

    @Test func failedFocusHandoff_doesNotLeaveCardPinned() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let request = approval()

        store.updatePending([request])
        store.present(request)
        store.cardFocusRequestCompleted(for: request)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(store.presentedApproval == nil)
    }

    @Test func cardExit_doesNotDismissWhileRowRemainsActive() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let request = approval()

        store.updatePending([request])
        store.previewBegan(request)
        store.cardHoverChanged(true)
        store.cardHoverChanged(false)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(store.presentedApproval == request)

        store.previewEnded(request)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(store.presentedApproval == nil)
    }

    @Test func lastActiveRowExit_dismissesCardPresentedByAnotherRow() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .zero)
        let first = approval()
        let second = approval(epoch: first.epoch)

        store.updatePending([first, second])
        store.previewBegan(first)
        store.previewBegan(second)
        store.previewEnded(second)
        store.previewEnded(first)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(store.presentedApproval == nil)
    }

    @Test func questionCard_dismissesLikeAnyCardAndKeepsItsDraft() async {
        let store = ApprovalPresentationStore(previewDismissDelay: .milliseconds(20))
        let request = approval(questions: [question])
        store.updatePending([request])
        store.present(request)
        var draft = store.answerDraft(for: request)
        draft.toggle(label: "Red", questionIndex: 0, in: question)
        store.updateAnswerDraft(draft, for: request)

        store.cardFocusChanged(true, for: request)
        store.cardFocusChanged(false, for: request)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(store.presentedApproval == nil)

        store.present(request)
        #expect(store.answerDraft(for: request).answers(for: [question]) == ["Which color?": "Red"])
    }

    @Test func rowPreview_replacesQuestionCardWithoutLosingDraft() {
        let store = ApprovalPresentationStore(previewDismissDelay: .milliseconds(20))
        let first = approval(questions: [question])
        let second = approval(epoch: first.epoch)
        store.updatePending([first, second])
        store.present(first)
        var draft = store.answerDraft(for: first)
        draft.setFreeText("Green", questionIndex: 0, in: question)
        store.updateAnswerDraft(draft, for: first)

        store.previewBegan(second)
        #expect(store.presentedApproval == second)
        #expect(store.answerDraft(for: first).freeText[0] == "Green")
    }

    @Test func answerDraft_leavesWithItsRequest() {
        let store = ApprovalPresentationStore()
        let request = approval(questions: [question])
        store.updatePending([request])
        var draft = store.answerDraft(for: request)
        draft.toggle(label: "Red", questionIndex: 0, in: question)
        store.updateAnswerDraft(draft, for: request)

        store.updatePending([])
        store.updatePending([request])
        #expect(store.answerDraft(for: request) == ApprovalAnswerDraft())

        // A request that is no longer pending cannot gain a draft either.
        store.updatePending([])
        store.updateAnswerDraft(draft, for: request)
        store.updatePending([request])
        #expect(store.answerDraft(for: request) == ApprovalAnswerDraft())
    }

    @Test func resolve_answer_sendsAnswersAndClearsResolving() async {
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
        })
        let request = approval(epoch: UUID(), questions: [
            ApprovalQuestion(
                header: "Color",
                prompt: "Which color?",
                options: [.init(label: "Red", description: nil)],
                isMultiSelect: false
            )
        ])
        store.updatePending([request])
        store.resolve(request, .answer(["Which color?": "Red"]))
        await recorded.waitForCount(1)
        await waitUntilSettled(store, request)
        #expect(await recorded.entries.first?.1 == .answer(["Which color?": "Red"]))
        #expect(!store.resolvingIDs.contains(request.id))
    }

    @Test func resolve_failure_clearsResolvingState() async {
        struct Failure: Error {}
        let store = ApprovalPresentationStore(decisionSender: { _, _ in throw Failure() })
        let request = approval(epoch: UUID())
        store.updatePending([request])
        store.resolve(request, .allowOnce)
        await waitUntilSettled(store, request)
        #expect(!store.resolvingIDs.contains(request.id))
        #expect(store.lastFailureID == request.id)
    }

    @Test func releaseStaleApprovals_delegatesOnceTheTurnIsOver() async {
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
        })
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "claude-session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .running, updatedAt: Date())]
        }
        let request = approval(epoch: UUID(), sessionID: "claude-session")
        store.updatePending([request])

        // An active turn alone proves no answer. We keep the request until
        // the turn ends, even if the needs-input projection is missed.
        store.releaseStaleApprovals(in: session)
        #expect(await recorded.entries.isEmpty)

        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .needsInput, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        #expect(await recorded.entries.isEmpty)

        // A background subagent or another tool puts the session back into
        // `running` while the dialog is still open; that is no answer.
        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .running, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        await Task.yield()
        #expect(store.resolvingIDs.isEmpty)
        #expect(await recorded.entries.isEmpty)

        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        // A second projection that lands before the decision settles must
        // not send it again. Calling without a suspension point in between
        // keeps the first decision in flight regardless of scheduling.
        store.releaseStaleApprovals(in: session)
        await recorded.waitForCount(1)
        await waitUntilSettled(store, request)
        #expect(await recorded.entries.first?.1 == .delegate)
        #expect(await recorded.entries.count == 1)
    }

    @Test func releaseStaleApprovals_skipsRequestSettledBeforeProjectionDropsIt() async {
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
        })
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "claude-session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .needsInput, updatedAt: Date())]
        }
        let request = approval(epoch: UUID(), sessionID: "claude-session", questions: [question])
        store.updatePending([request])
        store.releaseStaleApprovals(in: session)

        store.resolve(request, .answer(["Which color?": "Red"]))
        await recorded.waitForCount(1)
        await waitUntilSettled(store, request)

        // The turn ends before the broker projection drops the answered
        // request; a late `delegate` would be rejected as already terminal.
        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        await Task.yield()
        #expect(store.resolvingIDs.isEmpty)
        #expect(await recorded.entries.count == 1)
        #expect(store.lastFailureID == nil)
    }

    @Test func releaseStaleApprovals_releasesAfterRunningWithoutNeedsInput() async {
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
        })
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .running, updatedAt: Date())]
        }
        let request = approval(sessionID: "session", questions: [question])
        store.updatePending([request])
        store.releaseStaleApprovals(in: session)
        #expect(await recorded.entries.isEmpty)
        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        await recorded.waitForCount(1)
        #expect(await recorded.entries.first?.1 == .delegate)
    }

    @Test func releaseStaleApprovals_leavesScopedQuestionsToTheirOwnTurnCompletion() async {
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
        })
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 20))]
        }
        let request = approval(
            sessionID: "session", operationID: AgentQuestionTurnCompletion.operationIDPrefix + "question",
            questions: [question]
        )
        store.updatePending([request])
        store.releaseStaleApprovals(in: session)
        await Task.yield()
        #expect(await recorded.entries.isEmpty)
    }

    @Test func releaseStaleApprovals_keepsAQuestionIssuedAfterThePreviousTurnEnded() async {
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
        })
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 10))]
        }
        let request = approval(sessionID: "session", questions: [question])
        store.updatePending([request])
        store.releaseStaleApprovals(in: session)
        await Task.yield()
        #expect(await recorded.entries.isEmpty)
        #expect(store.resolvingIDs.isEmpty)
    }

    @Test func releaseFailure_neitherReportsNorRetries() async {
        struct Failure: Error {}
        let recorded = Recorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append((approval.id, resolution))
            throw Failure()
        })
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "claude-session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .needsInput, updatedAt: Date())]
        }
        let request = approval(epoch: UUID(), sessionID: "claude-session")
        store.updatePending([request])
        store.releaseStaleApprovals(in: session)
        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date())]
        }

        store.releaseStaleApprovals(in: session)
        await recorded.waitForCount(1)
        await waitUntilSettled(store, request)
        // Nobody pressed anything, so the card must not ask to try again.
        #expect(store.lastFailureID == nil)

        // The next projection pass must not resend a release that failed.
        store.releaseStaleApprovals(in: session)
        await Task.yield()
        #expect(store.resolvingIDs.isEmpty)
        #expect(await recorded.entries.count == 1)
    }

    @Test func resolve_keepsTheFailureOfAnotherRequest() async {
        struct Failure: Error {}
        let failing = approval(epoch: UUID())
        let succeeding = approval(epoch: failing.epoch)
        let failingID = failing.id
        let store = ApprovalPresentationStore(decisionSender: { approval, _ in
            if approval.id == failingID {
                throw Failure()
            }
        })
        store.updatePending([failing, succeeding])

        store.resolve(failing, .allowOnce)
        await waitUntilSettled(store, failing)
        #expect(store.lastFailureID == failing.id)

        store.resolve(succeeding, .allowOnce)
        await waitUntilSettled(store, succeeding)
        #expect(store.lastFailureID == failing.id)
    }

    @Test func decode_questions_readsSnapshotShape() {
        let decoded = ApprovalQuestion.decode([
            [
                "header": "Color",
                "prompt": "Which color?",
                "multi_select": true,
                "options": [["label": "Red", "description": "warm"], ["label": "Blue"]]
            ],
            ["prompt": "Which size?"]
        ])
        #expect(decoded.count == 2)
        #expect(decoded[0].isMultiSelect)
        #expect(decoded[0].options[1].description == nil)
        #expect(decoded[1].options.isEmpty)
        #expect(ApprovalQuestion.decode(nil).isEmpty)
    }

    /// The sender runs off the main actor and the store clears its resolving
    /// state only after hopping back, so a single yield does not guarantee
    /// the decision task has finished. The deadline keeps a regression from
    /// hanging the suite.
    private func waitUntilSettled(
        _ store: ApprovalPresentationStore,
        _ request: ApprovalPresentation
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while store.resolvingIDs.contains(request.id), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    private let question = ApprovalQuestion(
        header: "Color",
        prompt: "Which color?",
        options: [.init(label: "Red", description: nil)],
        isMultiSelect: false
    )

    private func approval(
        epoch: UUID = UUID(),
        sessionID: String? = nil,
        operationID: String? = nil,
        questions: [ApprovalQuestion] = []
    ) -> ApprovalPresentation {
        ApprovalPresentation(
            epoch: epoch, runID: UUID(), requestID: UUID(), provider: .claude,
            sessionID: sessionID, operationID: operationID, toolName: "Bash", summary: nil, requestDescription: nil,
            inputDescription: "{}",
            deadlineMilliseconds: 0,
            questions: questions
        )
    }
}

/// Collects the decisions a store hands to its injected sender, so a test can
/// observe what would have crossed the XPC boundary.
private actor Recorder {
    private(set) var entries: [(String, ApprovalResolution)] = []

    func append(_ entry: (String, ApprovalResolution)) {
        entries.append(entry)
    }

    /// The deadline makes a store that never calls its sender fail the
    /// following expectations instead of hanging the suite.
    func waitForCount(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while entries.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}
