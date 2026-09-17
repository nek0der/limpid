// CodexShimScriptTests.swift
// Limpid — drives `codex-shim/codex` with `LIMPID_REAL_CODEX` pointed at a
// stub that records what it was handed. Codex had no shim at all, so this
// pins what the new one owes its caller: the user's arguments arrive
// untouched behind our own, and the pid the receiver watches is the
// agent's own.

import Foundation
import Testing
@testable import Limpid

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

    /// What the tmux stub does when it is asked to create the session.
    private enum TmuxStub {
        /// Prints the report `new-session -P -F` asks for. The socket is the
        /// one this build's agents would use, so the request it leads to is
        /// one `AgentMirrorRequest.parse` accepts.
        case reports
        /// Exits non-zero, the way a tmux that could not create the session
        /// does.
        case fails

        var script: String {
            switch self {
            case .reports:
                #"printf '/private/tmp/tmux-501/limpid-dev.limpid.Limpid\t$3\t@4\t%%5\t4100\t1758130000\n'"#
            case .fails:
                "printf 'tmux: no server running\\n' >&2; exit 1"
            }
        }
    }

    /// Everything one hosted invocation left behind: what each stub was
    /// handed, what the pane saw, and the request the shim wrote for Limpid.
    private struct HostedRun {
        var tmuxArgv: [String]?
        var codexArgv: [String]?
        var status: Int32
        /// What reached the pane, with the pty's carriage returns removed.
        var output: String
        var errors: String
        /// Every name left in the request directory, hidden ones included —
        /// which is how a temporary file that outlived the shim shows up.
        var leftBehind: [String]
        /// The bytes of the single request, when the shim wrote exactly one.
        var request: Data?

        var handover: Handover {
            if let tmuxArgv {
                return .tmux(tmuxArgv)
            }
            if let codexArgv {
                return .direct(codexArgv)
            }
            return .none
        }
    }

    /// The socket name `TmuxStub.reports` names, as this build's own.
    private static let ownSocketName = "limpid-dev.limpid.Limpid"

    /// Runs the shim under a pty. The hosting decision asks whether stdin
    /// and stdout are terminals, and a `Process` pipe is not one, so the
    /// plain harness above can never reach the tmux branch at all.
    ///
    /// `size` is imposed on the pty rather than inherited, since the window
    /// size a test process passes down is nobody's terminal; `nil` stands
    /// for the pty that never got one.
    private func runShimHosted(
        _ args: [String],
        hookArgs: String? = nil,
        paneID: String? = "547D688D-39DF-4A06-BD6F-316C3385532C",
        insideTmux: Bool = false,
        tmux: TmuxStub = .reports,
        size: (columns: Int, rows: Int)? = (columns: 103, rows: 37),
        hasRequestDirectory: Bool = true
    ) throws -> HostedRun {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/codex-shim/codex")
            let codexArgv = dir.appendingPathComponent("codex.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            let errorFile = dir.appendingPathComponent("stderr")
            let requests = dir.appendingPathComponent("requests", isDirectory: true)
            if hasRequestDirectory {
                try FileManager.default.createDirectory(
                    at: requests, withIntermediateDirectories: true
                )
            }
            // NUL-separated so an argument carrying spaces or newlines
            // — every `-c` value does — stays one argument.
            for (name, argvFile, tail) in [
                ("fake-codex", codexArgv, "exit 0"),
                ("fake-tmux", tmuxArgv, tmux.script)
            ] {
                try Self.writeScript(
                    """
                    : > "\(argvFile.path)"
                    for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
                    \(tail)
                    """,
                    to: dir.appendingPathComponent(name)
                )
            }
            // stderr goes to a file rather than the pty, so the two streams
            // can be read apart; the shim only asks whether stdin and stdout
            // are terminals.
            let runner = dir.appendingPathComponent("run.sh")
            try Self.writeScript(
                """
                stty rows \(size?.rows ?? 0) columns \(size?.columns ?? 0) 2>/dev/null
                exec /bin/sh "\(shim.path)" "$@" 2> "\(errorFile.path)"
                """,
                to: runner
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", runner.path] + args
            let output = Pipe()
            process.standardOutput = output
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_REAL_CODEX": dir.appendingPathComponent("fake-codex").path,
                "LIMPID_AGENT_TMUX": dir.appendingPathComponent("fake-tmux").path,
                "LIMPID_AGENT_TMUX_SOCKET": Self.ownSocketName,
                AgentMirrorRequest.directoryVariable: requests.path,
                // Spaces on purpose: these reach tmux as `-e` values.
                "LIMPID_CODEX_SESSIONS_DIR": "/App Support/codex-sessions",
                "LIMPID_CODEX_AGENT_STATES_DIR": "/App Support/codex-agent-states",
                "LIMPID_AGENT_HOOK_BACKEND": "rust"
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
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            /// Each stub truncates its file before recording, so the file
            /// existing is what says the stub ran at all.
            func argv(_ url: URL) -> [String]? {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return text.split(separator: "\0").map(String.init)
            }
            let leftBehind = ((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? [])
                .sorted()
            let written = leftBehind.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            return HostedRun(
                tmuxArgv: argv(tmuxArgv),
                codexArgv: argv(codexArgv),
                status: process.terminationStatus,
                output: (String(bytes: printed, encoding: .utf8) ?? "").replacingOccurrences(of: "\r", with: ""),
                errors: (try? String(contentsOf: errorFile, encoding: .utf8)) ?? "",
                leftBehind: leftBehind,
                request: written.count == 1
                    ? try? Data(contentsOf: requests.appendingPathComponent(written[0]))
                    : nil
            )
        }
    }

    private static func writeScript(_ body: String, to url: URL) throws {
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    /// The whole handoff is one invocation: the server options are set
    /// in the same command that creates the session, so they are in
    /// force before the pane exists. A server of our own because
    /// `escape-time` and the terminal overrides are server-wide and not
    /// ours to change on the one the user also uses.
    @Test("hosts the agent in a detached tmux session of its own")
    func hostedInvocation_buildsTheSessionAndItsServer() throws {
        let run = try runShimHosted([])
        guard case let .tmux(argv) = run.handover else {
            Issue.record("expected a tmux handover, got \(run.handover)")
            return
        }
        #expect(argv.prefix(2) == ["-L", Self.ownSocketName])
        // `-L` picks the socket but leaves `~/.tmux.conf` loading, which
        // would bring the user's hooks and plugins onto our server.
        // `-u` is a server flag rather than one `new-session` takes.
        #expect(argv.dropFirst(2).prefix(3) == ["-u", "-f", "/dev/null"])
        #expect(argv.contains("new-session"))
        // Detached: the agent belongs to the server, not to this shell, and
        // Limpid shows it by attaching a mirror tab.
        #expect(argv.contains("-d"))
        #expect(argv.contains("-P"))
        #expect(argv.contains { $0.hasPrefix("#{socket_path}") })
        #expect(argv.contains { $0.hasPrefix("LIMPID_AGENT_RUN_ID=") })
        #expect(argv.contains("LIMPID_AGENT_TMUX_HOST_MODE=limpidHosted"))
        #expect(argv.contains("LIMPID_AGENT_HOOK_BACKEND=rust"))
        // `-A` would attach to an existing session of the same name and
        // silently drop the command, handing back the running agent.
        #expect(!argv.contains("-A"))
        // Guarantees more than one argument after `new-session`, which is
        // what makes tmux exec the argv directly instead of handing a
        // single string to `sh -c`.
        #expect(argv.dropLast().last == "/usr/bin/env")
    }

    /// The session opens at the size of the pane the command was typed in,
    /// so the agent does not draw once at tmux's default and reflow when
    /// the tab attaches.
    @Test("sizes the session from the terminal it was started on")
    func hostedInvocation_sizesTheSession() throws {
        guard case let .tmux(argv) = try runShimHosted([]).handover else {
            Issue.record("expected a tmux handover")
            return
        }
        let columns = try #require(argv.firstIndex(of: "-x"))
        #expect(argv[columns + 1] == "103")
        let rows = try #require(argv.firstIndex(of: "-y"))
        #expect(argv[rows + 1] == "37")
    }

    /// A pty with no size of its own is left to tmux's default rather than
    /// asked for a zero-sized session.
    @Test("omits the size when the terminal has none")
    func hostedInvocation_withoutASize_omitsTheFlags() throws {
        guard case let .tmux(argv) = try runShimHosted([], size: nil).handover else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(!argv.contains("-x"))
        #expect(!argv.contains("-y"))
    }

    /// The leaf of the mirror tab is the agent's pane as far as every
    /// record is concerned, so the agent is given that id — not the one of
    /// the pane the command was typed in, which travels in the request as
    /// where to put the tab.
    @Test("gives the agent the mirror leaf's id, not the launching pane's")
    func hostedInvocation_replacesThePaneID() throws {
        let run = try runShimHosted([])
        guard case let .tmux(argv) = run.handover else {
            Issue.record("expected a tmux handover")
            return
        }
        let passed = try #require(argv.first { $0.hasPrefix("LIMPID_PANE_ID=") })
        let leaf = String(passed.dropFirst("LIMPID_PANE_ID=".count))
        #expect(leaf != "547D688D-39DF-4A06-BD6F-316C3385532C")
        let request = try Self.parseRequest(run)
        #expect(request?.leafID == UUID(uuidString: leaf))
        #expect(request?.launchPaneID == UUID(uuidString: "547D688D-39DF-4A06-BD6F-316C3385532C"))
    }

    private static func parseRequest(_ run: HostedRun) throws -> AgentMirrorRequest? {
        guard let data = run.request else {
            Issue.record("expected one request file, found \(run.leftBehind)")
            return nil
        }
        return try AgentMirrorRequest.parse(data, ownSocketName: ownSocketName)
    }

    /// The request is the whole of the handover to Limpid, so it has to
    /// pass the same validation the watcher puts it through.
    @Test("writes a request Limpid accepts")
    func hostedInvocation_writesAValidRequest() throws {
        let run = try runShimHosted([])
        let request = try #require(try Self.parseRequest(run))
        #expect(request.socketPath.hasSuffix("/" + Self.ownSocketName))
        #expect(request.sessionID == "$3")
        #expect(request.windowID == "@4")
        #expect(request.paneID == "%5")
        #expect(request.serverPID == "4100")
        #expect(request.serverStartedAt == "1758130000")
        #expect(request.sessionName.hasPrefix("limpid-547D688D-"))
        #expect(request.provider == .codex)
    }

    /// Written under a hidden name and renamed, so the watcher only ever
    /// sees a whole request — and so nothing of a half-written one is left
    /// in the directory afterwards.
    @Test("leaves nothing but the finished request behind")
    func hostedInvocation_writesTheRequestAtomically() throws {
        let run = try runShimHosted([])
        #expect(run.leftBehind.count == 1)
        #expect(run.leftBehind.allSatisfy { !$0.hasPrefix(".") && $0.hasSuffix(".json") })
    }

    /// The pane the command was typed in gets one line and its prompt
    /// back; the agent is no longer this shell's child.
    @Test("returns to the prompt after one line")
    func hostedInvocation_printsOneLineAndSucceeds() throws {
        let run = try runShimHosted([])
        #expect(run.status == 0)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Opened in a Limpid tab.")
        #expect(run.errors.isEmpty)
    }

    /// An agent that silently ran where the user cannot see it is the
    /// failure that is hard to notice, so a launch that cannot be shown
    /// does not happen at all.
    @Test("fails loudly when tmux cannot create the session")
    func hostedInvocation_tmuxFailure_exitsNonZero() throws {
        let run = try runShimHosted([], tmux: .fails)
        #expect(run.status != 0)
        #expect(run.errors.contains("limpid:"))
        #expect(run.leftBehind.isEmpty)
        #expect(run.codexArgv == nil)
    }

    @Test("fails loudly when there is nowhere to ask for a tab")
    func hostedInvocation_withoutARequestDirectory_exitsNonZero() throws {
        let run = try runShimHosted([], hasRequestDirectory: false)
        #expect(run.status != 0)
        #expect(run.errors.contains("limpid:"))
        // Nothing was started, so there is no session to clean up either.
        #expect(run.tmuxArgv == nil)
        #expect(run.codexArgv == nil)
    }

    /// The reason nothing here is quoted. Each `-c` value is TOML with
    /// spaces, quotes and brackets, and it has to reach Codex byte for
    /// byte or the trust hashes stop covering what was passed.
    @Test("carries the hook flags through tmux untouched")
    func hostedInvocation_preservesHookArguments() throws {
        let value = "hooks.Stop=[{hooks=[{command=[\"/a b/hook\", \"x\"]}]}]"
        let run = try runShimHosted(["resume"], hookArgs: "-c\n\(value)")
        guard case let .tmux(argv) = run.handover else {
            Issue.record("expected a tmux handover, got \(run.handover)")
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
        guard case let .tmux(argv) = try runShimHosted([]).handover else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(argv.contains("LIMPID_CODEX_SESSIONS_DIR=/App Support/codex-sessions"))
        #expect(argv.contains("LIMPID_CODEX_AGENT_STATES_DIR=/App Support/codex-agent-states"))
    }

    @Test("does not wrap again once inside tmux")
    func insideTmux_handsOffDirectly() throws {
        let run = try runShimHosted([], insideTmux: true)
        #expect(run.handover == .direct([]))
        #expect(run.leftBehind.isEmpty)
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
        let run = try runShimHosted(args)
        #expect(run.handover == .direct(args))
        #expect(run.leftBehind.isEmpty)
    }

    /// The interactive entry points, which is the whole allow list: a
    /// bare launch, and the two ways back into an existing session.
    @Test("hosts the interactive entry points", arguments: [
        [], ["resume"], ["resume", "--last"], ["fork"]
    ])
    func interactiveInvocations_areHosted(_ args: [String]) throws {
        guard case .tmux = try runShimHosted(args).handover else {
            Issue.record("expected a tmux handover for \(args)")
            return
        }
    }

    /// Limpid sets the pane id and the tmux path together, so a missing
    /// pane id means this is not a Limpid pane and there is nothing to
    /// name the session after.
    @Test("does not host without a pane id")
    func withoutPaneID_handsOffDirectly() throws {
        #expect(try runShimHosted([], paneID: nil).handover == .direct([]))
    }
}
