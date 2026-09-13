// NotificationReadSyncTests.swift
// Limpid — the join between agent notification rows and the live
// runtime behind them: which rows still read as "waiting", and which
// get retired automatically once the Waiting side has handled them.

import Foundation
import Testing
@testable import Limpid

@Suite("NotificationReadSync")
@MainActor
struct NotificationReadSyncTests {

    // MARK: - Helpers

    private func runtime(
        _ state: AgentState,
        runID: String,
        paneID: UUID = UUID(),
        revision: Int = 1,
        stateEpisodeToken: String? = nil
    ) -> AgentRuntimePresentation {
        var runtime = AgentRuntimePresentation(
            kind: .codex,
            runID: runID,
            revision: revision,
            badge: AgentBadge(
                state: state, detail: nil, runStartedAt: nil,
                contextTokens: nil, updatedAt: Date(), lastPrompt: nil
            ),
            paneIDs: [paneID],
            tmuxLocations: [:]
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
        NotificationEntry(
            kind: kind,
            paneID: nil,
            tabTitleSnapshot: nil,
            title: "t",
            body: "b",
            isRead: isRead,
            runtimeID: runtimeID,
            eventToken: eventToken
        )
    }

    // MARK: - liveStatus

    @Test func liveStatus_needsInputRow_tracksTheRuntime() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        let row = entry(.agentNeedsInput, runtimeID: id)

        attention.replaceRuntimes([runtime(.needsInput, runID: runID)], kind: .codex)
        #expect(attention.liveStatus(for: row) == .stillWaiting)

        attention.replaceRuntimes([runtime(.running, runID: runID)], kind: .codex)
        #expect(attention.liveStatus(for: row) == .resolved)

        // The state file was cleaned up: nothing can be waiting behind it.
        attention.replaceRuntimes([], kind: .codex)
        #expect(attention.liveStatus(for: row) == .resolved)
    }

