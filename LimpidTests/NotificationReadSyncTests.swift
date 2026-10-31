// NotificationReadSyncTests.swift
// Limpid — the join between agent notification rows and the live
// runtime behind them: which rows still read as "waiting", and which
// get retired automatically once their runs read as handled.

import Foundation
import Testing
@testable import Limpid

@Suite("NotificationReadSync", .timeLimit(.minutes(1)))
@MainActor
struct NotificationReadSyncTests {
    /// A ledger holding no request: these rows are joined to their runs.
    /// Request rows have their own suite (`NotificationRequestLiveStatusTests`).
    private let requests = ApprovalLedger()

    // MARK: - Helpers

    private func runtime(
        _ state: AgentState,
        runID: String,
        paneID: UUID = UUID(),
        revision: Int = 1,
        stateEpisodeToken: String? = nil
    ) -> AgentRuntimePresentation {
        var runtime = AgentRuntimePresentation.test(
            kind: .codex,
            runID: runID,
            revision: revision,
            badge: AgentBadge(state: state, detail: nil, runStartedAt: nil, updatedAt: Date(), lastPrompt: nil),
            paneIDs: [paneID]
        )
        runtime.stateEpisodeToken = stateEpisodeToken
        return runtime
    }

    private func entry(
        _ kind: NotificationEntry.Kind,
        runtimeID: String?,
        eventToken: String? = "1",
        isRead: Bool = false
    ) -> NotificationEntry {
        NotificationEntry.test(kind: kind, title: "t", body: "b", isRead: isRead, runtimeID: runtimeID, eventToken: eventToken)
    }

    // MARK: - liveStatus

    @Test func liveStatus_needsInputRow_tracksTheRuntime() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        let row = entry(.agentNeedsInput, runtimeID: id)

        attention.replaceRuntimes([runtime(.needsInput, runID: runID)], kind: .codex)
        #expect(attention.liveStatus(for: row, requests: requests) == .stillWaiting)

        attention.replaceRuntimes([runtime(.running, runID: runID)], kind: .codex)
        #expect(attention.liveStatus(for: row, requests: requests) == .resolved)

