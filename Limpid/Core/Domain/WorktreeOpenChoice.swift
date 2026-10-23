// WorktreeOpenChoice.swift
// Limpid — what a new worktree opens once it is made: an agent, a shell, or nothing.

import Foundation

/// What the new worktree sheet opens in the worktree it made. The
/// sheet only makes the worktree; this is the one thing it starts there,
/// with no instruction: the agent opens waiting, as the pane strip's ＋
/// opens one.
enum WorktreeOpenChoice: Hashable, Sendable {
    case agent(AgentKind)
    case shell
    /// No tab: the row is made and selected, and nothing runs in it.
    case nothing

    /// The value stored in settings.json.
    var stored: String {
        switch self {
        case let .agent(kind): kind.rawValue
        case .shell: Self.shellValue
        case .nothing: Self.nothingValue
        }
    }

    /// `stored` read back. A value a later build wrote, an agent this one
    /// does not know among them, reads as no choice, so the rule that picks
    /// the sheet's first choice falls to the next one rather than failing.
    /// `"none"`, which an earlier build stored for a terminal with no
    /// agent, reads as the shell: that build's "Terminal" is this one's
    /// shell.
    init?(stored: String?) {
        guard let stored else { return nil }
        switch stored {
        case Self.shellValue, Self.legacyTerminalValue:
            self = .shell
        case Self.nothingValue:
            self = .nothing
        default:
            guard let kind = AgentKind(rawValue: stored) else { return nil }
            self = .agent(kind)
        }
    }

    var agent: AgentKind? {
        if case let .agent(kind) = self {
            return kind
        }
        return nil
    }

    /// Whether this choice can open now: an agent only once it was found
    /// (`installed`); a shell and nothing always.
    func isAvailable(installed: [AgentKind]) -> Bool {
        agent.map(installed.contains) ?? true
    }

    /// One agent in the sheet's menu, and whether it can be chosen.
    struct MenuAgent: Hashable, Sendable {
        let kind: AgentKind
        /// Found on this Mac (`installed`). One not found is listed all the
        /// same, unchosen, so a person whose last choice it was sees why the
        /// sheet opened with another.
        let isAvailable: Bool
    }

    /// The menu's agents: every one `catalog` has, in its order, so a new
    /// agent is listed once the catalog has it, with nothing in the sheet
    /// to change. The shell and nothing follow (`others`).
    static func menuAgents(catalog: [AgentKind], installed: [AgentKind]) -> [MenuAgent] {
        catalog.map { MenuAgent(kind: $0, isAvailable: installed.contains($0)) }
    }

    /// What the menu offers after the agents, apart from them: always
    /// available.
    static let others: [WorktreeOpenChoice] = [.shell, .nothing]

    /// The choice the sheet opens with, and what ⌥⌘N opens: the first of
    /// `remembered` that reads and can open now, else the first agent
    /// found, else the shell. `remembered` lists the stored values from
    /// the most to the least specific: the project's last choice, the
    /// last one anywhere, then what an earlier build kept as the agent,
    /// for the project and anywhere, so a person used to "Create and
    /// Start" with Claude still gets Claude.
    static func initial(remembered: [String?], installed: [AgentKind]) -> WorktreeOpenChoice {
        for value in remembered {
            if let choice = WorktreeOpenChoice(stored: value), choice.isAvailable(installed: installed) {
                return choice
            }
        }
        return installed.first.map(WorktreeOpenChoice.agent) ?? .shell
    }

    private static let shellValue = "shell"
    private static let nothingValue = "nothing"
    /// What an earlier build stored for a terminal with no agent.
    static let legacyTerminalValue = "none"
}
