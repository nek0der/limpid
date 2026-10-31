// Tab+PaneTransfer.swift
// Weir — the per-pane state a pane carries when it moves to another tab.

import Foundation

extension Tab {
    /// This is the state a tab holds for one pane that goes with the pane
    /// when it moves to another tab (`TabActions.movePaneToNewTab`,
    /// `TabActions.mergePaneIntoTab`). We keep the set in one place so a
    /// per-pane field added to `Tab` is carried and cleared by both moves,
    /// not by whichever one remembers it.
    ///
    /// The split tree, zoom, and conversation name stay with the callers:
    /// each move orders them against its own `session.update` calls.
    /// `paneSearchStates` and `paneTransients` live on `WorkspaceSession`,
    /// keyed by pane id, so they follow the pane without a copy.
    struct PaneTransferState: Equatable {
        var paneState: PaneState?
        var agentSessions: [AgentKind: AgentSessionInfo] = [:]
        var agentBadges: [AgentKind: AgentBadge] = [:]
        var agentInFront: PaneAgentInFront?
        var scrollbackPath: String?
        var initialCommand: String?
        var initialPromptFile: String?
        var initialAgentExecutable: AgentInstallation?
        var tmuxBinding: TmuxBinding?
    }

    /// Returns the state this tab holds for `paneID`, read without changing
    /// the tab, so a caller can capture it before any update and clear it later.
    func paneTransferState(of paneID: UUID) -> PaneTransferState {
        PaneTransferState(
            paneState: paneStates[paneID],
            agentSessions: agentSessions.compactMapValues { $0[paneID] },
            agentBadges: agentBadges.compactMapValues { $0[paneID] },
            agentInFront: agentsInFront[paneID],
            scrollbackPath: scrollbackPaths[paneID],
            initialCommand: initialCommands[paneID],
            initialPromptFile: initialPromptFiles[paneID],
            initialAgentExecutable: initialAgentExecutables[paneID],
            tmuxBinding: tmuxBindings[paneID]
        )
    }

    /// Records `state` for `paneID` in this tab. A value the pane did not
    /// have leaves this tab's entry as it was, so a field never holds an
    /// empty placeholder; the agent in front is the exception and is set
    /// either way, because it says what the pane shows now.
    mutating func apply(_ state: PaneTransferState, to paneID: UUID) {
        if let value = state.paneState {
            paneStates[paneID] = value
        }
        for (provider, hint) in state.agentSessions {
            agentSessions[provider, default: [:]][paneID] = hint
        }
        for (provider, badge) in state.agentBadges {
            agentBadges[provider, default: [:]][paneID] = badge
        }
        agentsInFront[paneID] = state.agentInFront
        if let value = state.scrollbackPath {
            scrollbackPaths[paneID] = value
        }
        if let value = state.initialCommand {
            initialCommands[paneID] = value
        }
        if let value = state.initialPromptFile {
            initialPromptFiles[paneID] = value
        }
        if let value = state.initialAgentExecutable {
            initialAgentExecutables[paneID] = value
        }
        if let value = state.tmuxBinding {
            tmuxBindings[paneID] = value
        }
    }

    /// Clears everything `paneTransferState(of:)` reads for `paneID`, once
    /// the pane has left this tab.
    mutating func removePaneTransferState(of paneID: UUID) {
        paneStates.removeValue(forKey: paneID)
        for provider in AgentKind.allCases {
            agentSessions[provider]?.removeValue(forKey: paneID)
            agentBadges[provider]?.removeValue(forKey: paneID)
        }
        agentsInFront.removeValue(forKey: paneID)
        scrollbackPaths.removeValue(forKey: paneID)
        initialCommands.removeValue(forKey: paneID)
        initialPromptFiles.removeValue(forKey: paneID)
        initialAgentExecutables.removeValue(forKey: paneID)
        tmuxBindings.removeValue(forKey: paneID)
    }
}
