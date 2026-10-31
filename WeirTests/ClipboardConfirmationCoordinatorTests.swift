// ClipboardConfirmationCoordinatorTests.swift
// Weir — which clipboard answers reach libghostty, and with which request state.

import Foundation
import GhosttyKit
import Testing
@testable import Weir

/// A pane with a stand-in surface pointer. Nothing dereferences it: the
/// answerer under test records calls instead of making them.
@MainActor
private final class FakeClipboardTarget: ClipboardRequestTarget {
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can free it; it is
    /// never written, and nothing else holds the target by then.
    private nonisolated(unsafe) let storage = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    var isAlive = true
    let clipboardRequests = ClipboardRequestTracker()
    let surfaceView: SurfaceView? = nil

    var surface: ghostty_surface_t? {
        isAlive ? storage : nil
    }

    var liveSurface: ghostty_surface_t {
        storage
    }

    deinit {
        storage.deallocate()
    }
}

/// Distinct request states, as libghostty would allocate them.
private final class FakeRequestStates {
    private var storage: [UnsafeMutableRawPointer] = []

    func make() -> ClipboardRequestState {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        storage.append(pointer)
        return ClipboardRequestState(pointer: pointer)
    }

    deinit {
        storage.forEach { $0.deallocate() }
    }
}

@MainActor
private final class AnswerLog {
    var denied: [(surface: ghostty_surface_t, state: ClipboardRequestState)] = []
    var completed: [ClipboardRequestState] = []
    var pasteboardWrites: [String] = []

    var answerer: ClipboardRequestAnswerer {
        ClipboardRequestAnswerer(
            deny: { [unowned self] surface, state in denied.append((surface, state)) },
            complete: { [unowned self] _, _, state in completed.append(state) },
            writePasteboard: { [unowned self] text in pasteboardWrites.append(text) }
        )
    }
}

@MainActor
struct ClipboardConfirmationCoordinatorTests {
    @Test func overlappingWrites_secondIsDroppedWithoutReachingLibghostty() {
        let log = AnswerLog()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()

        coordinator.enqueue(.osc52Write, contents: "first", target: target)
        coordinator.enqueue(.osc52Write, contents: "second", target: target)

        #expect(log.denied.isEmpty, "a write has no request state for the C deny")
        #expect(log.pasteboardWrites.isEmpty, "a refused write never reaches the pasteboard")
        #expect(coordinator.pending?.contents == "first")

        coordinator.deny()
        #expect(log.denied.isEmpty)
        #expect(log.pasteboardWrites.isEmpty)
    }

    @Test func overlappingReads_secondIsDeniedWithItsOwnState() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()
        let first = states.make()
        let second = states.make()
        #expect(target.clipboardRequests.track(first))
        #expect(target.clipboardRequests.track(second))

        coordinator.enqueue(.libghostty(.osc52Read, first), contents: "", target: target)
        coordinator.enqueue(.libghostty(.osc52Read, second), contents: "", target: target)

