// AgentNotificationEmitterTests.swift
// Limpid — the half of a notification this process still decides.
//
// The rules choose the moment, the wording under the title, and whether it
// interrupts. What is left here is the container label and how the entry is
// filed, which is what these cases pin.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentNotificationEmitter")
struct AgentNotificationEmitterTests {
    private func payload(
        kind: AgentNotificationKind,
        body: String?,
        tab: UUID,
        pane: UUID,
        presentsBanner: Bool = true
    ) throws -> AgentNotifyPayload {
        let json: [String: Any] = [
            "provider": "claude",
            "kind": kind.rawValue,
            "tab": tab.uuidString,
            "pane": pane.uuidString,
            "runtimeId": "claude:RUN",
            "body": body as Any,
            "presentsBanner": presentsBanner,
            "suppressWhenPaneFocused": true,
            "episodeToken": "4",
            "eventToken": "4",
            "state": "finished"
        ].compactMapValues { $0 is NSNull ? nil : $0 }
        return try JSONDecoder().decode(
            AgentNotifyPayload.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func emitter(_ history: NotificationHistoryStore) -> AgentNotificationEmitter {
        AgentNotificationEmitter(
            kind: .claude,
            notificationManager: LimpidNotificationManager(historyStore: history),
            suppressWhenPaneFocused: true,
            runtimeID: "claude:RUN",
            eventToken: "4"
        )
    }

    @Test("the body the rules chose is what the row carries")
    func deliver_usesTheBodyTheRulesChose() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WindowSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(kind: .finished, body: "ran the tests", tab: tab.id, pane: pane),
                tab: tab,
                session: session
            )

            let entry = try #require(history.entries.first)
            #expect(entry.body == "ran the tests")
            #expect(entry.kind == .agentFinished)
            #expect(entry.paneID == pane)
        }
    }

    @Test("a notification with nothing to quote falls back to naming the agent")
    func deliver_withoutABody_namesTheAgent() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WindowSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(kind: .needsInput, body: nil, tab: tab.id, pane: pane),
                tab: tab,
                session: session
            )

            // Both agents set a generic terminal title, so the localized
            // sentence naming the agent is the only thing left to say.
            let entry = try #require(history.entries.first)
            #expect(entry.body == AgentKind.claude.needsInputTitle)
            #expect(entry.kind == .agentNeedsInput)
        }
    }

    @Test("a failure is filed without interrupting")
    func deliver_failureDoesNotPresentABanner() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WindowSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(
                    kind: .failed,
                    body: "rate limited",
                    tab: tab.id,
                    pane: pane,
                    presentsBanner: false
                ),
                tab: tab,
                session: session
            )

            // The agent's own dialog is already on screen; the row is so the
            // failure is still findable once that dialog is gone.
            let entry = try #require(history.entries.first)
            #expect(entry.kind == .agentError)
            #expect(entry.body == "rate limited")
        }
    }
}
