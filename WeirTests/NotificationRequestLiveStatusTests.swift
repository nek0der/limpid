// NotificationRequestLiveStatusTests.swift
// Weir — a request's history row read from the approval ledger's entry for
// that request: amber while it waits, retired once it is answered or gone.

import Foundation
import Testing
@testable import Weir

@Suite("Notification request live status", .timeLimit(.minutes(1)))
@MainActor
struct NotificationRequestLiveStatusTests {

    // MARK: - Helpers

    /// The row `postRequestBanner` records for `request`: the run's ID and
    /// the request's key, and no event token.
    private func row(for request: ApprovalPresentation, isRead: Bool = false) -> NotificationEntry {
        NotificationEntry.test(
            kind: .agentNeedsInput,
            title: "Approval",
            body: "Bash",
            isRead: isRead,
            runtimeID: AgentRuntimePresentation.id(kind: .claude, runID: request.runID.uuidString),
            requestKey: request.key,
            event: RequestBannerText.event(for: request)
        )
    }

    /// A store that accepts every decision, as a broker that took it does.
    private func acceptingStore() -> ApprovalPresentationStore {
        ApprovalPresentationStore(decisionSender: { _, _ in })
    }

    /// The mark the history row draws for `entry`.
    private func mark(of entry: NotificationEntry, live: NotificationLiveStatus?) -> NotificationHistoryRowText.Mark {
        NotificationHistoryRowText.mark(
            of: entry,
            happening: NotificationHistoryRowText.happening(of: entry, locale: Locale(identifier: "en")),
            liveStatus: live,
            isSourceClosed: false
        )
    }

    // MARK: - Pure rule

    @Test func ofRequest_waitsExactlyWhileTheAttentionListListsTheRequest() {
        let waiting: [ApprovalRequestState] = [
            .held,
            .sending(.allowOnce, since: .now),
            .sendFailed(.allowOnce, error: "x"),
            .handedToTerminal(since: .now),
            .timedOut,
            .unknownResult
        ]
        for state in waiting {
            #expect(NotificationLiveStatus.ofRequest(state: state, hasReadService: true) == .stillWaiting, "\(state)")
        }
        for state in [ApprovalRequestState.answered(.allowOnce), .withdrawn] {
            #expect(NotificationLiveStatus.ofRequest(state: state, hasReadService: true) == .resolved, "\(state)")
        }
        #expect(NotificationLiveStatus.ofRequest(state: nil, hasReadService: true) == .resolved)
        // Before the first pending list the service may still hold it.
        #expect(NotificationLiveStatus.ofRequest(state: nil, hasReadService: false) == nil)
    }

    // MARK: - From the notification to its ending

    @Test func answeredOnTheCard_isNoLongerAmber_andTheSyncRetiresTheRow() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            let waiting = attention.liveStatus(for: history.entries[0], requests: store.ledger)
            #expect(waiting == .stillWaiting)
            #expect(mark(of: history.entries[0], live: waiting) == .approval)
            #expect(history.unreadCount == 1)

            store.resolve(request, .allowOnce)
            await store.waitUntilResolved(request)