        // The state file was cleaned up: nothing can be waiting behind it.
        attention.replaceRuntimes([], kind: .codex)
        #expect(attention.liveStatus(for: row, requests: requests) == .resolved)
    }

    /// A row recorded as event "1" against the run as it reads now.
    struct LiveCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let row: NotificationEntry.Kind
        let state: AgentState
        let revision: Int
        let stateEpisodeToken: String?
        let status: NotificationLiveStatus

        static let all = [
            LiveCase(
                testDescription: "an error row waits while the run is errored",
                row: .agentError, state: .error, revision: 1, stateEpisodeToken: nil, status: .stillWaiting
            ),
            LiveCase(
                testDescription: "a later wait does not revive an earlier one",
                row: .agentNeedsInput, state: .needsInput, revision: 2, stateEpisodeToken: nil, status: .resolved
            ),
            LiveCase(
                testDescription: "the same wait survives a revision update",
                row: .agentNeedsInput, state: .needsInput, revision: 2, stateEpisodeToken: "1", status: .stillWaiting
            )
        ]
    }

    @Test(arguments: LiveCase.all)
    func liveStatus_followsTheWaitTheRowRecorded(_ live: LiveCase) {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        let row = entry(live.row, runtimeID: id, eventToken: "1")

        attention.replaceRuntimes([
            runtime(live.state, runID: runID, revision: live.revision, stateEpisodeToken: live.stateEpisodeToken)
        ], kind: .codex)

        #expect(attention.liveStatus(for: row, requests: requests) == live.status)
    }

    @Test func liveStatus_isNilForFinishedCommandAndLegacyRows() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        attention.replaceRuntimes([runtime(.finished, runID: runID)], kind: .codex)
        // A finished turn is a fact, not a wait.
        #expect(attention.liveStatus(for: entry(.agentFinished, runtimeID: id), requests: requests) == nil)
        #expect(attention.liveStatus(for: entry(.commandFinished, runtimeID: nil), requests: requests) == nil)
        // Rows recorded before `runtimeID` existed carry no runtime.
        #expect(attention.liveStatus(for: entry(.agentNeedsInput, runtimeID: nil), requests: requests) == nil)
        // A pre-event-token row cannot be safely joined to a later state
        // from the same invocation, so it stays in history for manual read.
        #expect(attention.liveStatus(for: entry(.agentNeedsInput, runtimeID: id, eventToken: nil), requests: requests) == nil)
    }

    // MARK: - reconcile

    @Test func observer_retiresNeedsInputRowOnceTheRuntimeMovesOn() async throws {
        try await withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentNeedsInput, runtimeID: id))
            attention.replaceRuntimes([runtime(.needsInput, runID: runID)], kind: .codex)

            let sync = NotificationReadSync(historyStore: store, attention: attention, requests: requests)
            #expect(store.unreadCount == 1)

            attention.replaceRuntimes([runtime(.running, runID: runID)], kind: .codex)
            await untilObserved { store.unreadCount == 0 }
            #expect(store.unreadCount == 0)
            store.flushSynchronously()
            _ = sync
        }
    }

    @Test func reconcile_retiresEarlierNeedsInputBeforeTheNextWaitingEvent() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentNeedsInput, runtimeID: id, eventToken: "1"))
            attention.replaceRuntimes([runtime(.needsInput, runID: runID, revision: 1)], kind: .codex)
            let sync = NotificationReadSync(historyStore: store, attention: attention, requests: requests)

            attention.replaceRuntimes([runtime(.running, runID: runID, revision: 2)], kind: .codex)
            sync.reconcile()
            attention.replaceRuntimes([runtime(.needsInput, runID: runID, revision: 3)], kind: .codex)
            sync.reconcile()

            #expect(store.unreadCount == 0)
            #expect(attention.liveStatus(for: store.entries[0], requests: requests) == .resolved)
        }
    }

    @Test func reconcile_retiresFinishedRowOnceViewed() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let paneID = UUID()
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentFinished, runtimeID: id))
            attention.replaceRuntimes([runtime(.finished, runID: runID, paneID: paneID)], kind: .codex)

            let sync = NotificationReadSync(historyStore: store, attention: attention, requests: requests)
            // Finished but not yet looked at: the row still counts.
            #expect(store.unreadCount == 1)

            attention.markVisibleRuntimesViewed(paneID: paneID)
            sync.reconcile()
            #expect(store.unreadCount == 0)
        }
    }

    @Test func reconcile_doesNotReadFinishedRowFromAnotherEvent() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentFinished, runtimeID: id, eventToken: "1"))
            attention.replaceRuntimes([runtime(.finished, runID: runID, revision: 2)], kind: .codex)

            // The later episode is viewed; the row is for the earlier one.
            let current = try #require(attention.allRuntimes.first?.attentionEventToken)
            attention.markFinishedRuntimesViewed(matching: [id: [current]])
            NotificationReadSync(historyStore: store, attention: attention, requests: requests).reconcile()

            #expect(store.unreadCount == 1)
        }
    }

    @Test func reconcile_leavesCommandAndLegacyRowsAlone() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            store.record(entry(.commandFinished, runtimeID: nil))
            store.record(entry(.agentNeedsInput, runtimeID: nil))

            let sync = NotificationReadSync(historyStore: store, attention: attention, requests: requests)
            sync.reconcile()
            // Neither row has a runtime episode to consult, so only an
            // explicit history action can clear them.
            #expect(store.unreadCount == 2)
        }
    }

    // MARK: - Explicit history acknowledgment

    @Test func aRunWhoseTurnsAreRecorded_isReadInTheHistoryOnlyAsItsTurnsAre() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let runID = UUID().uuidString
            let paneID = UUID()
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            var isLineDown = false
            attention.turnReadDecision = { $0.id == id ? isLineDown : nil }
            store.record(entry(.agentFinished, runtimeID: id))
            attention.replaceRuntimes([runtime(.finished, runID: runID, paneID: paneID)], kind: .codex)
            let sync = NotificationReadSync(historyStore: store, attention: attention, requests: requests)

            // Looked at, but it changed files: still unread.
            attention.markVisibleRuntimesViewed(paneID: paneID)
            sync.reconcile()
            #expect(store.unreadCount == 1)

            // The viewed line passes it, and its row is read.
            isLineDown = true
            sync.reconcile()
            #expect(store.unreadCount == 0)
            isLineDown = false

            // Marking the whole history read marks its rows read, but does
            // not mark the turn viewed.
            NotificationReadSync.markAllRead(historyStore: store, attention: attention, session: session)
            #expect(attention.allRuntimes.allSatisfy { !attention.isViewed($0) })

            // The viewed line passes it.
            isLineDown = true
            #expect(attention.allRuntimes.allSatisfy(attention.isViewed))
        }
    }

    @Test func markAllRead_acknowledgesMatchingFinishedRuntimeOnly() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
            let finishedRunID = UUID().uuidString
            let waitingRunID = UUID().uuidString
            let finishedID = AgentRuntimePresentation.id(kind: .codex, runID: finishedRunID)
            let waitingID = AgentRuntimePresentation.id(kind: .codex, runID: waitingRunID)
            let finished = runtime(
                .finished,
                runID: finishedRunID,
                revision: 2,
                stateEpisodeToken: "finished-episode"
            )

            store.record(entry(
                .agentFinished,
                runtimeID: finishedID,
                eventToken: "finished-episode"
            ))
            store.record(entry(.agentNeedsInput, runtimeID: waitingID))
            attention.replaceRuntimes([
                finished,
                runtime(.needsInput, runID: waitingRunID)
            ], kind: .codex)
            session.markUnread(paneID: paneID)

            var changeCount = 0
            attention.onRuntimeAttentionChanged = { changeCount += 1 }
            NotificationReadSync.markAllRead(
                historyStore: store,
                attention: attention,
                session: session
            )

            #expect(store.unreadCount == 0)
            #expect(session.windowUnreadCount == 0)
            #expect(attention.isViewed(finished))
            #expect(attention.liveStatus(for: entry(.agentNeedsInput, runtimeID: waitingID), requests: requests) == .stillWaiting)
            #expect(changeCount == 1)
        }
    }

    @Test func markAllRead_doesNotAcknowledgeNewerFinishedEpisode() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let session = WorkspaceSession()
            let runID = UUID().uuidString
            let runtimeID = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            let current = runtime(.finished, runID: runID, revision: 2)

            store.record(entry(.agentFinished, runtimeID: runtimeID, eventToken: "1"))
            store.record(entry(.agentFinished, runtimeID: runtimeID, eventToken: nil))
            attention.replaceRuntimes([current], kind: .codex)

            NotificationReadSync.markAllRead(
                historyStore: store,
                attention: attention,
                session: session
            )

            #expect(store.unreadCount == 0)
            #expect(!attention.isViewed(current))
        }
    }

    @Test func reconcile_restoresViewedFinishedFromPersistedReadHistory() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let runID = UUID().uuidString
            let runtimeID = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            let current = runtime(
                .finished,
                runID: runID,
                revision: 2,
                stateEpisodeToken: "finished-episode"
            )

            store.record(entry(
                .agentFinished,
                runtimeID: runtimeID,
                eventToken: "finished-episode",
                isRead: false
            ))
            store.markAllRead()
            store.flushSynchronously()

            let reloadedStore = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            attention.replaceRuntimes([current], kind: .codex)

            NotificationReadSync(historyStore: reloadedStore, attention: attention, requests: requests).reconcile()

            #expect(reloadedStore.entries.first?.isRead == true)
            #expect(attention.isViewed(current))
        }
    }

    /// A read notification row does not by itself mean that a turn which
    /// changed files was read. Where the run's turns decide (`false`), their
    /// reads win. Where they do not (`nil`), as for a run older than its
    /// conversation's turn history, the row restores the run as viewed, as it
    /// did before turn records existed.
    @Test(arguments: [(false as Bool?, false), (nil, true)])
    func reconcile_restoresAReadFinishedRun_onlyWhereItsTurnsDoNotDecide(
        _ turnReadDecision: Bool?,
        _ isViewed: Bool
    ) throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let runID = UUID().uuidString
            let runtimeID = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            var current = runtime(.finished, runID: runID, revision: 2, stateEpisodeToken: "finished-episode")
            current.currentTurnID = TurnID("T7")
            store.record(entry(.agentFinished, runtimeID: runtimeID, eventToken: "finished-episode", isRead: true))
            let attention = AttentionState()
            attention.turnReadDecision = { _ in turnReadDecision }
            attention.replaceRuntimes([current], kind: .codex)

            NotificationReadSync(historyStore: store, attention: attention, requests: requests).reconcile()

            #expect(attention.isViewed(current) == isViewed)
            if !isViewed {
                #expect(attention.viewedRuntimeTokens[runtimeID] == nil)
            }
        }
    }

    @Test func observer_restoresViewedFinishedWhenRuntimeArrivesLater() async throws {
        try await withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let runtimeID = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            let current = runtime(
                .finished,
                runID: runID,
                revision: 2,
                stateEpisodeToken: "finished-episode"
            )
            store.record(entry(
                .agentFinished,
                runtimeID: runtimeID,
                eventToken: "finished-episode",
                isRead: true
            ))

            let sync = NotificationReadSync(historyStore: store, attention: attention, requests: requests)
            attention.replaceRuntimes([current], kind: .codex)

            await untilObserved { attention.isViewed(current) }
            #expect(attention.isViewed(current))
            _ = sync
        }
    }

    @Test func reconcile_restoresOnlyReadExactFinishedEpisode() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let runtimeID = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            let current = runtime(.finished, runID: runID, revision: 2)

            store.record(entry(.agentFinished, runtimeID: runtimeID, eventToken: "2"))
            store.record(entry(.agentFinished, runtimeID: runtimeID, eventToken: "1", isRead: true))
            store.record(entry(.agentFinished, runtimeID: runtimeID, eventToken: nil, isRead: true))
            attention.replaceRuntimes([current], kind: .codex)

            NotificationReadSync(historyStore: store, attention: attention, requests: requests).reconcile()

            #expect(!attention.isViewed(current))
        }
    }
}
