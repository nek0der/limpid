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

@Suite("Claude shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"), .timeLimit(.minutes(1)))
struct ClaudeShimScriptTests {
    /// Run the shim with `args` and return the argv the real claude would
    /// have been exec'd with.
    private func runShim(
        _ args: [String],
        hookNamespace: String? = nil,
        setsTemporaryDirectory: Bool = true,
        prepareTemporaryDirectory: (URL) throws -> Void = { _ in },
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String] {
        try withTempDir { dir in
            try prepareTemporaryDirectory(dir)
            let stub = dir.appendingPathComponent("fake-claude")
            // The settings payload is pretty-printed JSON, which is why the
            // argv is recorded NUL-separated.
            let argvFile = dir.appendingPathComponent("argv.txt")
            try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile), at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["LIMPID_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
            environment["LIMPID_REAL_CLAUDE"] = stub.path
            environment["LIMPID_CLAUDE_HOOK_NAMESPACE"] = hookNamespace
            if !setsTemporaryDirectory {
                environment["TMPDIR"] = nil
            }
            let process = try ShimHarness.run(ShimHarness.shim("claude"), args, environment: environment)
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            return ShimHarness.recordedArgv(argvFile) ?? []
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

    /// A link folder someone else put in place (here a link to another
    /// folder) is not used: the hooks Claude runs would be whatever that
    /// folder holds. The shim falls back to the hooks' own paths.
    @Test func hookLink_refusesAFolderThatIsALink() throws {
        try withTempDir { elsewhere in
            let argv = try runShim([], hookNamespace: "planted") { dir in
                try FileManager.default.createSymbolicLink(
                    at: dir.appendingPathComponent("limpid-claude-shim-planted"),
                    withDestinationURL: elsewhere
                )
            }
            let command = try sessionStartCommand(argv)
            #expect(!command.contains("limpid-claude-shim-planted"))
            #expect(command.hasSuffix("/claude-shim/limpid-hook"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }

    /// Without TMPDIR (an ssh login, a tmux server started with a stripped
    /// environment) the links go to the folder macOS keeps for this user,
    /// not to a shared /tmp.
    @Test func hookLink_withoutTMPDIR_usesTheUsersOwnTemporaryFolder() throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        try #require(length > 0)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let userTemporary = try #require(String(bytes: bytes, encoding: .utf8))
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let namespace = "test-\(UUID().uuidString)"
        let linkFolder = URL(fileURLWithPath: userTemporary).appendingPathComponent("limpid-claude-shim-\(namespace)")
        defer { try? FileManager.default.removeItem(at: linkFolder) }

        let argv = try runShim([], hookNamespace: namespace, setsTemporaryDirectory: false)
        let command = try sessionStartCommand(argv)

        #expect(command == linkFolder.appendingPathComponent("limpid-hook").path)
        #expect(!command.hasPrefix("/tmp/"))
        let mode = try FileManager.default.attributesOfItem(atPath: linkFolder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
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

    @Test("leaves Claude's status reports on: sets no title switch of its own")
    func terminalTitleSwitch_isLeftUnset() throws {
        try withTempDir { dir in
            let stub = dir.appendingPathComponent("fake-claude")
            // The switch also turns off Claude's OSC 7501 reports, which the
            // projection reads (`PaneProgramStatusStore`).
            try ShimHarness.writeExecutable("""
            #!/bin/sh
            [ -z "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE+set}" ]
            """, at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["LIMPID_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
            environment["LIMPID_REAL_CLAUDE"] = stub.path
            environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_TERMINAL_TITLE")
            let process = try ShimHarness.run(ShimHarness.shim("claude"), [], environment: environment)

            #expect(process.terminationStatus == 0)
        }
    }

    /// Runs the shim under a pty with tmux hosting switched on, and
    /// returns the argv tmux was handed. The hosting decision asks
    /// whether stdin and stdout are terminals, and the harness above runs
    /// the shim on the null device, so it can never reach this branch. The rule
    /// is shared (`limpid_should_host_in_tmux` in `runtime-common.sh`), but
    /// each shim hands it its own lists, so Claude's are pinned here as
    /// Codex's are in its suite; what is Claude's alone besides is that
    /// our `--settings` survives the wrap.
    /// `underPTY: false` is the launch whose output is not a terminal.
    /// `files`, when given, are written into the temporary folder, and the
    /// shim then runs there, so a relative path in `args` or `environment`
    /// names one of them.
    private func runShimHosted(
        _ args: [String],
        environment: [String: String] = [:],
        files: [String: String] = [:],
        underPTY: Bool = true
    ) throws -> HostedRun {
        try withTempDir { dir in
            for (name, contents) in files {
                try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let claudeArgv = dir.appendingPathComponent("claude.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            let claudeStub = dir.appendingPathComponent("fake-claude")
            let tmuxStub = dir.appendingPathComponent("fake-tmux")
            for (stub, argvFile) in [(claudeStub, claudeArgv), (tmuxStub, tmuxArgv)] {
                // Beside the argv, what the stub saw of the sheet's executable.
                try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile, then: """
                printf '%s' "${LIMPID_FOUND_CLAUDE-unset}" > "\(argvFile.path).found"
                printf '%s' "${LIMPID_AGENT_TMUX_HOST_MODE-unset}" > "\(argvFile.path).mode"
                exit 0
                """), at: stub)
            }

            var shimEnvironment = ShimHarness.environment(in: dir)
            try shimEnvironment.merge([
                "LIMPID_CLAUDE_SETTINGS_TEMPLATE": ShimHarness.claudeSettingsTemplate(),
                "LIMPID_REAL_CLAUDE": claudeStub.path,
                "LIMPID_AGENT_TMUX": tmuxStub.path,
                "LIMPID_AGENT_TMUX_SOCKET": "limpid-test.socket",
                "LIMPID_PANE_ID": "547D688D-39DF-4A06-BD6F-316C3385532C"
            ]) { _, new in new }
            shimEnvironment.merge(environment) { _, new in new }
            try ShimHarness.run(
                ShimHarness.shim("claude"),
                args,
                environment: shimEnvironment,
                underPTY: underPTY,
                currentDirectory: files.isEmpty ? nil : dir
            )

            func argv(_ url: URL) -> [String] {
                ShimHarness.recordedArgv(url) ?? []
            }
            return HostedRun(
                tmux: argv(tmuxArgv),
                claude: argv(claudeArgv),
                tmuxSawFound: try? String(contentsOfFile: tmuxArgv.path + ".found", encoding: .utf8),
                claudeSawMode: try? String(contentsOfFile: claudeArgv.path + ".mode", encoding: .utf8)
            )
        }
    }

    /// What `runShimHosted` saw: the argv tmux and the agent were each
    /// handed (empty for the one that did not run), and what tmux saw of
    /// `LIMPID_FOUND_CLAUDE` (`unset` when it had none), and the host mode
    /// a Claude run directly was handed (`unset` when it had none).
    private struct HostedRun {
        let tmux: [String]
        let claude: [String]
        let tmuxSawFound: String?
        let claudeSawMode: String?

        /// Claude ran directly, with our settings and then the user's
        /// arguments.
        func ranDirectly(_ args: [String]) -> Bool {
            tmux.isEmpty && claude.contains("--settings") && claude.suffix(args.count) == args[...]
        }
    }

    /// The hooks are the reason the shim exists, so they have to survive
    /// being handed to tmux rather than exec'd directly. tmux runs
    /// multiple arguments as an argv, which is what keeps the settings
    /// JSON — quotes, braces and all — out of a shell.
    @Test("keeps our settings flag when the agent is hosted in tmux")
    func hostedInvocation_stillCarriesTheSettingsFlag() throws {
        let handover = try runShimHosted([])
        #expect(handover.claude.isEmpty)
        #expect(handover.tmux.prefix(4) == ["-L", "limpid-test.socket", "-f", "/dev/null"])
        #expect(handover.tmux.contains { $0.hasPrefix("LIMPID_AGENT_RUN_ID=") })
        #expect(handover.tmux.contains("LIMPID_AGENT_TMUX_HOST_MODE=limpidHosted"))
        let settings = try #require(handover.tmux.firstIndex(of: "--settings"))
        // After `/usr/bin/env` and the `-u NAME` of each variable the pane
        // does not set comes the agent, then our flag.
        let env = try #require(handover.tmux.lastIndex(of: "/usr/bin/env"))
        let unsets = handover.tmux[(env + 1)..<(settings - 1)]
        #expect(unsets.count.isMultiple(of: 2))
        #expect(stride(from: unsets.startIndex, to: unsets.endIndex, by: 2).allSatisfy { handover.tmux[$0] == "-u" })
        let payload = try JSONSerialization.jsonObject(
            with: Data(handover.tmux[settings + 1].utf8)
        ) as? [String: Any]
        #expect(payload?["hooks"] != nil)
    }

    /// `--bg` prints a session id and returns, so hosting it would put
    /// that id on a screen tmux erases on the way out.
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

    /// A server already running would otherwise start the agent on the
    /// `PATH` of the pane that started the server (`CodexShimScriptTests`
    /// pins what the agent's folder adds to it). The stub comes through
    /// `LIMPID_REAL_CLAUDE`, an override that leaves the `PATH` as it was.
    @Test("passes the pane's PATH into tmux")
    func hostedInvocation_passesThePanesPath() throws {
        let handover = try runShimHosted([])
        #expect(zip(handover.tmux, handover.tmux.dropFirst()).contains { $0 == "-e" && $1 == "PATH=/usr/bin:/bin:/usr/sbin:/sbin" })
    }

    /// What the new workspace sheet found stays with the pane's shell: a
    /// tmux server started with it would hand it to every session after.
    /// Neither the tmux client nor its `-e` list has it.
    @Test("keeps what the sheet found out of tmux")
    func hostedInvocation_keepsTheSheetsExecutableOutOfTmux() throws {
        let handover = try runShimHosted([], environment: ["LIMPID_FOUND_CLAUDE": "/opt/tools/bin/claude"])
        #expect(!handover.tmux.isEmpty)
        #expect(handover.tmuxSawFound == "unset")
        #expect(!handover.tmux.contains { $0.hasPrefix("LIMPID_FOUND_") })
    }

    /// A tmux session starts in a folder of its own, so a relative value
    /// would name another folder there, and one left out would be the tmux
    /// server's, the first pane's account rather than this pane's.
    @Test("passes the pane's Claude account into tmux, made absolute")
    func hostedLaunch_passesTheAccountMadeAbsolute() throws {
        let handover = try runShimHosted(
            [],
            environment: ["CLAUDE_CONFIG_DIR": "relative/config"],
            files: ["placeholder": ""]
        )
        let value = try #require(handover.tmux.first { $0.hasPrefix("CLAUDE_CONFIG_DIR=") })
        #expect(value.hasPrefix("CLAUDE_CONFIG_DIR=/"))
        #expect(value.hasSuffix("/relative/config"))

        let unset = try runShimHosted([])
        #expect(zip(unset.tmux, unset.tmux.dropFirst()).contains { $0 == ("-u", "CLAUDE_CONFIG_DIR") })
    }

    /// The status line relay finds the person's own status line in the
    /// settings they launched with, which our flag replaced.
    @Test("passes the person's settings into tmux for the status line relay")
    func hostedLaunch_passesThePersonsSettings() throws {
        let file = try runShimHosted(
            ["--resume", "abc", "--settings", "mine.json"],
            files: ["mine.json": #"{"model":"opus"}"#]
        )
        let value = try #require(file.tmux.first { $0.hasPrefix("LIMPID_CLAUDE_USER_SETTINGS=") })
        #expect(value.hasPrefix("LIMPID_CLAUDE_USER_SETTINGS=/"))
        #expect(value.hasSuffix("/mine.json"))

        // Inline JSON is passed as written, blanks before it included, and
        // merged as JSON rather than read as a file of that name.
        let inline = "  \n {\"model\":\"opus\"}"
        let handover = try runShimHosted(["--resume", "abc", "--settings", inline])
        #expect(handover.tmux.contains("LIMPID_CLAUDE_USER_SETTINGS=\(inline)"))
        let settings = try #require(handover.tmux.firstIndex(of: "--settings"))
        let payload = try JSONSerialization.jsonObject(with: Data(handover.tmux[settings + 1].utf8)) as? [String: Any]
        #expect(payload?["model"] as? String == "opus")
        #expect(payload?["hooks"] != nil)
    }

    @Test("passes an emptied record directory into tmux as empty")
    func hostedLaunch_passesEmptyRecordDirectories() throws {
        // A demo pane empties them; left out, the session would take the
        // tmux server's values, which are another build's directories.
        let handover = try runShimHosted([], environment: [
            "LIMPID_AGENT_STATES_DIR": "",
            "LIMPID_SESSIONS_DIR": ""
        ])
        #expect(handover.tmux.contains("LIMPID_AGENT_STATES_DIR="))
        #expect(handover.tmux.contains("LIMPID_SESSIONS_DIR="))
        // An unset one stays unset: not passed, and taken out of what the
        // session would take from the server.
        #expect(!handover.tmux.contains { $0.hasPrefix("LIMPID_CWD_EVENTS_DIR=") })
        #expect(zip(handover.tmux, handover.tmux.dropFirst()).contains { $0 == ("-u", "LIMPID_CWD_EVENTS_DIR") })
    }

    /// The rest of Claude's allow list: a bare launch, and each spelling
    /// of the two ways back into a session.
    @Test("hosts each interactive entry point", arguments: [[], ["-r"], ["--resume"], ["-c"], ["--continue"]])
    func hostedInvocation_hostsTheInteractiveEntryPoints(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.claude.isEmpty)
        #expect(handover.tmux.contains("new-session"))
        #expect(handover.tmux.suffix(args.count) == args[...])
    }

    /// A prompt and a subcommand look alike, and a flag the list does not
    /// name may come before either, so whatever does not start with an
    /// entry point runs directly; so does a one-shot flag anywhere, even
    /// after an entry point.
    @Test("runs anything it does not recognize directly", arguments: [
        ["fix the failing test"], ["mcp", "list"], ["--model", "opus"],
        ["-p", "hi"], ["--resume", "abc123", "--print"], ["-c", "-h"]
    ])
    func hostedInvocation_runsWhatItDoesNotRecognizeDirectly(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.ranDirectly(args))
    }

    /// Inside a session our folder is still on the PATH, so wrapping again
    /// would nest without bound. The tmux is then the person's own, which
    /// the host mode says, so a resume asks that tmux for its pane.
    @Test("does not wrap again once inside tmux, and names the tmux the person's")
    func insideTmux_handsOffDirectly_asManual() throws {
        let handover = try runShimHosted([], environment: ["TMUX": "/tmp/tmux-501/default,4242,0"])
        #expect(handover.ranDirectly([]))
        #expect(handover.claudeSawMode == "manual")
    }

    /// Hosting off, or a pane Limpid did not name, leaves no host mode at
    /// all: neither ours nor the person's.
    @Test("does not host without a pane id or a tmux to run", arguments: [
        ["LIMPID_PANE_ID": ""],
        ["LIMPID_AGENT_TMUX": ""],
        ["LIMPID_AGENT_TMUX": "/nonexistent/tmux"]
    ])
    func withoutPaneIDOrTmux_handsOffDirectly(_ environment: [String: String]) throws {
        let handover = try runShimHosted([], environment: environment)
        #expect(handover.ranDirectly([]))
        #expect(handover.claudeSawMode == "unset")
    }

    /// Output that is not a terminal is output someone means to keep,
    /// which a tmux client would take to a screen it erases.
    @Test("runs directly when its output is not a terminal")
    func withoutATerminal_handsOffDirectly() throws {
        let handover = try runShimHosted([], underPTY: false)
        #expect(handover.ranDirectly([]))
    }
}
