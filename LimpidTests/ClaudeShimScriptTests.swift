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
}
