// AgentForeground.swift
// Limpid — what job is in front of a terminal (an agent, a shell, or something else), from the names of its foreground process group.

import Foundation

/// The job in front of a terminal, read from the names of its foreground
/// process group, leader first (`SurfaceView.foregroundGroupProcessNames`).
/// An agent run through a launcher (npm's `node …/bin/codex`) has the
/// launcher in front and the agent in its group. A tmux client in front
/// counts as the agent: what it shows is not visible from here.
enum AgentForeground {
    enum Job: Equatable, Sendable {
        case agent
        /// A shell at its prompt, where a typed command runs as a command.
        case shell
        /// An editor, a pager, a REPL, ssh: where typed text would be keys
        /// to that program. Also a terminal whose job cannot be read.
        case other
    }

    /// The shells a pane may run; a login shell's leader is named after the
    /// path it was started from (`/bin/zsh`), whatever `argv[0]` says.
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish"]

    /// The flags an interactive shell is started with, Ghostty's shell
    /// integration's among them (bash runs as `bash --posix`); any other
    /// argument (a script's path, `-c`) is a shell running something.
    static let interactiveShellFlags: Set<String> = ["-l", "-i", "-il", "-li", "--login", "--interactive", "--posix"]

    /// What Ghostty's shell integration has nu run as it starts, which
    /// leaves it at its prompt (`vendor/ghostty/src/termio/shell_integration.zig`).
    static let integrationArguments: [[String]] = [["--execute", "use ghostty *"]]

    /// The arguments with Ghostty's own integration taken out.
    private static func withoutIntegration(_ arguments: [String]) -> [String] {
        for added in integrationArguments {
            if let start = (0...max(0, arguments.count - added.count)).first(where: {
                arguments.count >= added.count && Array(arguments[$0..<$0 + added.count]) == added
            }) {
                return Array(arguments[..<start] + arguments[(start + added.count)...])
            }
        }
        return arguments
    }

    /// Whether a shell alone is in front, started as an interactive one: at
    /// its prompt, by the same reading as `job`'s, for any agent.
    static func isShellAtPrompt(
        names: [String],
        leaderArguments: [String]?,
        userShell: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> Bool {
        guard let leader = names.first, names.count == 1, !leader.isEmpty, let leaderArguments,
              withoutIntegration(leaderArguments).allSatisfy(interactiveShellFlags.contains)
        else { return false }
        let userShellName = userShell.map { ($0 as NSString).lastPathComponent }
        return shellNames.contains(leader) || leader == userShellName
    }

    /// `leaderArguments` are the leader's arguments after its own name.
    /// A shell counts only alone in front and started as an interactive
    /// one: a script (`./install.sh`) is a shell too, and its `read`, a
    /// builtin with no process of its own, would take the typed text as
    /// its answer. A `read` inside a function of the person's own shell
    /// still passes; telling it apart needs the prompt's own marks.
    static func job(
        of names: [String],
        leaderArguments: [String]?,
        agent: AgentKind,
        userShell: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> Job {
        guard !names.isEmpty else { return .other }
        if isAgent(agent, inFront: names) {
            return .agent
        }
        return isShellAtPrompt(names: names, leaderArguments: leaderArguments, userShell: userShell) ? .shell : .other
    }

    /// Whether `agent`, or a tmux client, is in front: what must not be
    /// typed into. The tmux client counts whoever's server it is, as what
    /// runs inside it cannot be seen from here.
    static func isAgent(_ agent: AgentKind, inFront names: [String]) -> Bool {
        guard let leader = names.first else { return false }
        let agentNames = AgentProviderRegistry.processNames(for: agent)
        return leader == TmuxClientProbe.clientProcessName || names.contains(where: agentNames.contains)
    }

    /// Whether `agent` itself runs in front: the proof a resume's deadline
    /// reads (`StopLedger.launchResumeTimedOut`), where `isAgent`'s reading
    /// of a tmux client would turn a failed resume into one that took. With
    /// a tmux client in front, `tmuxPane` says what it shows (`TmuxPaneJob`):
    ///
    /// - Limpid's own host of the agent: the shims start the agent as the
    ///   session's one command on Limpid's server, so the session, and the
    ///   client with it, ends when the agent does.
    /// - The person's own tmux (started by their shell's rc, say): the job
    ///   in front of the pane the client shows, which is the agent, or the
    ///   shell a failed resume returned to.
    /// - Unknown, when the server could not be asked: taken for the agent.
    ///   The other way would list a stop saying the resume failed after
    ///   every relaunch of a person whose tmux does not answer, on every
    ///   conversation that came back; this way a resume that failed there
    ///   leaves no stop, and its terminal says why. A server answers in
    ///   all but a wedged or vanished one, so the stop is rarely lost.
    static func isAgentRunning(_ agent: AgentKind, inFront names: [String], tmuxPane: TmuxPaneJob) -> Bool {
        guard let leader = names.first else { return false }
        guard leader == TmuxClientProbe.clientProcessName else { return isAgentProcess(agent, in: names) }
        switch tmuxPane {
        case .agentHost, .unknown:
            return true
        case let .pane(paneNames):
            return isAgentProcess(agent, in: paneNames)
        }
    }

    /// Which agent is in front, for the badge a pane wears before its run
    /// has a record (`PaneAgentInFront`): the first, in `AgentKind`'s
    /// order, whose process is in the group. Behind a tmux client, the job
    /// its pane runs, read only where the client could be asked: Limpid's
    /// own host runs whichever agent its shim started, which is not
    /// visible from here, so it is undetermined, as is no job at all.
    static func agentInFront(names: [String], tmuxPane: TmuxPaneJob) -> AgentInFrontReading {
        guard let leader = names.first else { return .undetermined }
        guard leader == TmuxClientProbe.clientProcessName else { return agentReading(in: names) }
        switch tmuxPane {
        case .agentHost, .unknown:
            return .undetermined
        case let .pane(paneNames):
            return agentReading(in: paneNames)
        }
    }

    private static func agentReading(in names: [String]) -> AgentInFrontReading {
        AgentKind.allCases.first { isAgentProcess($0, in: names) }.map(AgentInFrontReading.agent) ?? .none
    }

    /// Whether `names`, a foreground group, holds `agent`'s process.
    private static func isAgentProcess(_ agent: AgentKind, in names: [String]) -> Bool {
        let agentNames = AgentProviderRegistry.processNames(for: agent)
        return names.contains(where: agentNames.contains)
    }
}
