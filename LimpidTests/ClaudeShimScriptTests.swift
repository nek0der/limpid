// ClaudeShimScriptTests.swift
// Limpid — drives `claude-shim/claude` with `LIMPID_REAL_CLAUDE` pointed at
// a stub that records its argv, the only way to see what the shim decided
// Claude should receive. `--settings` overwrites rather than merges, so the
// shim has to fold a user-supplied one into its own and pass a single flag;
// these pin that it does, in both spellings and for a file as well as
// inline JSON.

import Foundation
import Testing
@testable import Limpid

@Suite("Claude shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct ClaudeShimScriptTests {
    /// The template lives in the provider crate and the build copies it into
    /// the bundle beside the shim. A test runs the shim from the source tree,
    /// where there is no bundle, so it points the shim at the source instead.
    private static func templatePath(_ root: URL) -> String {
        root.appendingPathComponent(
            "rust/limpid-provider-claude/resources/settings.template.json"
        ).path
    }

    /// Run the shim with `args` and return the argv the real claude would
    /// have been exec'd with.
    private func runShim(
        _ args: [String],
        hookNamespace: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String] {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/claude-shim/claude")
            let stub = dir.appendingPathComponent("fake-claude")
            let argvFile = dir.appendingPathComponent("argv.txt")
            // NUL-separated: the settings payload is pretty-printed JSON, so
            // a newline-delimited dump would split one argument into many.
            try """
            #!/bin/sh
            : > "\(argvFile.path)"
            for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
            exit 0
            """.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path] + args
            var environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_CLAUDE_SETTINGS_TEMPLATE": Self.templatePath(root),
                "LIMPID_REAL_CLAUDE": stub.path
            ]
            environment["LIMPID_CLAUDE_HOOK_NAMESPACE"] = hookNamespace
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            let dumped = (try? String(contentsOf: argvFile, encoding: .utf8)) ?? ""
            return dumped.split(separator: "\0").map(String.init)
        }
    }

    /// The value of the single `--settings` the shim passed, decoded.
    private func settingsPayload(
        in argv: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any]? {
        let flags = argv.indices.filter { argv[$0] == "--settings" }
        #expect(
            flags.count == 1,
            "expected exactly one --settings, got \(flags.count)",
            sourceLocation: sourceLocation
        )
        guard let index = flags.first, index + 1 < argv.count else { return nil }
        let raw = argv[index + 1]
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func sessionStartGroups(_ payload: [String: Any]?) -> [[String: Any]] {
        let hooks = payload?["hooks"] as? [String: Any]
        return hooks?["SessionStart"] as? [[String: Any]] ?? []
    }

    private func sessionStartCommand(_ argv: [String]) throws -> String {
        let decodedPayload = try settingsPayload(in: argv)
        let payload = try #require(decodedPayload)
        let group = try #require(sessionStartGroups(payload).first)
        let hooks = try #require(group["hooks"] as? [[String: Any]])
        return try #require(hooks.first?["command"] as? String)
    }

    @Test("injects our settings when the user passes none")
    func noUserSettings_injectsOurs() throws {
        let argv = try runShim([])
        let payload = try settingsPayload(in: argv)
        #expect(sessionStartGroups(payload).count == 1)
    }

    /// The hook path is captured by a running Claude process. Separate stable
    /// names let a new invocation refresh its own build without redirecting a
    /// session launched by another installed build.
    @Test("namespaces the no-space hook link by build identity")
    func hookLink_separatesBuilds() throws {
        let releaseArguments = try runShim([], hookNamespace: "dev.limpid.Limpid")
        let release = try sessionStartCommand(releaseArguments)
        let developmentArguments = try runShim([], hookNamespace: "dev.limpid.Limpid.dev")
        let development = try sessionStartCommand(developmentArguments)

        #expect(release.hasSuffix("/limpid-claude-shim-dev.limpid.Limpid/limpid-hook"))
        #expect(development.hasSuffix("/limpid-claude-shim-dev.limpid.Limpid.dev/limpid-hook"))
        #expect(release != development)
    }

    @Test("exports the running build identity for the hook link")
    func environment_carriesHookNamespace() {
        let environment = ClaudeShimLocator.environment(forPaneID: nil)
        #expect(environment["LIMPID_CLAUDE_HOOK_NAMESPACE"] == LimpidPaths.bundleID)
    }

    @Test("merges with the user's settings instead of losing to them")
    func userSettings_mergedRatherThanOverwritten() throws {
        let theirs = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/true"}]}]},"env":{"USER_KEY":"1"}}"#
        let argv = try runShim(["--settings", theirs])
        let payload = try settingsPayload(in: argv)
        // Both hook groups survive, and the user's unrelated keys come along.
        #expect(sessionStartGroups(payload).count == 2)
        #expect((payload?["env"] as? [String: Any])?["USER_KEY"] as? String == "1")
    }

    @Test("merges the --settings=value spelling too")
    func userSettingsEqualsForm_merged() throws {
        let theirs = #"{"env":{"USER_KEY":"1"}}"#
        let argv = try runShim(["--settings=\(theirs)"])
        let payload = try settingsPayload(in: argv)
        #expect(sessionStartGroups(payload).count == 1)
        #expect((payload?["env"] as? [String: Any])?["USER_KEY"] as? String == "1")
    }

    @Test("merges a user settings file, not just inline JSON")
    func userSettingsFile_merged() throws {
        let payload = try withTempDir { dir -> [String: Any]? in
            let file = dir.appendingPathComponent("theirs.json")
            try #"{"env":{"FROM_FILE":"1"}}"#.write(to: file, atomically: true, encoding: .utf8)
            return try settingsPayload(in: runShim(["--settings", file.path]))
        }
        #expect(sessionStartGroups(payload).count == 1)
        #expect((payload?["env"] as? [String: Any])?["FROM_FILE"] as? String == "1")
    }

    @Test("passes an unmergeable user value straight through")
    func unmergeableUserSettings_leftAlone() throws {
        let argv = try runShim(["--settings", "{bad"])
        let flags = argv.indices.filter { argv[$0] == "--settings" }
        #expect(flags.count == 1)
        #expect(flags.first.map { argv[$0 + 1] } == "{bad")
    }

    @Test("keeps Rust as the sole automatic title writer")
    func terminalTitleOverride_isForcedOff() throws {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/claude-shim/claude")
            let stub = dir.appendingPathComponent("fake-claude")
            try """
            #!/bin/sh
            [ "$CLAUDE_CODE_DISABLE_TERMINAL_TITLE" = "1" ]
            """.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_CLAUDE_SETTINGS_TEMPLATE": Self.templatePath(root),
                "LIMPID_REAL_CLAUDE": stub.path,
                "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "0"
            ]
            try process.run()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)
        }
    }

    /// One hosted invocation: what each stub was handed, what the pane
    /// saw, and the request the shim left for Limpid.
    private struct HostedRun {
        var tmux: [String]
        var claude: [String]
        var status: Int32
        var output: String
        var errors: String
        var request: Data?
    }

    /// The socket name the tmux stub reports, as this build's own.
    private static let ownSocketName = "limpid-dev.limpid.Limpid"
    /// The whole socket path the stub reports, which is what a request is
    /// compared against.
    private static let ownSocketPath = "/private/tmp/tmux-501/" + ownSocketName

    /// Runs the shim under a pty with tmux hosting switched on. The hosting
    /// decision asks whether stdin and stdout are terminals, and a `Process`
    /// pipe is not one, so the harness above can never reach this branch.
    /// The decision itself is shared with the Codex shim and pinned there;
    /// what is Claude's own is that our `--settings` survives the wrap.
    private func runShimHosted(_ args: [String], tmuxFails: Bool = false) throws -> HostedRun {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/claude-shim/claude")
            let claudeArgv = dir.appendingPathComponent("claude.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            let errorFile = dir.appendingPathComponent("stderr")
            let requests = dir.appendingPathComponent("requests", isDirectory: true)
            try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            let report = #"printf '/private/tmp/tmux-501/limpid-dev.limpid.Limpid\t$3\t@4\t%%5\t4100\t1758130000\n'"#
            for (name, argvFile, tail) in [
                ("fake-claude", claudeArgv, "exit 0"),
                ("fake-tmux", tmuxArgv, tmuxFails ? "exit 1" : report)
            ] {
                // NUL-separated: the settings payload is pretty-printed JSON,
                // so a newline-delimited dump would split one argument.
                try Self.writeScript(
                    """
                    : > "\(argvFile.path)"
                    for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
                    \(tail)
                    """,
                    to: dir.appendingPathComponent(name)
                )
            }
            // stderr goes to a file rather than the pty so the two streams
            // can be read apart; the shim only asks about stdin and stdout.
            let runner = dir.appendingPathComponent("run.sh")
            try Self.writeScript(
                """
                stty rows 37 columns 103 2>/dev/null
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
                "LIMPID_CLAUDE_SETTINGS_TEMPLATE": Self.templatePath(root),
                "LIMPID_REAL_CLAUDE": dir.appendingPathComponent("fake-claude").path,
                "LIMPID_AGENT_TMUX": dir.appendingPathComponent("fake-tmux").path,
                "LIMPID_AGENT_TMUX_SOCKET": Self.ownSocketName,
                AgentMirrorRequest.directoryVariable: requests.path,
                "LIMPID_PANE_ID": "547D688D-39DF-4A06-BD6F-316C3385532C",
                "LIMPID_AGENT_HOOK_BACKEND": "rust"
            ]
            try process.run()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            func argv(_ url: URL) -> [String] {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return text.split(separator: "\0").map(String.init)
            }
            let written = ((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            return HostedRun(
                tmux: argv(tmuxArgv),
                claude: argv(claudeArgv),
                status: process.terminationStatus,
                output: (String(bytes: printed, encoding: .utf8) ?? "").replacingOccurrences(of: "\r", with: ""),
                errors: (try? String(contentsOf: errorFile, encoding: .utf8)) ?? "",
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

    /// The hooks are the reason the shim exists, so they have to survive
    /// being handed to tmux rather than exec'd directly. tmux runs
    /// multiple arguments as an argv, which is what keeps the settings
    /// JSON — quotes, braces and all — out of a shell.
    @Test("keeps our settings flag when the agent is hosted in tmux")
    func hostedInvocation_stillCarriesTheSettingsFlag() throws {
        let handover = try runShimHosted([])
        #expect(handover.claude.isEmpty)
        #expect(handover.tmux.prefix(5) == ["-L", Self.ownSocketName, "-u", "-f", "/dev/null"])
        #expect(handover.tmux.contains("new-session"))
        #expect(handover.tmux.contains("-d"))
        #expect(handover.tmux.contains { $0.hasPrefix("LIMPID_AGENT_RUN_ID=") })
        #expect(handover.tmux.contains("LIMPID_AGENT_TMUX_HOST_MODE=limpidHosted"))
        // The hook backend is fixed per pane and must reach the hooks that
        // run inside the tmux session, not only the shell that chose it.
        #expect(handover.tmux.contains("LIMPID_AGENT_HOOK_BACKEND=rust"))
        let settings = try #require(handover.tmux.firstIndex(of: "--settings"))
        // Directly after `/usr/bin/env` comes the agent, then our flag.
        #expect(handover.tmux[settings - 2] == "/usr/bin/env")
        let payload = try JSONSerialization.jsonObject(
            with: Data(handover.tmux[settings + 1].utf8)
        ) as? [String: Any]
        #expect(payload?["hooks"] != nil)
    }

    /// The tab is opened from this file alone, so a Claude launch has to
    /// leave one Limpid accepts, naming Claude as its provider.
    @Test("asks Limpid for a tab on the session it created")
    func hostedInvocation_writesAValidRequest() throws {
        let handover = try runShimHosted([])
        #expect(handover.status == 0)
        #expect(handover.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Opened in a Limpid tab.")
        let data = try #require(handover.request)
        let request = try AgentMirrorRequest.parse(data, ownSocketPath: Self.ownSocketPath)
        #expect(request.provider == .claude)
        #expect(request.launchPaneID == UUID(uuidString: "547D688D-39DF-4A06-BD6F-316C3385532C"))
        // The agent is given the mirror leaf's id, not the launching pane's.
        let passed = try #require(handover.tmux.first { $0.hasPrefix("LIMPID_PANE_ID=") })
        #expect(passed == "LIMPID_PANE_ID=\(request.leafID.uuidString)")
    }

    /// An agent that ran where the user cannot see it is the failure that
    /// is hard to notice, so a launch that cannot be shown does not happen.
    @Test("fails loudly when tmux cannot create the session")
    func hostedInvocation_tmuxFailure_exitsNonZero() throws {
        let handover = try runShimHosted([], tmuxFails: true)
        #expect(handover.status != 0)
        #expect(handover.errors.contains("limpid:"))
        #expect(handover.request == nil)
        #expect(handover.claude.isEmpty)
    }

    /// `--bg` prints a session id and returns, so hosting it would put
    /// that id on a screen tmux erases on the way out. The decision rule
    /// itself is shared with the Codex shim and pinned there.
    @Test(
        "runs a one-shot invocation directly even when hosting is on",
        arguments: [["--version"], ["--bg", "do a thing"]]
    )
    func hostedInvocation_leavesOneShotsAlone(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.tmux.isEmpty)
        #expect(handover.claude.contains(args[0]))
    }

    /// `--resume` is one of the two ways back into an existing session,
    /// so it is on the allow list even though it carries arguments.
    @Test("hosts a resume")
    func hostedInvocation_hostsAResume() throws {
        let handover = try runShimHosted(["--resume", "abc123"])
        #expect(handover.claude.isEmpty)
        #expect(handover.tmux.suffix(2) == ["--resume", "abc123"])
    }
}
