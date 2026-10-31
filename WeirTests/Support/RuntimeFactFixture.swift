// RuntimeFactFixture.swift
// Weir — one builder for the runtime facts the attention suites hand a reducer or a ledger.

import Foundation
@testable import Weir
@testable import WeirDomain

extension RuntimeFact {
    /// A Claude run `name` that stopped on an error in every pane of `tab`.
    static func stopped(_ name: String, in tab: Tab, of project: Project) -> RuntimeFact {
        RuntimeFact(
            runtimeID: name, provider: .claude, paneIDs: tab.splitTree.allLeafIDs(), tabID: tab.id, projectID: project.id,
            state: .error, updatedAt: Date(), episodeToken: "1", isEpisodeRead: false, detail: nil
        )
    }

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
