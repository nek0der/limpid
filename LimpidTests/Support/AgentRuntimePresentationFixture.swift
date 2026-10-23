// AgentRuntimePresentationFixture.swift
// Limpid — one builder for the agent runs the suites hand the attention list.

import Foundation
@testable import Limpid

extension AgentRuntimePresentation {
    /// A running Claude run named "run" at revision 1, attached to no pane,
    /// changed only where a test says.
    ///
    /// The initializer takes every field; a test names here only the one it
    /// is about.
    static func test(
        kind: AgentKind = .claude,
        runID: String = "run",
        revision: Int? = 1,
        badge: AgentBadge = AgentBadge(state: .running, updatedAt: Date()),
        paneIDs: Set<UUID> = [],
        tmuxLocations: [UUID: TmuxPaneLocation] = [:],
        stateEpisodeToken: String? = nil,
        attachmentResolution: AgentAttachmentResolution? = nil,
        processID: pid_t? = nil,
        sessionID: String? = nil,
        conversation: ConversationKey? = nil,
        currentTurnID: TurnID? = nil,
        projectedID: String? = nil
    ) -> AgentRuntimePresentation {
        AgentRuntimePresentation(
            kind: kind,
            runID: runID,
            revision: revision,
            badge: badge,
            paneIDs: paneIDs,
            tmuxLocations: tmuxLocations,
            stateEpisodeToken: stateEpisodeToken,
            attachmentResolution: attachmentResolution,
            processID: processID,
            sessionID: sessionID,
            conversation: conversation,
            currentTurnID: currentTurnID,
            projectedID: projectedID
        )
    }
}