    @Test func liveStatus_errorRow_isStillWaitingWhileErrored() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        attention.replaceRuntimes([runtime(.error, runID: runID)], kind: .codex)
        #expect(attention.liveStatus(for: entry(.agentError, runtimeID: id)) == .stillWaiting)
    }

    @Test func liveStatus_doesNotReviveAnEarlierWaitingEvent() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        let earlier = entry(.agentNeedsInput, runtimeID: id, eventToken: "1")

        attention.replaceRuntimes([runtime(.needsInput, runID: runID, revision: 2)], kind: .codex)

        #expect(attention.liveStatus(for: earlier) == .resolved)
    }

    @Test func liveStatus_sameWaitingEpisodeSurvivesRevisionUpdates() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        let row = entry(.agentNeedsInput, runtimeID: id, eventToken: "1")

        attention.replaceRuntimes([
            runtime(.needsInput, runID: runID, revision: 2, stateEpisodeToken: "1")
        ], kind: .codex)

        #expect(attention.liveStatus(for: row) == .stillWaiting)
    }

    @Test func liveStatus_isNilForFinishedCommandAndLegacyRows() {
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        attention.replaceRuntimes([runtime(.finished, runID: runID)], kind: .codex)
        // A finished turn is a fact, not a wait.
        #expect(attention.liveStatus(for: entry(.agentFinished, runtimeID: id)) == nil)
        #expect(attention.liveStatus(for: entry(.commandFinished, runtimeID: nil)) == nil)
        // Rows recorded before `runtimeID` existed carry no runtime.
        #expect(attention.liveStatus(for: entry(.agentNeedsInput, runtimeID: nil)) == nil)
        // A pre-event-token row cannot be safely joined to a later state
        // from the same invocation, so it stays in history for manual read.
        #expect(attention.liveStatus(for: entry(.agentNeedsInput, runtimeID: id, eventToken: nil)) == nil)
    }

    // MARK: - reconcile

    @Test func observer_retiresNeedsInputRowOnceTheRuntimeMovesOn() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationReadSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = NotificationHistoryStore(directory: dir)
        let attention = AttentionState()
        let runID = UUID().uuidString
        let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
        store.record(entry(.agentNeedsInput, runtimeID: id))
        attention.replaceRuntimes([runtime(.needsInput, runID: runID)], kind: .codex)

        let sync = NotificationReadSync(historyStore: store, attention: attention)
        #expect(store.unreadCount == 1)

        attention.replaceRuntimes([runtime(.running, runID: runID)], kind: .codex)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while store.unreadCount != 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.unreadCount == 0)
        store.flushSynchronously()
        _ = sync
    }

    @Test func reconcile_retiresEarlierNeedsInputBeforeTheNextWaitingEvent() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentNeedsInput, runtimeID: id, eventToken: "1"))
            attention.replaceRuntimes([runtime(.needsInput, runID: runID, revision: 1)], kind: .codex)
            let sync = NotificationReadSync(historyStore: store, attention: attention)

            attention.replaceRuntimes([runtime(.running, runID: runID, revision: 2)], kind: .codex)
            sync.reconcile()
            attention.replaceRuntimes([runtime(.needsInput, runID: runID, revision: 3)], kind: .codex)
            sync.reconcile()

            #expect(store.unreadCount == 0)
            #expect(attention.liveStatus(for: store.entries[0]) == .resolved)
        }
    }

    @Test func reconcile_retiresFinishedRowOnceViewedInWaiting() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let paneID = UUID()
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentFinished, runtimeID: id))
            attention.replaceRuntimes([runtime(.finished, runID: runID, paneID: paneID)], kind: .codex)

            let sync = NotificationReadSync(historyStore: store, attention: attention)
            // Finished but not yet looked at: the row still counts.
            #expect(store.unreadCount == 1)

            attention.markVisibleRuntimesViewed(paneID: paneID)
            sync.reconcile()
            #expect(store.unreadCount == 0)
        }
    }

    @Test func reconcile_retiresFinishedRowOnceDismissed() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let runID = UUID().uuidString
            let id = AgentRuntimePresentation.id(kind: .codex, runID: runID)
            store.record(entry(.agentFinished, runtimeID: id))
            attention.replaceRuntimes([runtime(.finished, runID: runID)], kind: .codex)

            let sync = NotificationReadSync(historyStore: store, attention: attention)
            attention.dismissRuntime(id)
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

            attention.dismissRuntime(id)
            NotificationReadSync(historyStore: store, attention: attention).reconcile()

            #expect(store.unreadCount == 1)
        }
    }

    @Test func reconcile_leavesCommandAndLegacyRowsAlone() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            store.record(entry(.commandFinished, runtimeID: nil))
            store.record(entry(.agentNeedsInput, runtimeID: nil))

            let sync = NotificationReadSync(historyStore: store, attention: attention)
            sync.reconcile()
            // Neither row has a runtime episode to consult, so only an
            // explicit history action can clear them.
            #expect(store.unreadCount == 2)
        }
    }

    // MARK: - Explicit history acknowledgement

    @Test func markAllRead_acknowledgesMatchingFinishedRuntimeOnly() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
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
            #expect(attention.liveStatus(for: entry(.agentNeedsInput, runtimeID: waitingID)) == .stillWaiting)
            #expect(changeCount == 1)
        }
    }

    @Test func markAllRead_doesNotAcknowledgeNewerFinishedEpisode() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let session = WindowSession()
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

            NotificationReadSync(historyStore: reloadedStore, attention: attention).reconcile()

            #expect(reloadedStore.entries.first?.isRead == true)
            #expect(attention.isViewed(current))
        }
    }

    @Test func observer_restoresViewedFinishedWhenRuntimeArrivesLater() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationReadSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

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

        let sync = NotificationReadSync(historyStore: store, attention: attention)
        attention.replaceRuntimes([current], kind: .codex)

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !attention.isViewed(current), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(attention.isViewed(current))
        _ = sync
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

            NotificationReadSync(historyStore: store, attention: attention).reconcile()

            #expect(!attention.isViewed(current))
        }
    }
}
