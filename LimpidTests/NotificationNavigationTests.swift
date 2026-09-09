// NotificationNavigationTests.swift
// Limpid — notification targets survive runtime-record retirement.

import Foundation
import Testing
@testable import Limpid

@Suite("Notification navigation")
@MainActor
struct NotificationNavigationTests {
    @Test func retiredRuntime_fallsBackToPersistedPaneTarget() {
        let (session, firstTab, _, secondTab, secondPane) = WindowSessionFixture.withTwoLooseTabs()
        session.setActiveTab(firstTab.id)
        let payload = NotificationTapPayload(userInfo: [
            "runtimeID": AgentRuntimePresentation.id(kind: .codex, runID: UUID().uuidString),
            "paneID": secondPane.uuidString
        ])

        AppState.handleNotificationTap(
            payload,
            session: session,
            registry: RecordingSurfaceRegistry(),
            attention: AttentionState()
        )

        #expect(session.activeTabID == secondTab.id)
        #expect(session.activeTab?.splitTree.focusedLeafID == secondPane)
    }

    @Test func liveRuntime_outweighsOlderPersistedPaneTarget() {
        let (session, firstTab, firstPane, secondTab, secondPane) = WindowSessionFixture.withTwoLooseTabs()
        session.setActiveTab(firstTab.id)
        let runID = UUID().uuidString
        let attention = AttentionState()
        attention.replaceRuntimes([AgentRuntimePresentation(
            kind: .codex,
            runID: runID,
            revision: 1,
            badge: AgentBadge(state: .finished, updatedAt: Date()),
            paneIDs: [secondPane],
            tmuxLocations: [:],
            attachmentResolution: .attached
        )], kind: .codex)
        let payload = NotificationTapPayload(userInfo: [
            "runtimeID": AgentRuntimePresentation.id(kind: .codex, runID: runID),
            "paneID": firstPane.uuidString
        ])

        AppState.handleNotificationTap(
            payload,
            session: session,
            registry: RecordingSurfaceRegistry(),
            attention: attention
        )

        #expect(session.activeTabID == secondTab.id)
        #expect(session.activeTab?.splitTree.focusedLeafID == secondPane)
    }

    @Test func staleFirstAttachment_usesNextLiveRuntimePane() throws {
        let (session, firstTab, firstPane, secondTab, secondPane) = WindowSessionFixture.withTwoLooseTabs()
        session.setActiveTab(firstTab.id)
        let runID = UUID().uuidString
        let stalePane = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let attention = AttentionState()
        attention.replaceRuntimes([AgentRuntimePresentation(
            kind: .codex,
            runID: runID,
            revision: 1,
            badge: AgentBadge(state: .finished, updatedAt: Date()),
            paneIDs: [stalePane, secondPane],
            tmuxLocations: [:],
            attachmentResolution: .attached
        )], kind: .codex)
        let payload = NotificationTapPayload(userInfo: [
            "runtimeID": AgentRuntimePresentation.id(kind: .codex, runID: runID),
            "paneID": firstPane.uuidString
        ])

        AppState.handleNotificationTap(
            payload,
            session: session,
            registry: RecordingSurfaceRegistry(),
            attention: attention
        )

        #expect(session.activeTabID == secondTab.id)
        #expect(session.activeTab?.splitTree.focusedLeafID == secondPane)
    }
}
