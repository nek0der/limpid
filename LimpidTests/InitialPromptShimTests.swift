// InitialPromptShimTests.swift
// Limpid — a first instruction an earlier build staged still reaches the agent once, as one argument, through the shims.

import Foundation
import Testing
@testable import Limpid

@Suite(
    "First instruction through the shims",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    .timeLimit(.minutes(1))
)
struct InitialPromptShimTests {
    enum Agent: String, CaseIterable {
        case claude
        case codex

        var realVariable: String {
            "LIMPID_REAL_\(rawValue.uppercased())"
        }
    }

    /// A prompt a shell would take apart: quotes of both kinds, a command
    /// substitution, a variable, a leading dash, and trailing newlines.
    static let awkwardPrompt = """
    -Fix "the 'quoted' bug" in $(rm -rf ~) and $HOME
    then run `make test`


    """

    /// What the agent got: its argv, and whether the prompt's variable was
    /// still in its environment; and what tmux was handed.
    struct Handoff {
        let agentArgv: [String]
        let tmuxArgv: [String]
        let agentSawVariable: Bool
        /// The agent's own pid, and the one the Codex shim exported as the
        /// agent's.
        let agentPID: String
        let exportedCodexPID: String
    }

    /// Runs the shim once in `dir` with `args`, under a pty and a tmux stub
    /// that runs what it is handed when `hostsInTmux`.
    private func launch(
        _ agent: Agent,
        in dir: URL,
        promptFile: URL?,
        args: [String] = [],
        environment extra: [String: String] = [:],
        hostsInTmux: Bool = false
    ) throws -> Handoff {
        let run = UUID().uuidString
        let agentArgv = dir.appendingPathComponent("agent-\(run)")
        let agentEnv = dir.appendingPathComponent("env-\(run)")
        let tmuxArgv = dir.appendingPathComponent("tmux-\(run)")
        let stub = dir.appendingPathComponent("fake-\(agent.rawValue)-\(run)")
        try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: agentArgv, then: """
        printf '%s\n%s\n%s\n' "${LIMPID_INITIAL_PROMPT_FILE:+set}" "$$" "${LIMPID_CODEX_PID:-}" > "\(agentEnv.path)"
        exit 0
        """), at: stub)
        // Records its argv, then runs what follows `/usr/bin/env`, as tmux
        // runs the session's command.
        let tmux = dir.appendingPathComponent("fake-tmux-\(run)")
        try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: tmuxArgv, then: """
        while [ "$#" -gt 0 ] && [ "$1" != /usr/bin/env ]; do shift; done
        exec "$@"
        """), at: tmux)

        var environment = ShimHarness.environment(in: dir)
        environment[agent.realVariable] = stub.path
        environment["LIMPID_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
        environment["LIMPID_INITIAL_PROMPT_FILE"] = promptFile?.path
        environment.merge(extra) { _, new in new }
        if hostsInTmux {
            environment["LIMPID_AGENT_TMUX"] = tmux.path
            environment["LIMPID_AGENT_TMUX_SOCKET"] = "limpid-test.socket"
            environment["LIMPID_PANE_ID"] = "547D688D-39DF-4A06-BD6F-316C3385532C"
        }
        let process = try ShimHarness.run(
            ShimHarness.shim(agent.rawValue),
            args,
            environment: environment,
            underPTY: hostsInTmux
        )
        #expect(process.terminationStatus == 0)
        func argv(_ url: URL) -> [String] {
            ShimHarness.recordedArgv(url, keepsEmptyArguments: true) ?? []
        }
        let lines = ((try? String(contentsOf: agentEnv, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Handoff(
            agentArgv: argv(agentArgv),
            tmuxArgv: argv(tmuxArgv),
            agentSawVariable: lines.first == "set",
            agentPID: lines.count > 1 ? lines[1] : "",
            exportedCodexPID: lines.count > 2 ? lines[2] : ""
        )
    }

    private static func prompts(in dir: URL) -> URL {
        dir.appendingPathComponent("prompts")
    }

    @Test(arguments: Agent.allCases)
    func shim_passesPromptOnceOnly(_ agent: Agent) throws {
        try withTempDir { dir in
            let file = try InitialPromptFile.stagedByEarlierBuild(Self.awkwardPrompt, in: Self.prompts(in: dir))
            let first = try launch(agent, in: dir, promptFile: file)
            // One argument, after `--`, exactly as written.
            #expect(first.agentArgv.suffix(2) == ["--", Self.awkwardPrompt])
            // Neither the file, nor the copy taken, nor the variable stays.
            let left = try FileManager.default.contentsOfDirectory(atPath: Self.prompts(in: dir).path)
            #expect(left.isEmpty)
            #expect(!first.agentSawVariable)

            // The pane's shell still names the file; the next launch finds
            // none and passes nothing.
            let second = try launch(agent, in: dir, promptFile: file)
            #expect(!second.agentArgv.contains("--"))
        }
    }

    @Test(arguments: Agent.allCases)
    func withoutAFile_theShimAddsNoArgument(_ agent: Agent) throws {
        try withTempDir { dir in
            let handoff = try launch(agent, in: dir, promptFile: nil)
            #expect(!handoff.agentArgv.contains("--"))
        }
    }

    /// Written inline in `@Test(arguments:)`, this list does not type-check
    /// in reasonable time on Xcode 27, so we state its type here.
    static let launchesThatStartNoNewSession: [(Agent, [String])] = [
        (.claude, ["--version"]), (.claude, ["-r", "abc"]), (.claude, ["doctor"]),
        (.claude, ["--resume=abc"]), (.claude, ["-rabc"]), (.claude, ["--from-pr", "12"]),
        (.claude, ["my prompt"]), (.claude, ["rc"]), (.claude, ["--", "x"]),
        (.codex, ["--version"]), (.codex, ["resume", "abc"]), (.codex, ["exec", "x"]),
        (.codex, ["newcmd"]), (.codex, ["-m", "gpt-5", "newcmd"]), (.codex, ["--model=gpt-5", "newcmd"]),
        (.codex, ["-m=gpt-5", "newcmd"])
    ]

    /// A launch that starts no new session, or whose shape is no alias's
    /// (an unknown subcommand, the user's own prompt), leaves the
    /// instruction for the launch that does.
    @Test(arguments: launchesThatStartNoNewSession)
    func aLaunchThatStartsNoNewSession_leavesTheInstruction_forTheOneThatDoes(_ agent: Agent, _ args: [String]) throws {
        try withTempDir { dir in
            let file = try InitialPromptFile.stagedByEarlierBuild("do it", in: Self.prompts(in: dir))
            let kept = try launch(agent, in: dir, promptFile: file, args: args)
            #expect(!kept.agentArgv.contains("do it"))
            #expect(FileManager.default.fileExists(atPath: file.path))

            let taken = try launch(agent, in: dir, promptFile: file)
            #expect(taken.agentArgv.suffix(2) == ["--", "do it"])
        }
    }

    /// The staged `claude` meets the person's alias, which adds flags.
    @Test(arguments: [
        (Agent.claude, ["--model", "opus"]), (Agent.claude, ["--permission-mode", "plan", "--verbose"]),
        (Agent.claude, ["--model=opus"]), (Agent.codex, ["-m", "gpt-5"]), (Agent.codex, ["-c", "key=value"])
    ])
    func flagsAnAliasAdds_stillTakeTheInstruction(_ agent: Agent, _ args: [String]) throws {
        try withTempDir { dir in
            let file = try InitialPromptFile.stagedByEarlierBuild("do it", in: Self.prompts(in: dir))
            let handoff = try launch(agent, in: dir, promptFile: file, args: args)
            #expect(handoff.agentArgv.suffix(2) == ["--", "do it"])
        }
    }

    /// The hook flags go in ahead of the instruction, and the pid the shim
    /// exports is still the agent's once the reader runs in between.
    @Test func codexsHookFlags_andItsPid_surviveTheReader() throws {
        try withTempDir { dir in
            let file = try InitialPromptFile.stagedByEarlierBuild("do it", in: Self.prompts(in: dir))
            let handoff = try launch(.codex, in: dir, promptFile: file, environment: ["LIMPID_CODEX_HOOK_ARGS": "-c\nhooks.x=1"])
            #expect(handoff.agentArgv == ["-c", "hooks.x=1", "--", "do it"])
            #expect(!handoff.agentPID.isEmpty)
            #expect(handoff.exportedCodexPID == handoff.agentPID)
        }
    }

    @Test(arguments: Agent.allCases)
    func hostedInTmux_aLongPrompt_staysOffTmuxsCommandLine_andReachesTheAgent(_ agent: Agent) throws {
        try withTempDir { dir in
            // Past what tmux takes on its command line (about 16 KB).
            let long = String(repeating: "word ", count: 4000) + Self.awkwardPrompt
            let file = try InitialPromptFile.stagedByEarlierBuild(long, in: Self.prompts(in: dir))
            let handoff = try launch(agent, in: dir, promptFile: file, hostsInTmux: true)
            #expect(handoff.tmuxArgv.contains("new-session"))
            #expect(!handoff.tmuxArgv.contains(long))
            #expect(!handoff.tmuxArgv.contains { $0.hasPrefix("LIMPID_INITIAL_PROMPT_FILE=") })
            #expect(handoff.agentArgv.suffix(2) == ["--", long])
            #expect(!handoff.agentSawVariable)
        }
    }

    /// Claude's parser takes a lone word after `--` as a subcommand of that
    /// name; `purge` would delete the project's state.
    @Test func aOneWordPrompt_isNoSubcommandForClaude_andUnchangedForCodex() throws {
        try withTempDir { dir in
            let forClaude = try InitialPromptFile.stagedByEarlierBuild("purge", in: Self.prompts(in: dir))
            let claude = try launch(.claude, in: dir, promptFile: forClaude)
            #expect(claude.agentArgv.suffix(2) == ["--", "purge "])
            let forCodex = try InitialPromptFile.stagedByEarlierBuild("purge", in: Self.prompts(in: dir))
            let codex = try launch(.codex, in: dir, promptFile: forCodex)
            #expect(codex.agentArgv.suffix(2) == ["--", "purge"])
        }
    }
}
