// AgentForegroundTests.swift
// Limpid — what runs in front of a pane: the agent, the shell, or something
// else, and behind a tmux client, what its pane runs.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct AgentForegroundTests {
    @Test func theJobInFront_isTheAgent_theShell_orSomethingElse() {
        #expect(AgentForeground.job(of: ["node", "codex"], leaderArguments: [], agent: .codex) == .agent)
        #expect(AgentForeground.job(of: ["tmux"], leaderArguments: [], agent: .claude) == .agent)
        #expect(AgentForeground.job(of: ["zsh"], leaderArguments: [], agent: .claude, userShell: "/bin/zsh") == .shell)
        #expect(AgentForeground.job(of: ["zsh"], leaderArguments: ["-l"], agent: .claude) == .shell)
        // What Ghostty's shell integration starts bash and nu with.
        #expect(AgentForeground.job(of: ["bash"], leaderArguments: ["--posix"], agent: .claude) == .shell)
        #expect(AgentForeground.job(of: ["nu"], leaderArguments: ["--execute", "use ghostty *"], agent: .claude) == .shell)
        #expect(AgentForeground.job(of: ["bash"], leaderArguments: ["--posix", "./x.sh"], agent: .claude) == .other)
        #expect(AgentForeground.job(of: ["myshell"], leaderArguments: [], agent: .claude, userShell: "/opt/bin/myshell") == .shell)
        #expect(AgentForeground.job(of: ["vim"], leaderArguments: [], agent: .claude) == .other)
        #expect(AgentForeground.job(of: ["bash", "python3"], leaderArguments: [], agent: .claude) == .other)
        // A script waiting at the shell's own `read` is no prompt.
        #expect(AgentForeground.job(of: ["bash"], leaderArguments: ["./install.sh"], agent: .claude) == .other)
        #expect(AgentForeground.job(of: ["sh"], leaderArguments: ["-c", "read x"], agent: .claude) == .other)
        #expect(AgentForeground.job(of: ["zsh"], leaderArguments: nil, agent: .claude) == .other)
        #expect(AgentForeground.job(of: [""], leaderArguments: [], agent: .claude, userShell: "") == .other)
        #expect(AgentForeground.job(of: [], leaderArguments: nil, agent: .claude) == .other)
    }

    /// A resume's deadline reads the agent itself in front. Behind a tmux
    /// client, what its pane runs: Limpid's own host is the agent, whose
    /// session ends with it; the person's own tmux (started by their
    /// shell's rc) is the agent when its pane has the agent in front, and
    /// the resume failed when it has the shell. A server that cannot be
    /// asked counts as the agent, so no stop says a resume failed that
    /// came back. Nothing is typed into any tmux client either way (`job`).
    @Test func theAgentRunningInFront_behindATmuxClient_isWhatItsPaneRuns() {
        #expect(AgentForeground.isAgentRunning(.codex, inFront: ["node", "codex"], tmuxPane: .unknown))
        #expect(AgentForeground.isAgentRunning(.codex, inFront: ["tmux"], tmuxPane: .agentHost))
        #expect(AgentForeground.isAgentRunning(.codex, inFront: ["tmux"], tmuxPane: .pane(["node", "codex"])))
        #expect(!AgentForeground.isAgentRunning(.codex, inFront: ["tmux"], tmuxPane: .pane(["zsh"])))
        #expect(!AgentForeground.isAgentRunning(.codex, inFront: ["tmux"], tmuxPane: .pane(["claude"])))
        #expect(AgentForeground.isAgentRunning(.codex, inFront: ["tmux"], tmuxPane: .unknown))
        #expect(AgentForeground.job(of: ["tmux"], leaderArguments: [], agent: .codex) == .agent)
        #expect(!AgentForeground.isAgentRunning(.codex, inFront: ["zsh"], tmuxPane: .agentHost))
        #expect(!AgentForeground.isAgentRunning(.codex, inFront: [], tmuxPane: .agentHost))
    }

    /// The person's tmux is asked for its client's active pane, by the
    /// client's socket and session, and the kernel for that pane's job.
    /// A server that does not answer, or a pane whose job cannot be read,
    /// is unknown.
    @Test func thePersonsTmux_isAskedForItsClientsActivePane() {
        let binding = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work")
        var asked: [TmuxBinding] = []
        let job = TmuxPaneJob.read(
            binding,
            activePaneTTY: { binding in
                asked.append(binding)
                return "/dev/ttys042"
            },
            foregroundNames: { $0 == "/dev/ttys042" ? ["node", "codex"] : [] }
        )
        #expect(job == .pane(["node", "codex"]))
        #expect(asked == [binding])
        #expect(TmuxPaneJob.read(binding, activePaneTTY: { _ in nil }, foregroundNames: { _ in ["codex"] }) == .unknown)
        #expect(TmuxPaneJob.read(binding, activePaneTTY: { _ in "/dev/ttys042" }, foregroundNames: { _ in [] }) == .unknown)
    }

    /// Which tmux pane a pane's job in front stands for, in order: no tmux
    /// client in front asks nothing; a client of Limpid's own agent server
    /// is the agent's host, its server not asked; the person's own tmux is
    /// asked about its client's active pane; a client not yet matched to
    /// the pane cannot be asked.
    @Test func theTmuxPaneInFront_isAskedOnlyOfThePersonsMatchedClient() async {
        let binding = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work")
        var asked: [TmuxBinding] = []
        let read = { (binding: TmuxBinding) -> TmuxPaneJob in
            asked.append(binding)
            return .pane(["zsh"])
        }

        let notTmux = await TmuxPaneJob.inFront(of: ["zsh"], isAgentHost: { true }, client: { binding }, read: read)
        #expect(notTmux == .unknown)
        let host = await TmuxPaneJob.inFront(of: ["tmux"], isAgentHost: { true }, client: { binding }, read: read)
        #expect(host == .agentHost)
        #expect(asked.isEmpty, "neither a pane without tmux nor Limpid's own host is asked")

        let persons = await TmuxPaneJob.inFront(of: ["tmux"], isAgentHost: { false }, client: { binding }, read: read)
        #expect(persons == .pane(["zsh"]))
        #expect(asked == [binding])

        let unmatched = await TmuxPaneJob.inFront(of: ["tmux"], isAgentHost: { false }, client: { nil }, read: read)
        #expect(unmatched == .unknown)
        #expect(asked == [binding])
    }

    /// A resume's deadline is handed the agent itself in front, and a
    /// launch the agent or its tmux client: the two differ behind the
    /// person's own tmux showing the shell, where the deadline must read a
    /// failed resume, not a tmux client taken for the agent.
    @Test func theResumeDeadline_readsTheAgentItself_andALaunch_itsTmuxClientToo() async {
        final class Reader: PaneForegroundReading {
            func isAgentInFront(_: AgentKind, inPane _: UUID) -> Bool {
                true
            }

            func isAgentRunningInFront(_: AgentKind, inPane _: UUID) async -> Bool {
                false
            }

            func agentInFrontReading(inPane _: UUID) async -> AgentInFrontReading {
                .undetermined
            }
        }
        let reader = Reader()
        let deadline = PaneForegroundWiring.resumeDeadline(reader)
        let launch = PaneForegroundWiring.launchFollow(reader)

        #expect(await deadline(UUID(), .codex) == false)
        #expect(launch(UUID(), .codex))
        withExtendedLifetime(reader) {}
    }
}
