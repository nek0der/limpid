// CodexShimScriptTests.swift
// Limpid — drives `codex-shim/codex` with `LIMPID_REAL_CODEX` pointed at a
// stub that records what it was handed. This pins what the shim owes its
// caller: the user's arguments arrive untouched behind our own, and the pid
// the receiver watches is the agent's own.

import Foundation
import Testing

@Suite("Codex shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"), .timeLimit(.minutes(1)))
struct CodexShimScriptTests {
    private struct Handoff {
        var argv: [String]
        var codexPID: String?
        /// The stub's own pid, which `exec` makes the agent's pid too.
        var ownPID: String?
        /// The `CODEX_HOME` the agent was started with.
        var codexHome: String?
    }

    /// `prepare` is given the temporary directory the shim runs in, and
    /// returns what to add to its environment.
    private func runShim(
        _ args: [String],
        hookArgs: String? = nil,
        prepare: (URL) throws -> [String: String] = { _ in [:] },
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Handoff {
        try withTempDir { dir in
            let stub = dir.appendingPathComponent("fake-codex")
            let argvFile = dir.appendingPathComponent("argv")
            let envFile = dir.appendingPathComponent("env")
            try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile, then: """
            printf '%s\\n%s\\n%s\\n' "${LIMPID_CODEX_PID:-}" "$$" "${CODEX_HOME:-}" > "\(envFile.path)"
            exit 0
            """), at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["LIMPID_REAL_CODEX"] = stub.path
            environment["LIMPID_CODEX_HOOK_ARGS"] = hookArgs
            try environment.merge(prepare(dir)) { _, added in added }
            let process = try ShimHarness.run(ShimHarness.shim("codex"), args, environment: environment, currentDirectory: dir)
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            let argv = ShimHarness.recordedArgv(argvFile) ?? []
            let lines = ((try? String(contentsOf: envFile, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Handoff(
                argv: argv,
                codexPID: lines.first.flatMap { $0.isEmpty ? nil : $0 },
                ownPID: lines.count > 1 ? lines[1] : nil,
                codexHome: lines.count > 2 && !lines[2].isEmpty ? lines[2] : nil
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

    /// Codex resolves a relative `CODEX_HOME` against the directory it
    /// starts in, and our hook, which runs in the session's `cwd`, cannot:
    /// without this it reads Codex's memory agent as the person's.
    @Test("makes a relative CODEX_HOME absolute against where Codex starts")
    func relativeCodexHome_isMadeAbsolute() throws {
        var expected = ""
        let handoff = try runShim([]) { dir in
            expected = dir.appendingPathComponent(".codex-work").path
            return ["CODEX_HOME": ".codex-work"]
        }
        /// The shell's `$PWD` and Foundation spell the temporary directory
        /// with and without `/private`.
        func unprivate(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let home = try #require(handoff.codexHome)
        #expect(home.hasPrefix("/"), "\(home)")
        #expect(unprivate(home) == unprivate(expected))
    }

    @Test("leaves an absolute CODEX_HOME, and an unset one, as they are")
    func absoluteOrUnsetCodexHome_isLeftAlone() throws {
        #expect(try runShim([]) { _ in ["CODEX_HOME": "/opt/codex"] }.codexHome == "/opt/codex")
        #expect(try runShim([]).codexHome == nil)
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
        insideTmux: Bool = false,
        environment: [String: String] = [:],
        knownLocation: String? = nil,
        onPath: Bool = false,
        seenFound: ((String?) -> Void)? = nil
    ) throws -> Handover {
        try withTempDir { dir in
            let codexArgv = dir.appendingPathComponent("codex.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            // With `knownLocation`, the stub is there, under the temporary
            // folder, and the shim finds it from the catalog's list
            // rather than being pointed at it; `onPath`, on the PATH.
            let codexStub = dir.appendingPathComponent(knownLocation ?? (onPath ? "bin/codex" : "fake-codex"))
            try FileManager.default.createDirectory(at: codexStub.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmuxStub = dir.appendingPathComponent("fake-tmux")
            for (stub, argvFile) in [(codexStub, codexArgv), (tmuxStub, tmuxArgv)] {
                // Beside the argv, what the stub saw of the sheet's
                // executable (`seenFound`).
                try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile, then: """
                printf '%s' "${LIMPID_FOUND_CODEX-unset}" > "\(argvFile.path).found"
                exit 0
                """), at: stub)
            }

            var shimEnvironment = ShimHarness.environment(in: dir)
            shimEnvironment.merge([
                "LIMPID_REAL_CODEX": codexStub.path,
                "LIMPID_AGENT_TMUX": tmuxStub.path,
                "LIMPID_AGENT_TMUX_SOCKET": "limpid-test.socket",
                // Spaces on purpose: these reach tmux as `-e` values.
                "LIMPID_CODEX_SESSIONS_DIR": "/App Support/codex-sessions",
                "LIMPID_CODEX_AGENT_STATES_DIR": "/App Support/codex-agent-states"
            ]) { _, new in new }
            shimEnvironment["LIMPID_PANE_ID"] = paneID
            shimEnvironment["LIMPID_CODEX_HOOK_ARGS"] = hookArgs
            if insideTmux {
                shimEnvironment["TMUX"] = "/tmp/tmux-501/default,4242,0"
            }
            if knownLocation != nil {
                shimEnvironment["LIMPID_REAL_CODEX"] = nil
                shimEnvironment["LIMPID_CODEX_KNOWN_LOCATIONS"] = codexStub.path
            }
            if onPath {
                shimEnvironment["LIMPID_REAL_CODEX"] = nil
                shimEnvironment["PATH"] = "\(codexStub.deletingLastPathComponent().path):\(ShimHarness.systemPath)"
            }
            shimEnvironment.merge(environment) { _, new in new }
            let process = try ShimHarness.run(ShimHarness.shim("codex"), args, environment: shimEnvironment, underPTY: true)
            #expect(process.terminationStatus == 0)

            /// Each stub truncates its file before recording, so the file
            /// existing is what says the stub ran at all.
            func argv(_ url: URL) -> [String]? {
                ShimHarness.recordedArgv(url)
            }
            if let seenFound {
                let ran = FileManager.default.fileExists(atPath: tmuxArgv.path) ? tmuxArgv : codexArgv
                seenFound(try? String(contentsOfFile: ran.path + ".found", encoding: .utf8))
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
        #expect(argv.contains { $0.hasPrefix("LIMPID_AGENT_RUN_ID=") })
        #expect(argv.contains("LIMPID_AGENT_TMUX_HOST_MODE=limpidHosted"))
        // `-A` would attach to an existing session of the same name and
        // silently drop the command, handing back the running agent.
        #expect(!argv.contains("-A"))
        // Guarantees more than one argument after `new-session`, which is
        // what makes tmux exec the argv directly instead of handing a
        // single string to `sh -c`.
        let env = try #require(argv.lastIndex(of: "/usr/bin/env"))
        // Then only `-u NAME`, for what the pane does not set, and the agent.
        let unsets = argv[(env + 1)...].dropLast()
        #expect(unsets.count.isMultiple(of: 2))
        #expect(stride(from: unsets.startIndex, to: unsets.endIndex, by: 2).allSatisfy { argv[$0] == "-u" })
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

    /// A server already running would otherwise start the agent with the
    /// `CODEX_HOME` of the pane that started the server, and the hook would
    /// read the memory agent against another home.
    @Test("passes the pane's CODEX_HOME into tmux")
    func hostedInvocation_passesThePanesCodexHome() throws {
        guard case let .tmux(argv) = try runShimHosted([], environment: ["CODEX_HOME": "/opt/codex"]) else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(argv.contains("CODEX_HOME=/opt/codex"), "\(argv)")
    }

    /// A pane with no `CODEX_HOME` must not take the one of the pane that
    /// started the server: a session takes every variable not given to it
    /// from the server's environment, and tmux's `-e` only sets one. So
    /// the agent starts with it unset, through `/usr/bin/env -u`, and
    /// Codex reads its default home, as it would outside tmux.
    @Test("unsets in the session the CODEX_HOME the pane does not set")
    func hostedInvocation_unsetsACodexHomeThePaneDoesNotSet() throws {
        guard case let .tmux(argv) = try runShimHosted([]) else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(!argv.contains { $0.hasPrefix("CODEX_HOME=") }, "\(argv)")
        let env = try #require(argv.lastIndex(of: "/usr/bin/env"))
        let unsets = Array(argv[(env + 1)...].dropLast())
        #expect(zip(unsets, unsets.dropFirst()).contains { $0 == ("-u", "CODEX_HOME") }, "\(argv)")
        // What the session's command does with it, on a server whose
        // environment holds another pane's home.
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = unsets + ["/bin/sh", "-c", "printf %s \"${CODEX_HOME-unset}\""]
        probe.environment = IsolatedProcessEnvironment.make(["CODEX_HOME": "/work/a/.codex", "PATH": "/usr/bin:/bin"])
        probe.standardOutput = output
        try probe.run()
        #expect(probe.waitUntilExit(within: 10))
        let seen = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(seen == "unset")

        // A pane that sets it passes it, and unsets nothing of the kind.
        guard case let .tmux(given) = try runShimHosted([], environment: ["CODEX_HOME": "/opt/codex"]) else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(!zip(given, given.dropFirst()).contains { $0 == ("-u", "CODEX_HOME") }, "\(given)")
    }

    /// The pane's `PATH` too, whichever way the agent was found: a server
    /// already running would start it on the `PATH` of the pane that
    /// started the server, which a mise, direnv or `.nvmrc` folder makes
    /// another project's.
    @Test("passes the pane's PATH into tmux")
    func hostedInvocation_passesThePanesPath() throws {
        guard case let .tmux(argv) = try runShimHosted([], onPath: true) else {
            Issue.record("expected a tmux handover")
            return
        }
        let path = zip(argv, argv.dropFirst()).first { $0.0 == "-e" && $0.1.hasPrefix("PATH=") }?.1
        // As the pane had it: found on it, the agent adds nothing.
        #expect(path?.hasSuffix("/bin:/usr/bin:/bin:/usr/sbin:/sbin") == true, "\(argv)")
        #expect(path?.components(separatedBy: ":").count == 5, "\(argv)")
    }

    /// Found at a known location, the agent's folder has joined the
    /// `PATH`, and the session gets that `PATH`.
    @Test("passes the PATH with the agent's folder when it was found at a known location")
    func hostedInvocation_ofAnAgentAtAKnownLocation_passesThePathWithItsFolder() throws {
        let location = ".nvm/versions/node/v22.3.0/bin/codex"
        guard case let .tmux(argv) = try runShimHosted([], knownLocation: location) else {
            Issue.record("expected a tmux handover")
            return
        }
        let path = zip(argv, argv.dropFirst()).first { $0.0 == "-e" && $0.1.hasPrefix("PATH=") }?.1
        #expect(path?.hasPrefix("PATH=/usr/bin:/bin:/usr/sbin:/sbin:") == true, "\(argv)")
        #expect(path?.hasSuffix("/.nvm/versions/node/v22.3.0/bin") == true, "\(argv)")
        #expect(argv.last?.hasSuffix(location) == true, "\(argv)")
    }

    /// What the new workspace sheet found stays with the pane's shell: a
    /// tmux server started with it would hand it to every session after,
    /// in whatever folder. Neither the tmux client nor its `-e` list has it.
    @Test("keeps what the sheet found out of tmux")
    func hostedInvocation_keepsTheSheetsExecutableOutOfTmux() throws {
        var seen: String?
        let handover = try runShimHosted([], environment: ["LIMPID_FOUND_CODEX": "/opt/tools/bin/codex"]) { seen = $0 }
        guard case let .tmux(argv) = handover else {
            Issue.record("expected a tmux handover, got \(handover)")
            return
        }
        #expect(seen == "unset")
        #expect(!argv.contains { $0.hasPrefix("LIMPID_FOUND_") })
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
    /// line is not hosted either. A one-shot flag after an entry point
    /// (`resume --help`) still prints and exits.
    @Test("runs anything it does not recognize directly", arguments: [
        ["--version"], ["--help"], ["--print", "hi"], ["login"],
        ["exec", "check this"], ["-m", "gpt-5", "exec", "check this"],
        ["fix the failing test"], ["hello"], ["resume", "--help"]
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

    @Test("passes an emptied record directory into tmux as empty")
    func hostedLaunch_passesEmptyRecordDirectories() throws {
        // A demo pane empties them; left out, the session would take the
        // tmux server's values, which are another build's directories.
        guard case let .tmux(argv) = try runShimHosted([], environment: [
            "LIMPID_CODEX_AGENT_STATES_DIR": "",
            "LIMPID_CODEX_SESSIONS_DIR": ""
        ]) else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(argv.contains("LIMPID_CODEX_AGENT_STATES_DIR="))
        #expect(argv.contains("LIMPID_CODEX_SESSIONS_DIR="))
    }
}
