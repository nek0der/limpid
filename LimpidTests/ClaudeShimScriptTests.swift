// ClaudeShimScriptTests.swift
// Limpid — drives `claude-shim/claude` with `LIMPID_REAL_CLAUDE` pointed at
// a stub that records its argv, the only way to see what the shim decided
// Claude should receive. `--settings` overwrites rather than merges, so the
// shim has to fold a user-supplied one into its own and pass a single flag;
// these pin that it does, in both spellings and for a file as well as
// inline JSON.

import Foundation
import Testing

@Suite("Claude shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct ClaudeShimScriptTests {
    /// Run the shim with `args` and return the argv the real claude would
    /// have been exec'd with.
    private func runShim(
        _ args: [String],
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
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_REAL_CLAUDE": stub.path
            ]
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

    @Test("injects our settings when the user passes none")
    func noUserSettings_injectsOurs() throws {
        let argv = try runShim([])
        let payload = try settingsPayload(in: argv)
        #expect(sessionStartGroups(payload).count == 1)
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
                "LIMPID_REAL_CLAUDE": stub.path,
                "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "0"
            ]
            try process.run()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)
        }
    }

    /// Runs the shim under a pty with tmux hosting switched on, and
    /// returns the argv tmux was handed. The hosting decision asks
    /// whether stdin and stdout are terminals, and a `Process` pipe is
    /// not one, so the harness above can never reach this branch. The
    /// decision itself is shared with the Codex shim and pinned there;
    /// what is Claude's own is that our `--settings` survives the wrap.
    private func runShimHosted(_ args: [String]) throws -> (tmux: [String], claude: [String]) {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/claude-shim/claude")
            let claudeArgv = dir.appendingPathComponent("claude.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            let claudeStub = dir.appendingPathComponent("fake-claude")
            let tmuxStub = dir.appendingPathComponent("fake-tmux")
            for (stub, argvFile) in [(claudeStub, claudeArgv), (tmuxStub, tmuxArgv)] {
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
                "LIMPID_REAL_CLAUDE": claudeStub.path,
                "LIMPID_AGENT_TMUX": tmuxStub.path,
                "LIMPID_AGENT_TMUX_SOCKET": "limpid-test.socket",
                "LIMPID_PANE_ID": "547D688D-39DF-4A06-BD6F-316C3385532C"
            ]
            try process.run()
            process.waitUntilExit()

            func argv(_ url: URL) -> [String] {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return text.split(separator: "\0").map(String.init)
            }
            return (argv(tmuxArgv), argv(claudeArgv))
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
        // Directly after `/usr/bin/env` comes the agent, then our flag.
        #expect(handover.tmux[settings - 2] == "/usr/bin/env")
        let payload = try JSONSerialization.jsonObject(
            with: Data(handover.tmux[settings + 1].utf8)
        ) as? [String: Any]
        #expect(payload?["hooks"] != nil)
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
