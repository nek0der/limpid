// ApprovalLedgerTests.swift
// Weir — requests kept past the pending list, settled by what the broker
// reports, and what the store reads from the ledger.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalLedgerTests {
    static let now = SuspendingClock.now
    /// When a request is first seen pending, on the wall clock.
    static let seenAt = Date(timeIntervalSince1970: 1000)
    /// A later reading of the same list.
    static let laterSight = seenAt.addingTimeInterval(1)

    // MARK: - Ledger

    @Test func eachEnding_isKeptApart() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let delegated = ApprovalPresentation.test(epoch: epoch)
        let expired = ApprovalPresentation.test(epoch: epoch)
        let canceled = ApprovalPresentation.test(epoch: epoch)
        let answered = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [delegated, expired, canceled, answered], epoch: epoch)

        ledger.settle(id: delegated.id, by: .resolved(.delegate), now: Self.now)
        ledger.settle(id: expired.id, by: .expired, now: Self.now)
        ledger.settle(id: canceled.id, by: .canceled, now: Self.now)
        ledger.settle(id: answered.id, by: .resolved(.allowOnce), now: Self.now)

        #expect(ledger.entry(for: delegated)?.state == .handedToTerminal(since: Self.now))
        #expect(ledger.entry(for: expired)?.state == .timedOut)
        #expect(ledger.entry(for: canceled)?.state == .withdrawn)
        #expect(ledger.entry(for: answered)?.state == .answered(.allowOnce))
    }

    @Test func leavingThePendingList_doesNotForgetARequest() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [request], epoch: epoch)

        ledger.observe(pending: [], epoch: epoch)

        #expect(ledger.entry(for: request)?.state == .held)
        #expect(ledger.trackedIDs == [request.id])
    }

    @Test func theEndOfItsEpisode_forgetsARequest() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [request], epoch: epoch)

        ledger.endEpisode(id: request.id)

        #expect(ledger.entry(for: request) == nil)
    }

    @Test func anEndedRequest_isNotBroughtBackByAStaleProjection() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [request], epoch: epoch)

        ledger.endEpisode(id: request.id)
        ledger.observe(pending: [request], epoch: epoch)

        #expect(ledger.entry(for: request) == nil)
        #expect(ledger.entry(id: request.id) == nil)
    }

    @Test func aNewEpoch_leavesTheOldHeldRequestToTheAgentsPrompt() {
        let ledger = ApprovalLedger()
        let old = ApprovalPresentation.test()
        ledger.observe(pending: [old], epoch: old.epoch)

        let epoch = UUID()
        let fresh = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [fresh], epoch: epoch)

        // The helper lost the old service and answered nothing, so the
        // agent's own prompt took the request.
        #expect(ledger.entry(for: old)?.state == .unknownResult)
        #expect(ledger.entry(for: old)?.holdsCardOpen == false)
        #expect(ledger.entry(for: fresh)?.state == .held)
        #expect(ledger.trackedIDs == [fresh.id], "the new broker cannot know the old key")
    }

    @Test func aNewEpoch_keepsWhatWaitsAtTheAgentsPrompt_andDropsWhatWasSettled() {
        let ledger = ApprovalLedger()
        let old = UUID()
        let delegated = ApprovalPresentation.test(epoch: old)
        let expired = ApprovalPresentation.test(epoch: old)
        let answered = ApprovalPresentation.test(epoch: old)
        let withdrawn = ApprovalPresentation.test(epoch: old)
        ledger.observe(pending: [delegated, expired, answered, withdrawn], epoch: old)
        ledger.settle(id: delegated.id, by: .resolved(.delegate), now: Self.now)
        ledger.settle(id: expired.id, by: .expired, now: Self.now)
        ledger.settle(id: answered.id, by: .resolved(.allowOnce), now: Self.now)
        ledger.settle(id: withdrawn.id, by: .canceled, now: Self.now)

        ledger.observe(pending: [], epoch: UUID())

        #expect(ledger.entry(for: delegated)?.state == .handedToTerminal(since: Self.now))
        #expect(ledger.entry(for: expired)?.state == .timedOut)
        #expect(ledger.entry(for: answered) == nil)
        #expect(ledger.entry(for: withdrawn) == nil)
        #expect(ledger.trackedIDs.isEmpty)
    }

    @Test func aSettledRequest_isNoLongerLookedUp() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let answered = ApprovalPresentation.test(epoch: epoch)
        let lost = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [answered, lost], epoch: epoch)

        ledger.settle(id: answered.id, by: .resolved(.deny), now: Self.now)
        ledger.markMissing(id: lost.id, now: Self.now)

        #expect(ledger.trackedIDs.isEmpty)
        #expect(ledger.entry(for: lost)?.state == .unknownResult)
    }

    @Test func theFirstWaitNoted_staysTheRequestsOwn() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [request], epoch: epoch)

        ledger.noteWait(id: request.id, episodeToken: "w1")
        ledger.noteWait(id: request.id, episodeToken: "w2")
        #expect(ledger.entry(for: request)?.waitEpisodeToken == "w1")
        ledger.noteWait(id: "unknown", episodeToken: "w3")
        #expect(ledger.entries.count == 1, "an unknown request is not added")
    }

    @Test func aTimeoutOnlyOurClockSaw_isLookedUpUntilTheBrokerSpeaks() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let byClock = ApprovalPresentation.test(epoch: epoch)
        let byBroker = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [byClock, byBroker], epoch: epoch)

        ledger.record(.deadlinePassed, for: byClock.id, now: Self.now)
        ledger.settle(id: byBroker.id, by: .expired, now: Self.now)
        // Our clock is an estimate: the broker may still have taken an answer.
        #expect(ledger.trackedIDs == [byClock.id])

        // The broker expiring it too leaves the state as it was, but there
        // is nothing more to ask.
        ledger.settle(id: byClock.id, by: .expired, now: Self.now)
        #expect(ledger.entry(for: byClock)?.state == .timedOut)
        #expect(ledger.trackedIDs.isEmpty)
    }

    @Test func aCardStaysOpenOnlyWhileTheRequestNeedsIt() {
        let ledger = ApprovalLedger()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        ledger.observe(pending: [request], epoch: epoch)
        #expect(ledger.entry(for: request)?.holdsCardOpen == true)

        ledger.settle(id: request.id, by: .resolved(.allowOnce), now: Self.now)
        #expect(ledger.entry(for: request)?.holdsCardOpen == false)

        ledger.markAnsweredElsewhere(id: request.id)
        #expect(ledger.entry(for: request)?.holdsCardOpen == true)
    }

    // MARK: - First sight

    @Test func aRequestReadAgain_keepsItsFirstSight() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let request = ApprovalPresentation.test()
        store.receive([request], seenAt: Self.seenAt)

        store.receive([request], seenAt: Self.laterSight)
        store.receive([], epoch: request.epoch, seenAt: Self.laterSight)
        store.receive([request], seenAt: Self.laterSight)

        #expect(store.ledger.entry(for: request)?.firstSeenAt == Self.seenAt)
        #expect(store.firstSeenAt(for: request) == Self.seenAt)
    }

    @Test func aNewEpoch_seesItsRequestsAfresh() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let old = ApprovalPresentation.test()
        store.receive([old], seenAt: Self.seenAt)
        // The restarted service's broker hands out the same run and request.
        let fresh = ApprovalPresentation.test(runID: old.runID, requestID: old.requestID)

        store.receive([fresh], seenAt: Self.laterSight)

        #expect(store.ledger.entry(for: fresh)?.state == .held)
        #expect(store.ledger.entry(for: fresh)?.firstSeenAt == Self.laterSight)
        #expect(store.firstSeenAt(for: fresh) == Self.laterSight)
        // The old one waits at the agent's prompt, under its own first sight.
        #expect(store.ledger.entry(for: old)?.state == .unknownResult)
        #expect(store.firstSeenAt(for: old) == Self.seenAt)
    }

    @Test func theFirstSight_isWhenTheRequestArrivedInTheList() throws {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let request = ApprovalPresentation.test()
        store.receive([request], seenAt: Self.seenAt)

        let placed = try #require(store.placedApprovals(in: WorkspaceSession()).first)

        #expect(store.firstSeenAt(for: request) == Self.seenAt)
        #expect(placed.arrivedAt == Self.seenAt)
    }

    // MARK: - The store's reading of the ledger

    @Test func stop_keepsTheLedger_andForgetsOnlyItsReading() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        let delegated = ApprovalPresentation.test(epoch: epoch)
        let expired = ApprovalPresentation.test(epoch: epoch)
        let held = ApprovalPresentation.test(epoch: epoch)
        store.receive([delegated, expired, held])
        store.receive([held], epoch: epoch, terminals: [delegated.id: .resolved(.delegate), expired.id: .expired])

        store.stop()

        #expect(store.ledger.entry(for: delegated)?.state.isLeftToTerminal == true)
        #expect(store.ledger.entry(for: expired)?.state == .timedOut)
        #expect(store.ledger.entry(for: held)?.state == .held)
        #expect(store.ledger.trackedIDs.contains(held.id), "looked up on reconnect")
        #expect(store.ledger.epoch == nil, "a stopped service has not been read")
        #expect(store.pending.isEmpty)
    }

    @Test func stop_thenTheSameEpoch_keepsTheDelegatedAndTheHeldRequest() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        let delegated = ApprovalPresentation.test(epoch: epoch)
        let held = ApprovalPresentation.test(epoch: epoch)
        store.receive([delegated, held], seenAt: Self.seenAt)
        store.receive([held], epoch: epoch, terminals: [delegated.id: .resolved(.delegate)])
        store.stop()

        store.receive([held], epoch: epoch, seenAt: Self.laterSight)

        #expect(store.ledger.entry(for: delegated)?.state.isLeftToTerminal == true)
        #expect(store.ledger.entry(for: held)?.state == .held)
        #expect(store.ledger.entry(for: held)?.firstSeenAt == Self.seenAt, "it keeps its first sight")
        #expect(!store.ledger.trackedIDs.contains(delegated.id), "nothing left to ask the broker")
    }

    @Test func stop_duringAHandOff_keepsTheRequest_andTheSendStillLands() async {
        let gate = Gate<Void>()
        let store = ApprovalPresentationStore(decisionSender: { _, _ in await gate.wait() })
        let request = ApprovalPresentation.test()
        store.receive([request])
        store.handOffSeenRequests(attention: AttentionVisibility(), session: WorkspaceSession(), holdsWhileHidden: false)
        await gate.waitUntilRequested()

        store.stop()
        #expect(store.ledger.entry(for: request) != nil, "the hand-off is in flight")
        gate.open()
        await pollUntil { store.ledger.entry(for: request)?.state.isLeftToTerminal == true }
        store.receive([], epoch: request.epoch)

        #expect(store.ledger.entry(for: request)?.state.isLeftToTerminal == true)
    }

    @Test func aNewEpoch_keepsARequestOurClockTimedOut_althoughTheNewBrokerCallsItMissing() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let request = ApprovalPresentation.test()
        let reading = ServiceDeadline(deadlineMs: 1000, serviceNowMs: 0, receivedAt: Self.now)
        store.apply(.test(pending: [request], deadlines: [request.id: reading]), epoch: request.epoch, now: Self.now)
        store.checkDeadlines(now: Self.now.advanced(by: .seconds(2)))
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
        #expect(store.ledger.trackedIDs.contains(request.id))

        // Read before the new epoch arrived, the tracked IDs come back missing.
        store.receive([], epoch: UUID(), missing: [request.id])

        #expect(store.ledger.entry(for: request)?.state == .timedOut)
        #expect(store.ledger.trackedIDs.isEmpty)
    }

    @Test func aSendThatLandsAfterANewEpoch_leavesTheRequestAtTheAgentsPrompt() async {
        let gate = Gate<Void>()
        let store = ApprovalPresentationStore(decisionSender: { _, _ in await gate.wait() })
        let request = ApprovalPresentation.test()
        store.receive([request])
        store.resolve(request, .allowOnce)
        await gate.waitUntilRequested()

        store.receive([], epoch: UUID())
        #expect(store.ledger.entry(for: request)?.state == .unknownResult)
        // The pending list no longer names it, so only the send's own
        // completion, which tells the cards, says it has landed.
        var hasLanded = false
        store.onRequestsChanged = { hasLanded = true }
        gate.open()
        await pollUntil { hasLanded }

        #expect(hasLanded)
        #expect(store.ledger.entry(for: request)?.state == .unknownResult)
    }

    @Test func stop_aHeldRequestTheBrokerExpiredMeanwhile_timesOut() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let held = ApprovalPresentation.test()
        store.receive([held])
        store.stop()

        // Still tracked, so the reconnect looks it up and learns it expired.
        store.receive([], epoch: held.epoch, terminals: [held.id: .expired])

        #expect(store.ledger.entry(for: held)?.state == .timedOut)
    }

    @Test func stop_thenAnotherEpoch_keepsWhatWaitsAtTheAgentsPrompt() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        let delegated = ApprovalPresentation.test(epoch: epoch)
        let held = ApprovalPresentation.test(epoch: epoch)
        store.receive([delegated, held])
        store.receive([held], epoch: epoch, terminals: [delegated.id: .resolved(.delegate)])
        store.stop()

        store.receive([], epoch: UUID())

        #expect(store.ledger.entry(for: delegated)?.state.isLeftToTerminal == true)
        #expect(store.ledger.entry(for: held)?.state == .unknownResult)
        #expect(store.ledger.trackedIDs.isEmpty)
    }

    @Test func aDroppedSubscription_keepsTheWholeLedgerAndItsReading() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        let delegated = ApprovalPresentation.test(epoch: epoch)
        let held = ApprovalPresentation.test(epoch: epoch)
        store.receive([delegated, held], seenAt: Self.seenAt)
        store.receive([held], epoch: epoch, terminals: [delegated.id: .resolved(.delegate)])

        store.connectionDidDrop()

        #expect(store.pending.isEmpty)
        #expect(store.ledger.epoch == epoch)
        #expect(store.ledger.entry(for: held)?.state == .held)
        #expect(store.ledger.entry(for: delegated)?.state.isLeftToTerminal == true)

        store.receive([held], epoch: epoch, seenAt: Self.laterSight)

        #expect(store.ledger.entry(for: held)?.firstSeenAt == Self.seenAt)
        #expect(store.ledger.entry(for: delegated)?.state.isLeftToTerminal == true)
    }

    @Test func facts_markCodexQuestionsAsAnsweredInTheTerminal() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let question = ApprovalQuestion(header: nil, prompt: "Which?", options: [], isMultiSelect: false)
        let codexQuestion = ApprovalPresentation.test(epoch: epoch, provider: .codex, questions: [question])
        let claudeQuestion = ApprovalPresentation.test(epoch: epoch, provider: .claude, questions: [question])
        let approval = ApprovalPresentation.test(epoch: epoch, provider: .codex)
        store.receive([codexQuestion, claudeQuestion, approval])

        let facts = Dictionary(uniqueKeysWithValues: store.approvalFacts.map { ($0.key, $0) })
        #expect(facts[codexQuestion.key]?.supportsNativeAnswer == false)
        #expect(facts[claudeQuestion.key]?.supportsNativeAnswer == true)
        #expect(facts[approval.key]?.supportsNativeAnswer == true)
        #expect(facts[approval.key]?.state == .held)
    }

    @Test func nearCapacity_countsOnlyRecordsThatCannotMakeRoom() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let limit = ApprovalPresentationStore.nearCapacityRecordCount
        func projection(unevictable: Int) -> ApprovalControllerConnection.Projection {
            ApprovalControllerConnection.Projection(
                sequence: 1, requests: [], terminals: [:], missingIDs: [], unevictableCount: unevictable, deadlines: [:]
            )
        }

        store.apply(projection(unevictable: limit - 1), epoch: epoch, now: Self.now)
        #expect(!store.isNearCapacity)
        store.apply(projection(unevictable: limit), epoch: epoch, now: Self.now)
        #expect(store.isNearCapacity)
    }
}
