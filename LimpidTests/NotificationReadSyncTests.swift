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
}
