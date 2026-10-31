// PaneAgentInFront.swift
// Weir — the agent a pane's terminal runs in front before its run has a record, and when that changes.

import Foundation

/// The agent a pane runs, as its terminal's foreground job says, for the
/// badge its tab, row, and header wear and the bar under it before the
/// agent's run has a record.
/// Codex writes its record at its first prompt, not as it starts, so
/// without this a Codex typed into a shell would wear the shell's glyph
/// until then. Only that it is there: what the agent is doing is the record's
/// to say, and a record, once there, wins (`Tab.agentKind(inPane:)`).
package struct PaneAgentInFront: Equatable, Sendable {
    package let kind: AgentKind
    /// Staged by the pane strip's "+" (or a new session) as the tab opened,
    /// and not seen in front yet: the command is typed once the terminal
    /// starts, so a shell in front until then is the agent still to come,
    /// not one that left.
    package let isStaged: Bool

    package init(
        kind: AgentKind,
        isStaged: Bool
    ) {
        self.kind = kind
        self.isStaged = isStaged
    }
}

/// What one reading of a pane's job in front says about its agent.
package enum AgentInFrontReading: Equatable, Sendable {
    case agent(AgentKind)
    /// No agent in front: a shell, or another program.
    case none
    /// The job cannot be told: no terminal yet, or a tmux client whose
    /// pane could not be asked, or Weir's own agent host, which runs
    /// whichever agent its shim started.
    case undetermined
}

package enum PaneAgentInFrontRules {
    /// When a pane's job in front is read: the events that mark a command
    /// starting or ending, which is when it can change.
    package enum Boundary: Equatable, Sendable {
        /// The terminal's title changed: the shell's preexec names the
        /// command it starts, its precmd the directory it is back at, and
        /// an agent may name its conversation.
        case titleChanged
        /// The shell's command finished (OSC 133 D): its prompt is back.
        case commandFinished
    }

    /// What a pane's agent in front becomes after `reading` at `boundary`.
    /// A staged agent outlives a reading of no agent at a title: the shell
    /// names its directory as it first starts, before the staged command
    /// runs. Only the command's end lets it go, which is also how one that
    /// never started (not installed, say) goes back to the shell.
    package static func next(
        _ current: PaneAgentInFront?,
        after reading: AgentInFrontReading,
        at boundary: Boundary
    ) -> PaneAgentInFront? {
        switch reading {
        case let .agent(kind):
            return PaneAgentInFront(kind: kind, isStaged: false)
        case .undetermined:
            return current
        case .none:
            if boundary == .titleChanged, current?.isStaged == true {
                return current
            }
            return nil
        }
    }
}
