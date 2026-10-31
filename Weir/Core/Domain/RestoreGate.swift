// RestoreGate.swift
// Weir — whether a turn's start can be restored now, as every entry asks before it offers the restore.

import Foundation

/// Whether the code can be restored to the start of a turn now. Every
/// entry (the changes panel, the viewed line, the decision bar's ⋯, the
/// palette) asks the same question, and again when "Restore Code" is
/// pressed. Rust asks once more under the worktree lock, reading the run
/// records rather than what the app last saw.
///
/// The worktree is shared by every agent in it, so any agent of the
/// worktree at work or waiting for the person keeps the restore back, not
/// only the turn's own.
package enum RestoreGate {
    /// "Restore Code to Before This Turn…", the entry every surface shows;
    /// here so the palette, which is not Presentation, names it too.
    package static let entryTitle = LocalizedStringResource(
        "Restore Code to Before This Turn…",
        comment: "Changes panel, decision bar, and palette: opens the confirmation to restore the code to the start of the turn"
    )

    /// An agent whose working tree is the turn's.
    package struct Agent: Equatable, Sendable {
        package let provider: AgentKind
        package let state: AgentState
        /// Whether this is the agent whose turn is restored.
        package let isTurnsOwn: Bool

        package init(
            provider: AgentKind,
            state: AgentState,
            isTurnsOwn: Bool
        ) {
            self.provider = provider
            self.state = state
            self.isTurnsOwn = isTurnsOwn
        }
    }

    package struct Input: Equatable, Sendable {
        package let turn: TurnSummary
        package let agents: [Agent]
        /// Whether an approval or a question of the worktree's agents waits
        /// for the person.
        package let isWaiting: Bool
        /// Whether a restore or an undo of the worktree is already under way.
        package let isRestoring: Bool

        package init(
            turn: TurnSummary,
            agents: [Agent],
            isWaiting: Bool,
            isRestoring: Bool
        ) {
            self.turn = turn
            self.agents = agents
            self.isWaiting = isWaiting
            self.isRestoring = isRestoring
        }
    }

    /// What the app knows now that the gate weighs (`input`).
    package struct Facts {
        package var runtimes: [Runtime]
        /// The panes of the tabs the worktree's folder holds.
        package var worktreeTabPanes: Set<UUID> = []
        /// The panes where an approval, a question, or a prompt waits.
        package var waitingPanes: Set<UUID> = []
        /// Whether a restore or an undo of the worktree is under way.
        package var isRestoring = false

        package init(
            runtimes: [Runtime],
            worktreeTabPanes: Set<UUID> = [],
            waitingPanes: Set<UUID> = [],
            isRestoring: Bool = false
        ) {
            self.runtimes = runtimes
            self.worktreeTabPanes = worktreeTabPanes
            self.waitingPanes = waitingPanes
            self.isRestoring = isRestoring
        }
    }

    /// A running agent as the gate reads it.
    package struct Runtime: Equatable, Sendable {
        package let provider: AgentKind
        package let state: AgentState
        package let conversation: ConversationKey?
        package let paneIDs: Set<UUID>
        /// Where its latest prompt was given (the run record's
        /// `worktreeRoot`) and where its turn was recorded (`turnRoot`), as
        /// far as it recorded them. Rust holds the restore back when either
        /// is the worktree, and so does the gate.
        package let roots: [String]

        package init(
            provider: AgentKind,
            state: AgentState,
            conversation: ConversationKey?,
            paneIDs: Set<UUID>,
            roots: [String]
        ) {
            self.provider = provider
            self.state = state
            self.conversation = conversation
            self.paneIDs = paneIDs
            self.roots = roots
        }
    }

    /// What the gate weighs for `turn`, as Rust weighs it under the lock:
    /// an agent is the worktree's when its root is
    /// (`isTurnsWorktree`); one that has recorded no root yet, when it runs
    /// in `worktreeTabPanes`, the panes of the tabs the worktree's folder
    /// holds. A wait (an approval, a question, a prompt) in a pane of the
    /// worktree's agents, or of those tabs where no agent recorded another
    /// root, holds the restore back too.
    package static func input(
        for turn: TurnSummary,
        facts: Facts,
        isTurnsWorktree: (String) -> Bool
    ) -> Input {
        var here: [Runtime] = []
        var elsewhere: Set<UUID> = []
        for runtime in facts.runtimes {
            if !runtime.roots.isEmpty {
                if runtime.roots.contains(where: isTurnsWorktree) {
                    here.append(runtime)
                } else {
                    elsewhere.formUnion(runtime.paneIDs)
                }
            } else if !runtime.paneIDs.isDisjoint(with: facts.worktreeTabPanes) {
                here.append(runtime)
            }
        }
        let panes = facts.worktreeTabPanes.subtracting(elsewhere).union(here.flatMap(\.paneIDs))
        return Input(
            turn: turn,
            agents: here.map {
                // The turn's own conversation, whichever run resumed it.
                Agent(provider: $0.provider, state: $0.state, isTurnsOwn: $0.conversation == turn.conversation)
            },
            isWaiting: !facts.waitingPanes.isDisjoint(with: panes),
            isRestoring: facts.isRestoring
        )
    }

    package enum Blocker: Equatable, Sendable {
        /// The turn's start was not captured: there is nothing to go back to.
        case notRecorded
        /// The turn is still running.
        case turnRunning
        /// An agent of the worktree is at work. `other` names a provider
        /// when only agents other than the turn's own are, so the reason
        /// says whose ("Codex is running in the same worktree").
        case agentRunning(other: AgentKind?)
        /// An agent of the worktree waits for an approval or an answer.
        case agentWaiting
        case restoring
    }

    /// Why the restore cannot run now, or `nil` when it can. The first
    /// that applies, in the order a person can do something about it.
    package static func blocker(_ input: Input) -> Blocker? {
        guard input.turn.beginTree != nil else { return .notRecorded }
        if input.isRestoring {
            return .restoring
        }
        if input.turn.phase == .started {
            return .turnRunning
        }
        if input.isWaiting || input.agents.contains(where: { $0.state == .needsInput }) {
            return .agentWaiting
        }
        let working = input.agents.filter { $0.state == .running || $0.state == .compacting }
        guard !working.isEmpty else { return nil }
        if working.contains(where: \.isTurnsOwn) {
            return .agentRunning(other: nil)
        }
        let providers = Set(working.map(\.provider))
        return .agentRunning(other: providers.count == 1 ? providers.first : nil)
    }
}
