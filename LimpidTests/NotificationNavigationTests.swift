// NotificationNavigationTests.swift
// Limpid — where opening a notification or its history row leads: the request's card, or the agent's pane.

import Foundation
import Testing
@testable import Limpid

@Suite("Notification navigation")
struct NotificationNavigationTests {
    private static let key = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
    private static let pane = UUID()
    private static let tab = UUID()

    /// Facts where everything named is still there, and the request can be
    /// answered on its card unless `opensCard` says otherwise.
    private static func facts(
        opensCard: Bool = true,
        runtimeShown: Bool = true,
        paneAlive: Bool = true,
        tabAlive: Bool = true
    ) -> NotificationRoute.Facts {
        NotificationRoute.Facts(
            opensCard: { _ in opensCard },
            isRuntimeShown: { _ in runtimeShown },
            isPaneAlive: { _ in paneAlive },
            isTabAlive: { _ in tabAlive },
            isContainerAlive: { _ in true }
        )
    }

    private static let full = NotificationTarget(
        requestKey: key,
        runtimeID: "claude:run",
        paneID: pane,
        tabID: tab,
        containerID: .loose
    )

    @Test func anOpenRequest_opensItsCard() {
        #expect(NotificationRoute.first(for: Self.full, facts: Self.facts()) == .card(Self.key))
    }

    @Test func oldApprovalRow_opensPaneNotCard() {
        // Handed to the TUI, timed out, settled, or a Codex question: the
        // card cannot answer it, so the agent's pane opens instead.
        let route = NotificationRoute.first(for: Self.full, facts: Self.facts(opensCard: false))
        #expect(route == .runtime("claude:run"))
    }

    @Test func aRetiredRuntime_fallsBackToThePane_thenTheTab_thenTheContainer() {
        let noRuntime = Self.facts(opensCard: false, runtimeShown: false)
        #expect(NotificationRoute.first(for: Self.full, facts: noRuntime) == .pane(Self.pane))

        let noPane = Self.facts(opensCard: false, runtimeShown: false, paneAlive: false)
        #expect(NotificationRoute.first(for: Self.full, facts: noPane) == .tab(Self.tab))

        let noTab = Self.facts(opensCard: false, runtimeShown: false, paneAlive: false, tabAlive: false)
        #expect(NotificationRoute.first(for: Self.full, facts: noTab) == .container(.loose))
    }

    @Test func aTargetWithNothingLeft_goesNowhere() {
        let gone = NotificationRoute.Facts(
            opensCard: { _ in false },
            isRuntimeShown: { _ in false },
            isPaneAlive: { _ in false },
            isTabAlive: { _ in false },
            isContainerAlive: { _ in false }
        )
        #expect(NotificationRoute.first(for: Self.full, facts: gone) == nil)
    }

    @Test func aBannersRequestKey_reachesTheTap() throws {
        let data = try JSONEncoder().encode(Self.key)
        let json = try #require(String(data: data, encoding: .utf8))
        let payload = NotificationTapPayload(userInfo: [
            "runtimeID": "claude:run",
            "paneID": Self.pane.uuidString,
            "requestKeyJSON": json
        ])
        let target = NotificationTarget(payload)
        #expect(target.requestKey == Self.key)
        #expect(target.runtimeID == "claude:run")
        #expect(target.paneID == Self.pane)
    }

    @Test func aHistoryRow_pointsAtItsRequestRuntimeAndPane() {
        let entry = NotificationEntry.test(
            kind: .agentNeedsInput,
            paneID: Self.pane,
            title: "t",
            body: "b",
            runtimeID: "claude:run",
            requestKey: Self.key
        )
        #expect(NotificationTarget(entry) == NotificationTarget(requestKey: Self.key, runtimeID: "claude:run", paneID: Self.pane))
    }
}