        #expect(log.denied.map(\.state) == [second])
        #expect(log.denied.first?.surface == target.liveSurface)
        #expect(!target.clipboardRequests.isTracking(second))
        #expect(target.clipboardRequests.isTracking(first), "the first still waits for the sheet")
    }

    @Test func readBehindAPendingWrite_isDeniedWithItsOwnState() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()
        let read = states.make()
        #expect(target.clipboardRequests.track(read))

        coordinator.enqueue(.osc52Write, contents: "text", target: target)
        coordinator.enqueue(.libghostty(.unsafePaste, read), contents: "", target: target)

        #expect(log.denied.map(\.state) == [read])
    }

    @Test func answeredRequest_isNotDeniedAgainAtTeardown() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()
        let allowed = states.make()
        let denied = states.make()
        #expect(target.clipboardRequests.track(allowed))
        #expect(target.clipboardRequests.track(denied))

        coordinator.enqueue(.libghostty(.unsafePaste, allowed), contents: "paste", target: target)
        coordinator.allow()
        coordinator.enqueue(.libghostty(.osc52Read, denied), contents: "", target: target)
        coordinator.deny()

        #expect(log.completed == [allowed])
        #expect(log.denied.map(\.state) == [denied])
        var deniedAtTeardown: [ClipboardRequestState] = []
        target.clipboardRequests.denyUnanswered { deniedAtTeardown.append($0) }
        #expect(deniedAtTeardown.isEmpty)
    }

    @Test func teardown_deniesARequestThatWasNeverRegistered() {
        let states = FakeRequestStates()
        let tracker = ClipboardRequestTracker()
        let state = states.make()
        // The callback tracked it, and the pane went away before the
        // main-actor work that would have registered it ran.
        #expect(tracker.track(state))

        var denied: [ClipboardRequestState] = []
        tracker.denyUnanswered { denied.append($0) }

        #expect(denied == [state])
        #expect(!tracker.claim(state), "a request denied at teardown cannot be answered again")
        #expect(!tracker.track(states.make()), "a torn-down surface keeps no new request")
    }

    @Test func requestFromAClosedPane_isLeftForTeardownToDeny() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()
        let state = states.make()
        #expect(target.clipboardRequests.track(state))
        coordinator.enqueue(.libghostty(.osc52Read, state), contents: "", target: target)

        target.isAlive = false
        coordinator.deny()

        #expect(log.denied.isEmpty, "no surface to answer on")
        var deniedAtTeardown: [ClipboardRequestState] = []
        target.clipboardRequests.denyUnanswered { deniedAtTeardown.append($0) }
        #expect(deniedAtTeardown == [state])
    }

    @Test func requestFromAFreedPane_isLeftForTeardownToDeny() throws {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        var target: FakeClipboardTarget? = FakeClipboardTarget()
        let tracker = target?.clipboardRequests ?? ClipboardRequestTracker()
        let denied = states.make()
        let allowed = states.make()
        #expect(tracker.track(denied))
        try coordinator.enqueue(.libghostty(.osc52Read, denied), contents: "", target: #require(target))

        // The pane is freed while its sheet is up: the weak target goes nil.
        target = nil
        coordinator.deny()
        #expect(log.denied.isEmpty, "no surface to answer on")

        let root = URL(fileURLWithPath: "/tmp/clipboard-freed-pane")
        let receipt = ReviewPasteReceipt(root: root, commentIDs: [UUID()], settlement: ReviewPasteSettlement())
        var paneForAllow: FakeClipboardTarget? = FakeClipboardTarget()
        let allowTracker = paneForAllow?.clipboardRequests ?? ClipboardRequestTracker()
        #expect(allowTracker.track(allowed))
        try coordinator.enqueue(
            .libghostty(.unsafePaste, allowed),
            contents: "paste",
            target: #require(paneForAllow),
            receipt: receipt
        )
        paneForAllow = nil
        coordinator.allow()
        #expect(log.completed.isEmpty)
        #expect(receipt.settlement?.wasDelivered == false, "allowed into a freed pane is nothing delivered")

        var deniedAtTeardown: [ClipboardRequestState] = []
        tracker.denyUnanswered { deniedAtTeardown.append($0) }
        allowTracker.denyUnanswered { deniedAtTeardown.append($0) }
        #expect(Set(deniedAtTeardown) == [denied, allowed])
    }

    @Test func allowedWrite_reachesThePasteboardOnly() {
        let log = AnswerLog()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()

        coordinator.enqueue(.osc52Write, contents: "text", target: target)
        coordinator.allow()

        #expect(log.pasteboardWrites == ["text"])
        #expect(log.denied.isEmpty)
        #expect(log.completed.isEmpty)
    }

    @Test func allowTwice_completesOnce() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()
        let state = states.make()
        #expect(target.clipboardRequests.track(state))

        coordinator.enqueue(.libghostty(.unsafePaste, state), contents: "paste", target: target)
        coordinator.allow()
        coordinator.allow()
        coordinator.deny()

        #expect(log.completed == [state])
        #expect(log.denied.isEmpty)
    }

    @Test func cancelPending_answersOnlyTheClosingPane() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let coordinator = ClipboardConfirmationCoordinator(answerer: log.answerer)
        let target = FakeClipboardTarget()
        let other = FakeClipboardTarget()
        let state = states.make()
        #expect(target.clipboardRequests.track(state))
        coordinator.enqueue(.libghostty(.osc52Read, state), contents: "", target: target)

        coordinator.cancelPending(for: other)
        #expect(log.denied.isEmpty)
        #expect(coordinator.pending != nil)

        coordinator.cancelPending(for: target)
        #expect(log.denied.map(\.state) == [state])
        #expect(coordinator.pending == nil)
    }

    @Test func untrackedState_neverReachesLibghostty() {
        let log = AnswerLog()
        let states = FakeRequestStates()
        let target = FakeClipboardTarget()

        log.answerer.refuse(states.make(), on: target)

        #expect(log.denied.isEmpty, "only a request still waiting may be answered")
    }
}
