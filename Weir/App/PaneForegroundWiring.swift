// PaneForegroundWiring.swift
// Weir — which reading of a pane's job in front a resume's deadline, a launch, and a pane's badge are each handed.

import Foundation
import WeirDomain

/// The three readings of the job in front of a pane that the app holds the
/// terminals for (`AppState`).
@MainActor
protocol PaneForegroundReading: AnyObject {
    /// `agent`, or a tmux client that may be hosting it, is in front
    /// (`AgentForeground.isAgent`): what must not be typed into.
    func isAgentInFront(_ agent: AgentKind, inPane paneID: UUID) -> Bool
    /// `agent` itself runs in front, behind a tmux client what its pane
    /// runs (`AgentForeground.isAgentRunning`).
    func isAgentRunningInFront(_ agent: AgentKind, inPane paneID: UUID) async -> Bool
    /// Which agent runs in front, behind a tmux client what its pane runs
    /// (`AgentForeground.agentInFront`).
    func agentInFrontReading(inPane paneID: UUID) async -> AgentInFrontReading
}

/// Which reading each store gets, named in one place so a test can pin it:
/// the first two answer the same for every pane but one behind the
/// person's own tmux, which is exactly where handing over the wrong one
/// goes unnoticed.
@MainActor
enum PaneForegroundWiring {
    /// What a resume's deadline reads (`StopLedgerStore.isAgentInFront`):
    /// the agent itself, never a tmux client, which may show the
    /// shell a failed resume returned to and would make that failure read
    /// as a resume that took.
    static func resumeDeadline(_ reader: some PaneForegroundReading) -> @MainActor (UUID, AgentKind) async -> Bool {
        { [weak reader] paneID, agent in
            await reader?.isAgentRunningInFront(agent, inPane: paneID) ?? false
        }
    }

    /// What a launch follows its agent by (`SessionLaunchStore
    /// .isAgentInFront`): the agent or the tmux client hosting it, read at
    /// once, as a launch never types into either.
    static func launchFollow(_ reader: some PaneForegroundReading) -> @MainActor (UUID, AgentKind) -> Bool {
        { [weak reader] paneID, agent in
            reader?.isAgentInFront(agent, inPane: paneID) ?? false
        }
    }

    /// What a pane's badge before its record follows
    /// (`PaneAgentInFrontFollower.read`): which agent runs in front,
    /// not merely whether one does.
    static func agentInFront(_ reader: some PaneForegroundReading) -> @MainActor (UUID) async -> AgentInFrontReading {
        { [weak reader] paneID in
            await reader?.agentInFrontReading(inPane: paneID) ?? .undetermined
        }
    }
}

extension AppState: PaneForegroundReading {}
