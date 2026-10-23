// RuntimeFactFixture.swift
// Limpid — one builder for the runtime facts the attention suites hand a reducer or a ledger.

import Foundation
@testable import Limpid

extension RuntimeFact {
    /// A Claude run `id` in `state`, shown in `pane`, in its first episode,
    /// changed only where a test says.
    static func test(
        _ id: String,
        _ state: AgentState,
        provider: AgentKind = .claude,
        pane: UUID = UUID(),
        tabID: UUID? = nil,
        projectID: UUID? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1000),
        episode: String = "1",
        isRead: Bool = false,
        detail: String? = nil,
        conversation: ConversationKey? = nil,
        sessionID: String? = nil,
        turn: String? = nil
    ) -> RuntimeFact {
        RuntimeFact(
            runtimeID: id,
            provider: provider,
            paneIDs: [pane],
            tabID: tabID,
            projectID: projectID,
            state: state,
            updatedAt: updatedAt,
            episodeToken: episode,
            isEpisodeRead: isRead,
            detail: detail,
            conversation: conversation,
            sessionID: sessionID,
            currentTurnID: turn.map(TurnID.init)
        )
    }
}