            let live = attention.liveStatus(for: history.entries[0], requests: store.ledger)
            #expect(live == .resolved)
            await untilObserved { history.unreadCount == 0 }
            #expect(history.unreadCount == 0, "the ledger's change alone retires the row")
            #expect(mark(of: history.entries[0], live: live) == .idle)
            history.flushSynchronously()
            _ = sync
        }
    }

    @Test func expired_waitsAtTheAgentsPrompt_untilItsTurnIsOver() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.receive([], epoch: request.epoch, terminals: [request.id: .expired])
            #expect(store.ledger.entry(for: request)?.state == .timedOut)
            // The person answers it at the agent's own prompt now, and the
            // attention list still lists it, so the row still waits.
            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .stillWaiting)
            sync.reconcile()
            #expect(history.unreadCount == 1)

            store.ledger.endEpisode(id: request.id)
            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .resolved)
            sync.reconcile()
            #expect(history.unreadCount == 0)
            history.flushSynchronously()
        }
    }

    @Test func withdrawn_isResolved() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])

            #expect(store.ledger.entry(for: request)?.state == .withdrawn)
            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .resolved)
            sync.reconcile()
            #expect(history.unreadCount == 0)
            history.flushSynchronously()
        }
    }

    @Test func markedReadWhilePending_staysAmber() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))

            history.markAllRead()

            let entry = history.entries[0]
            #expect(entry.isRead)
            let live = attention.liveStatus(for: entry, requests: store.ledger)
            #expect(live == .stillWaiting)
            #expect(mark(of: entry, live: live) == .approval)
            history.flushSynchronously()
        }
    }

    @Test func twoRequestsOfOneRun_onlyTheAnsweredRowChanges() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let epoch = UUID()
            let runID = UUID()
            let first = ApprovalPresentation.test(epoch: epoch, runID: runID)
            let second = ApprovalPresentation.test(epoch: epoch, runID: runID)
            store.receive([first, second])
            history.record(row(for: first))
            history.record(row(for: second))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.resolve(second, .allowOnce)
            await store.waitUntilResolved(second)
            sync.reconcile()

            let firstRow = try #require(history.entries.first { $0.requestKey == first.key })
            let secondRow = try #require(history.entries.first { $0.requestKey == second.key })
            #expect(attention.liveStatus(for: firstRow, requests: store.ledger) == .stillWaiting)
            #expect(!firstRow.isRead)
            #expect(attention.liveStatus(for: secondRow, requests: store.ledger) == .resolved)
            #expect(secondRow.isRead)
            history.flushSynchronously()
        }
    }

    /// After a launch the history names a request of the last run's
    /// service, which the ledger never held. Nothing may retire it until the
    /// first pending list arrives, and that list alone (an epoch, with no
    /// entry added) has to wake the sync. Stopping the service leaves the
    /// ledger without a pending list again, so the row's status is unknown.
    @Test func aRowTheLedgerNeverHeld_waitsForTheFirstPendingList_thenRetires() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let earlier = ApprovalPresentation.test()
            history.record(row(for: earlier))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == nil)
            #expect(history.unreadCount == 1)

            // The service restarted meanwhile: a new epoch, listing nothing.
            store.receive([], epoch: UUID())
            await untilObserved { history.unreadCount == 0 }
            #expect(history.unreadCount == 0, "the epoch alone wakes the sync")
            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .resolved)

            store.stop()
            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == nil)
            history.flushSynchronously()
            _ = sync
        }
    }

    // MARK: - A readiness drop while the TUI holds the request

    /// A request handed to the TUI while its turn runs, its row recorded,
    /// then the service's readiness check fails once (`stop`) and the store
    /// reconnects to the same epoch, which lists nothing pending.
    private func delegatedThenReconnected() -> ApprovalEpisodeEndTests.EndedRequest {
        let fixture = ApprovalEpisodeEndTests.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        // The pass that sees its turn under way.
        fixture.store.releaseStaleApprovals(in: fixture.session)
        fixture.store.stop()
        fixture.store.receive([], epoch: fixture.request.epoch)
        return fixture
    }

    @Test func aDelegatedRequest_staysAmberAndUnread_acrossAReadinessDrop() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let fixture = ApprovalEpisodeEndTests.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
            let store = fixture.store
            history.record(row(for: fixture.request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.releaseStaleApprovals(in: fixture.session)

            store.stop()
            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .stillWaiting)
            store.receive([], epoch: fixture.request.epoch)
            store.releaseStaleApprovals(in: fixture.session)
            sync.reconcile()

            let live = attention.liveStatus(for: history.entries[0], requests: store.ledger)
            #expect(live == .stillWaiting, "the TUI still waits for it")
            #expect(history.unreadCount == 1)
            #expect(mark(of: history.entries[0], live: live) == .approval)
            history.flushSynchronously()
        }
    }

    @Test func aDelegatedRequest_answeredAfterTheReconnect_retiresItsRow() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let fixture = delegatedThenReconnected()
            history.record(row(for: fixture.request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: fixture.store.ledger)
            sync.reconcile()
            #expect(history.unreadCount == 1)

            // Answered at the TUI: its turn goes on and ends.
            fixture.agent(.finished, runStartedAt: nil)
            fixture.store.releaseStaleApprovals(in: fixture.session)
            sync.reconcile()

            let live = attention.liveStatus(for: history.entries[0], requests: fixture.store.ledger)
            #expect(live == .resolved)
            #expect(history.unreadCount == 0)
            #expect(mark(of: history.entries[0], live: live) == .idle)
            history.flushSynchronously()
        }
    }

    @Test func aDelegatedRequest_kept_whileTheServiceStaysDown_leavesWithItsTurn() {
        let fixture = ApprovalEpisodeEndTests.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        fixture.store.releaseStaleApprovals(in: fixture.session)
        fixture.store.stop()
        #expect(fixture.isKeptAfterAPass())

        fixture.agent(.finished, runStartedAt: nil)

        #expect(!fixture.isKeptAfterAPass())
    }

    // MARK: - A service that comes back in a new epoch

    @Test func aDelegatedRequest_staysUnresolved_whenTheServiceComesBackInANewEpoch() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let fixture = ApprovalEpisodeEndTests.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
            let store = fixture.store
            history.record(row(for: fixture.request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.releaseStaleApprovals(in: fixture.session)

            store.receive([], epoch: UUID())
            store.releaseStaleApprovals(in: fixture.session)
            sync.reconcile()

            let live = attention.liveStatus(for: history.entries[0], requests: store.ledger)
            #expect(live == .stillWaiting, "the TUI still waits for it")
            #expect(history.unreadCount == 1)
            #expect(mark(of: history.entries[0], live: live) == .approval)

            // Answered at the TUI: its turn goes on and ends.
            fixture.agent(.finished, runStartedAt: nil)
            store.releaseStaleApprovals(in: fixture.session)
            sync.reconcile()

            let ended = attention.liveStatus(for: history.entries[0], requests: store.ledger)
            #expect(ended == .resolved)
            #expect(history.unreadCount == 0)
            #expect(mark(of: history.entries[0], live: ended) == .idle)
            history.flushSynchronously()
        }
    }

    @Test func aDelegatedRequest_acrossAStopAndANewEpoch_waitsUntilItsTurnEnds() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let fixture = ApprovalEpisodeEndTests.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
            history.record(row(for: fixture.request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: fixture.store.ledger)
            fixture.store.releaseStaleApprovals(in: fixture.session)

            fixture.store.stop()
            fixture.store.receive([], epoch: UUID())
            sync.reconcile()
            #expect(attention.liveStatus(for: history.entries[0], requests: fixture.store.ledger) == .stillWaiting)
            #expect(history.unreadCount == 1)

            fixture.agent(.finished, runStartedAt: nil)
            #expect(!fixture.isKeptAfterAPass())
            sync.reconcile()
            #expect(history.unreadCount == 0)
            history.flushSynchronously()
        }
    }

    @Test func aHeldRequest_ofAServiceThatRestarted_waitsAtTheAgentsPrompt() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.receive([], epoch: UUID())
            sync.reconcile()

            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .stillWaiting)
            #expect(history.unreadCount == 1)
            #expect(store.approvalForCard(request.id) == nil, "the new broker would refuse its buttons")
            history.flushSynchronously()
        }
    }

    @Test func aHeldRequest_thatExpiredDuringAnOutage_stillWaits() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.stop()
            store.receive([], epoch: request.epoch, terminals: [request.id: .expired])
            sync.reconcile()

            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .stillWaiting)
            #expect(history.unreadCount == 1)
            history.flushSynchronously()
        }
    }

    @Test func twoRequestsOfOneRun_acrossAReadinessDrop_eachKeepsItsOwnReading() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let epoch = UUID()
            let runID = UUID()
            let delegated = ApprovalPresentation.test(epoch: epoch, runID: runID)
            let held = ApprovalPresentation.test(epoch: epoch, runID: runID)
            store.receive([delegated, held])
            history.record(row(for: delegated))
            history.record(row(for: held))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.receive([held], epoch: epoch, terminals: [delegated.id: .resolved(.delegate)])

            store.stop()
            store.receive([held], epoch: epoch)
            store.resolve(held, .allowOnce)
            await store.waitUntilResolved(held)
            sync.reconcile()

            let delegatedRow = try #require(history.entries.first { $0.requestKey == delegated.key })
            let heldRow = try #require(history.entries.first { $0.requestKey == held.key })
            #expect(attention.liveStatus(for: delegatedRow, requests: store.ledger) == .stillWaiting)
            #expect(!delegatedRow.isRead)
            #expect(attention.liveStatus(for: heldRow, requests: store.ledger) == .resolved)
            #expect(heldRow.isRead)
            history.flushSynchronously()
        }
    }

    @Test func aDroppedSubscription_stillKeepsADelegatedRowWaiting() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.receive([], epoch: request.epoch, terminals: [request.id: .resolved(.delegate)])

            store.connectionDidDrop()
            store.receive([], epoch: request.epoch)
            sync.reconcile()

            #expect(attention.liveStatus(for: history.entries[0], requests: store.ledger) == .stillWaiting)
            #expect(history.unreadCount == 1)
            history.flushSynchronously()
        }
    }

    @Test func historyList_drawsARequestRowFromTheLedger() {
        let attention = AttentionState()
        let store = acceptingStore()
        let request = ApprovalPresentation.test()
        store.receive([request])
        let entry = row(for: request, isRead: true)
        let lookup = attention.liveStatusLookup(requests: store.ledger)

        #expect(mark(of: entry, live: lookup(entry)) == .approval)
        store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])
        #expect(mark(of: entry, live: lookup(entry)) == .idle)
    }

    @Test func beforeTheServiceIsRead_aRequestRowIsNotRetired() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let ledger = ApprovalLedger()
            history.record(row(for: ApprovalPresentation.test()))

            NotificationReadSync(historyStore: history, attention: attention, requests: ledger).reconcile()

            #expect(attention.liveStatus(for: history.entries[0], requests: ledger) == nil)
            #expect(history.unreadCount == 1)
            history.flushSynchronously()
        }
    }
}
