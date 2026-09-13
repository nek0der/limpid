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

    private func approval(epoch: UUID = UUID()) -> ApprovalPresentation {
        ApprovalPresentation(
            epoch: epoch, runID: UUID(), requestID: UUID(), provider: .claude,
            sessionID: nil, toolName: "Bash", summary: nil, requestDescription: nil,
            inputDescription: "{}",
            deadlineMilliseconds: 0
        )
    }
}
