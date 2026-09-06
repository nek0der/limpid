// CodexShimScriptTests.swift
// Limpid — drives `codex-shim/codex` with `LIMPID_REAL_CODEX` pointed at a
// stub that records what it was handed. Codex had no shim at all, so this
// pins what the new one owes its caller: the user's arguments arrive
// untouched behind our own, and the pid the receiver watches is the
// agent's own.

import Foundation
import Testing

@Suite("Codex shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct CodexShimScriptTests {
    private struct Handoff {
        var argv: [String]
        var codexPID: String?
        /// The stub's own pid, which `exec` makes the agent's pid too.
        var ownPID: String?
    }

    private func runShim(
        _ args: [String],
        hookArgs: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Handoff {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/codex-shim/codex")
            let stub = dir.appendingPathComponent("fake-codex")
            let argvFile = dir.appendingPathComponent("argv")
            let envFile = dir.appendingPathComponent("env")
            // NUL-separated so a multi-line argument stays one argument.
            try """
            #!/bin/sh
            : > "\(argvFile.path)"
            for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
            printf '%s\\n%s\\n' "${LIMPID_CODEX_PID:-}" "$$" > "\(envFile.path)"
            exit 0
            """.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path] + args
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_REAL_CODEX": stub.path
            ]
            if let hookArgs {
                process.environment?["LIMPID_CODEX_HOOK_ARGS"] = hookArgs
            }
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            let argv = ((try? String(contentsOf: argvFile, encoding: .utf8)) ?? "")
                .split(separator: "\0").map(String.init)
            let lines = ((try? String(contentsOf: envFile, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Handoff(
                argv: argv,
                codexPID: lines.first.flatMap { $0.isEmpty ? nil : $0 },
                ownPID: lines.count > 1 ? lines[1] : nil
            )
        }
    }

    @Test("hands the user's arguments through unchanged")
    func passesArgumentsThrough() throws {
        let handoff = try runShim(["exec", "--skip-git-repo-check", "hello world"])
        #expect(handoff.argv.suffix(3) == ["exec", "--skip-git-repo-check", "hello world"])
    }

    /// The flags arrive through the environment rather than being built
    /// in shell: the same Swift that writes the trust block has to
    /// produce them, or the hashes stop covering what is actually passed.
    @Test("splices the hook flags in ahead of the user's arguments")
    func splicesHookArgumentsBeforeUserArguments() throws {
        let handoff = try runShim(
            ["resume"],
            hookArgs: "-c\nhooks.Stop=[{hooks=[]}]\n-c\ntui.terminal_title=[]"
        )
        #expect(handoff.argv == [
            "-c", "hooks.Stop=[{hooks=[]}]", "-c", "tui.terminal_title=[]", "resume"
        ])
    }

    @Test("leaves the command line alone when there are no hook flags")
    func noHookArguments_passesThrough() throws {
        let handoff = try runShim(["resume"])
        #expect(handoff.argv == ["resume"])
    }

    /// `exec` gives the shim's shell pid to the agent, so exporting it
    /// before the handover is what lets the receiver skip walking the
    /// process tree to guess which ancestor is Codex.
    @Test("exports its own pid as the agent's")
    func exportsItsOwnPidAsTheAgents() throws {
        let handoff = try runShim([])
        #expect(handoff.codexPID != nil)
        #expect(handoff.codexPID == handoff.ownPID)
    }

    /// Where the shim handed control, once tmux hosting is switched on.
    private enum Handover: Equatable {
        case direct([String])
        case tmux([String])
        /// Neither stub ran. Distinguished from `.direct([])` because a
        /// shim that exits before handing off at all would otherwise
        /// satisfy every assertion about an argument-free handoff.
        case none
    }

    /// Runs the shim under a pty. The hosting decision asks whether
    /// stdin and stdout are terminals, and a `Process` pipe is not one,
    /// so the harness above can never reach the tmux branch at all.
    private func runShimHosted(
        _ args: [String],
        hookArgs: String? = nil,
        paneID: String? = "547D688D-39DF-4A06-BD6F-316C3385532C",
        insideTmux: Bool = false
    ) throws -> Handover {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/codex-shim/codex")
            let codexArgv = dir.appendingPathComponent("codex.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            let codexStub = dir.appendingPathComponent("fake-codex")
            let tmuxStub = dir.appendingPathComponent("fake-tmux")
            for (stub, argvFile) in [(codexStub, codexArgv), (tmuxStub, tmuxArgv)] {
                // NUL-separated so an argument carrying spaces or newlines
                // — every `-c` value does — stays one argument.
                try """
                #!/bin/sh
                : > "\(argvFile.path)"
                for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
                exit 0
                """.write(to: stub, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: stub.path
                )
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", shim.path] + args
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_REAL_CODEX": codexStub.path,
                "LIMPID_AGENT_TMUX": tmuxStub.path,
                "LIMPID_AGENT_TMUX_SOCKET": "limpid-test.socket",
                // Spaces on purpose: these reach tmux as `-e` values.
                "LIMPID_CODEX_SESSIONS_DIR": "/App Support/codex-sessions",
                "LIMPID_CODEX_AGENT_STATES_DIR": "/App Support/codex-agent-states"
            ]
            if let paneID {
                process.environment?["LIMPID_PANE_ID"] = paneID
            }
            if let hookArgs {
                process.environment?["LIMPID_CODEX_HOOK_ARGS"] = hookArgs
            }
            if insideTmux {
                process.environment?["TMUX"] = "/tmp/tmux-501/default,4242,0"
            }
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            /// Each stub truncates its file before recording, so the file
            /// existing is what says the stub ran at all.
            func argv(_ url: URL) -> [String]? {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return text.split(separator: "\0").map(String.init)
            }
            if let recorded = argv(tmuxArgv) {
                return .tmux(recorded)
            }
            if let recorded = argv(codexArgv) {
                return .direct(recorded)
            }
            return .none
        }
    }

    /// The whole handoff is one invocation: the server options are set
    /// in the same command that creates the session, so they are in
    /// force before the pane exists. A server of our own because
    /// `escape-time` and the terminal overrides are server-wide and not
    /// ours to change on the one the user also uses.
    @Test("hosts the agent in a tmux session of its own")
    func hostedInvocation_buildsTheSessionAndItsServer() throws {
        let handover = try runShimHosted([])
        guard case let .tmux(argv) = handover else {
            Issue.record("expected a tmux handover, got \(handover)")
            return
        }
        #expect(argv.prefix(2) == ["-L", "limpid-test.socket"])
        // `-L` picks the socket but leaves `~/.tmux.conf` loading, which
        // would bring the user's hooks and plugins onto our server.
        #expect(argv.dropFirst(2).prefix(2) == ["-f", "/dev/null"])
        #expect(argv.contains("new-session"))
        #expect(argv.contains("-e"))
        #expect(argv.contains("LIMPID_PANE_ID=547D688D-39DF-4A06-BD6F-316C3385532C"))
        // `-A` would attach to an existing session of the same name and
        // silently drop the command, handing back the running agent.
        #expect(!argv.contains("-A"))
        // Guarantees more than one argument after `new-session`, which is
        // what makes tmux exec the argv directly instead of handing a
        // single string to `sh -c`.
        #expect(argv.dropLast().last == "/usr/bin/env")
    }

    /// The reason nothing here is quoted. Each `-c` value is TOML with
    /// spaces, quotes and brackets, and it has to reach Codex byte for
    /// byte or the trust hashes stop covering what was passed.
    @Test("carries the hook flags through tmux untouched")
    func hostedInvocation_preservesHookArguments() throws {
        let value = "hooks.Stop=[{hooks=[{command=[\"/a b/hook\", \"x\"]}]}]"
        let handover = try runShimHosted(["resume"], hookArgs: "-c\n\(value)")
        guard case let .tmux(argv) = handover else {
            Issue.record("expected a tmux handover, got \(handover)")
            return
        }
        #expect(argv.suffix(3) == ["-c", value, "resume"])
    }

    /// `PATH` still carries the shim directory inside the session, so
    /// without this the shim would wrap itself without bound.
    /// A session created on a server that already exists inherits that
    /// server's environment for everything outside tmux's
    /// `update-environment` — measured 2026-09-06, a second session read
    /// the first one's `LIMPID_CODEX_AGENT_STATES_DIR`. The receiver
    /// writes its records where these point, so a Dev agent that landed
    /// on a Release build's server would write into the Release
    /// directories. They are passed rather than inherited.
    @Test("passes the record directories explicitly rather than inheriting them")
    func hostedInvocation_passesTheRecordDirectories() throws {
        guard case let .tmux(argv) = try runShimHosted([]) else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(argv.contains("LIMPID_CODEX_SESSIONS_DIR=/App Support/codex-sessions"))
        #expect(argv.contains("LIMPID_CODEX_AGENT_STATES_DIR=/App Support/codex-agent-states"))
    }

    @Test("does not wrap again once inside tmux")
    func insideTmux_handsOffDirectly() throws {
        #expect(try runShimHosted([], insideTmux: true) == .direct([]))
    }

    /// Anything printed inside tmux is erased when the client leaves the
    /// alternate screen, so a one-shot invocation has to run directly.
    /// `-m gpt-5 exec` is the case that decided the shape of this rule.
    /// A global option can sit in front of a subcommand, so reading the
    /// first argument does not find it, and wrapping `exec` would send
    /// its output to a screen tmux erases on the way out. A prompt is
    /// indistinguishable from a subcommand, so a prompt on the command
    /// line is not hosted either.
    @Test("runs anything it does not recognize directly", arguments: [
        ["--version"], ["--help"], ["--print", "hi"], ["login"],
        ["exec", "check this"], ["-m", "gpt-5", "exec", "check this"],
        ["fix the failing test"], ["hello"]
    ])
    func unrecognizedInvocations_areNotHosted(_ args: [String]) throws {
        #expect(try runShimHosted(args) == .direct(args))
    }

    /// The interactive entry points, which is the whole allow list: a
    /// bare launch, and the two ways back into an existing session.
    @Test("hosts the interactive entry points", arguments: [
        [], ["resume"], ["resume", "--last"], ["fork"]
    ])
    func interactiveInvocations_areHosted(_ args: [String]) throws {
        guard case .tmux = try runShimHosted(args) else {
            Issue.record("expected a tmux handover for \(args)")
            return
        }
    }

    /// Limpid sets the pane id and the tmux path together, so a missing
    /// pane id means this is not a Limpid pane and there is nothing to
    /// name the session after.
    @Test("does not host without a pane id")
    func withoutPaneID_handsOffDirectly() throws {
        #expect(try runShimHosted([], paneID: nil) == .direct([]))
    }
}
