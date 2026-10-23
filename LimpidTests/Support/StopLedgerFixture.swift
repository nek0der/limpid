// StopLedgerFixture.swift
// Limpid — the runs and the conversation the stop ledger suites share.

import Foundation
@testable import Limpid

/// One pane holding a Claude conversation, and the runs of it a stop is
/// about. A suite conforms to read them as its own (`Self.run`).
protocol StopLedgerFixture {}

private let fixturePane = UUID()

extension StopLedgerFixture {
    static var start: Date {
        Date(timeIntervalSince1970: 1000)
    }

    static var pane: UUID {
        fixturePane
    }

    static var conversation: ConversationKey {
        ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
    }

    static var sessionID: String {
        "0f4e1b52-3a8f-4d43-9b7e-6c2a1d9e8f10"
    }

    /// Every pane still exists.
    static var always: @Sendable (UUID) -> Bool {
        { _ in true }
    }

    /// A run `id` of the conversation in `state`, `seconds` after `start`,
    /// in its episode `episode`, shown in `pane`.
    static func run(
        _ id: String,
        _ state: AgentState,
        at seconds: TimeInterval = 0,
        episode: String = "1",
        pane: UUID = fixturePane,
        conversation: ConversationKey? = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false),
        sessionID: String? = "0f4e1b52-3a8f-4d43-9b7e-6c2a1d9e8f10",
        turn: String? = nil
    ) -> RuntimeFact {
        RuntimeFact.test(
            id, state, pane: pane, updatedAt: start.addingTimeInterval(seconds), episode: episode,
            detail: "overloaded", conversation: conversation, sessionID: sessionID, turn: turn
        )
    }
}
