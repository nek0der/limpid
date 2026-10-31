// StatusLineRelayTests.swift
// Weir — the Hook Helper's status line relay and the shim that installs it, run for real.
//
// The relay sits between Claude Code and the person's own status line. What
// they see must not change, so these pin that their command gets the very
// bytes Claude Code wrote and its output comes back as it was, while the
// plan usage lands where the usage panel reads it.

import Foundation
import Testing
@testable import Weir

@Suite(
    "Status line relay",
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(1))
)
struct StatusLineRelayTests {
    private let input = Data(#"""
    {"model":{"display_name":"Opus"},"workspace":{"project_dir":"/nonexistent/project"},
     "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1793247600},
                    "seven_day":{"used_percentage":83,"resets_at":1793822400}}}
    """#.utf8)

    /// What one helper run printed and how it exited.
    private struct HelperRun {
        let status: Int32
        let stdout: Data
    }

    /// Runs the helper with `arguments`, `stdin` as its input, in `dir`. The
    /// output is a line or two, well inside a pipe's buffer, so it is read
    /// once the helper has exited.
    private func runHelper(
        _ arguments: [String],
        stdin: Data,
        environment: [String: String],
        in dir: URL
    ) throws -> HelperRun {
        let inputFile = dir.appendingPathComponent("stdin.json")
        try stdin.write(to: inputFile)
        let process = Process()
        process.executableURL = HookHelperFixture.helperURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = dir
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        #expect(process.waitUntilExit(within: 10), "the helper did not exit within ten seconds")
        try? output.fileHandleForWriting.close()
        let stdout = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        return HelperRun(status: process.terminationStatus, stdout: stdout)
    }

    private func environment(in dir: URL) -> [String: String] {
        [
            "PATH": ShimHarness.systemPath,
            "HOME": dir.path,
            "TMPDIR": dir.path,
            "CLAUDE_CONFIG_DIR": dir.appendingPathComponent("config").path,
            "WEIR_USAGE_DIR": dir.appendingPathComponent("usage").path
        ]
    }

    private func writeUserSettings(_ settings: [String: Any], in dir: URL) throws {
        let config = dir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appendingPathComponent("settings.json"))
    }

    @Test("runs the person's status line on the same input and keeps the usage")
    func relay_handsTheInputOnAndKeepsTheUsage() throws {
        try withTempDir { dir in
            // `cat` echoes what it was given, so the output shows the input
            // reached it byte for byte.
            try writeUserSettings(["statusLine": ["type": "command", "command": "printf 'mine:'; cat"]], in: dir)
            let output = try runHelper(["statusline", "claude"], stdin: input, environment: environment(in: dir), in: dir)

            #expect(output.status == 0)
            #expect(output.stdout == Data("mine:".utf8) + input)
            let record = try Data(contentsOf: PlanUsageRecordDirectory.recordURL(
                for: .claude,
                in: dir.appendingPathComponent("usage")
            ))
            let usage = try PlanUsage.decode(record)
            #expect(usage.windows.map(\.kind) == [PlanUsageWindow.fiveHour, PlanUsageWindow.sevenDay])
            #expect(usage.windows.map(\.usedPercent) == [42, 83])
        }
    }

    @Test("prints nothing when the person has no status line of their own")
    func relay_withoutAStatusLine_printsNothing() throws {
        try withTempDir { dir in
            let output = try runHelper(["statusline", "claude"], stdin: input, environment: environment(in: dir), in: dir)
            #expect(output.status == 0)
            #expect(output.stdout.isEmpty)
        }
    }

    @Test("passes on the person's exit status")
    func relay_passesOnTheExitStatus() throws {
        try withTempDir { dir in
            try writeUserSettings(["statusLine": ["type": "command", "command": "echo shown; exit 3"]], in: dir)
            let output = try runHelper(["statusline", "claude"], stdin: input, environment: environment(in: dir), in: dir)
            #expect(output.status == 3)
            #expect(output.stdout == Data("shown\n".utf8))
        }
    }

    @Test("writes the relay into the settings with the person's options")
    func settings_carryThePersonsOptions() throws {
        try withTempDir { dir in
            try writeUserSettings(["statusLine": ["type": "command", "command": "mine.sh", "padding": 0]], in: dir)
            let document = try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": []]])
            let output = try runHelper(
                ["statusline", "claude", "settings", "/links/helper statusline claude"],
                stdin: document,
                environment: environment(in: dir),
                in: dir
            )
            #expect(output.status == 0)
            let settings = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
            #expect(settings["hooks"] != nil)
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            #expect(statusLine["command"] as? String == "/links/helper statusline claude")
            #expect(statusLine["padding"] as? Int == 0)
        }
    }

    @Test("leaves the status line slot empty when the person has none")
    func settings_withoutAStatusLine_leaveTheSlotEmpty() throws {
        try withTempDir { dir in
            let document = Data(#"{"hooks":{}}"#.utf8)
            let output = try runHelper(
                ["statusline", "claude", "settings", "/links/helper statusline claude"],
                stdin: document,
                environment: environment(in: dir),
                in: dir
            )
            #expect(output.status == 0)
            #expect(output.stdout == document)
        }
    }

    @Test("leaves the settings alone when they are not a document")
    func settings_unreadable_failWithoutOutput() throws {
        try withTempDir { dir in
            let output = try runHelper(
                ["statusline", "claude", "settings", "/links/helper statusline claude"],
                stdin: Data("not json".utf8),
                environment: environment(in: dir),
                in: dir
            )
            #expect(output.status != 0)
            #expect(output.stdout.isEmpty)
        }
    }
}

@Suite(
    "Claude shim status line",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(1))
)
struct ClaudeShimStatusLineTests {
    /// The shim run from a bundle's layout, which it needs to find the
    /// helper (`Contents/MacOS` beside `Contents/Resources`), with a stub in
    /// place of the real claude. Returns the settings it passed.
    private func shimSettings(
        _ arguments: [String],
        userStatusLine: [String: Any]? = nil,
        in dir: URL
    ) throws -> [String: Any] {
        if let userStatusLine {
            let config = dir.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["statusLine": userStatusLine])
                .write(to: config.appendingPathComponent("settings.json"))
        }
        let contents = dir.appendingPathComponent("Weir.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let shimFolder = resources.appendingPathComponent("claude-shim")
        let macOS = contents.appendingPathComponent("MacOS")
        let fileManager = FileManager.default
        for folder in [shimFolder, resources.appendingPathComponent("agent-shim"), macOS] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = try ShimHarness.shim("claude").deletingLastPathComponent()
        for name in ["claude", "weir-hook"] {
            try fileManager.copyItem(at: source.appendingPathComponent(name), to: shimFolder.appendingPathComponent(name))
        }
        try fileManager.copyItem(
            at: source.deletingLastPathComponent().appendingPathComponent("agent-shim/runtime-common.sh"),
            to: resources.appendingPathComponent("agent-shim/runtime-common.sh")
        )
        try fileManager.createSymbolicLink(
            at: macOS.appendingPathComponent("AgentIntegrationHookHelper"),
            withDestinationURL: #require(HookHelperFixture.helperURL)
        )

        let argvFile = dir.appendingPathComponent("argv.txt")
        let stub = dir.appendingPathComponent("fake-claude")
        try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile), at: stub)
        var environment = ShimHarness.environment(in: dir)
        environment["WEIR_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
        environment["WEIR_REAL_CLAUDE"] = stub.path
        environment["CLAUDE_CONFIG_DIR"] = dir.appendingPathComponent("config").path
        let process = try ShimHarness.run(
            shimFolder.appendingPathComponent("claude"),
            arguments,
            environment: environment,
            currentDirectory: dir
        )
        #expect(process.terminationStatus == 0)

        let argv = try #require(ShimHarness.recordedArgv(argvFile))
        let flag = try #require(argv.firstIndex(of: "--settings"))
        #expect(argv.count(where: { $0 == "--settings" }) == 1)
        let data = Data(argv[flag + 1].utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The relay's arguments as the Rust side recognizes its own relay by
    /// them (`rust/fixtures/contract/shared-values.json`).
    private static func relayArguments() throws -> String {
        let root = try #require(RepoFixture.weirRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("rust/fixtures/contract/shared-values.json"))
        let shared = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(shared["claudeStatusLineRelayArguments"] as? String)
    }

    @Test("puts the relay in the status line slot beside the hooks")
    func shim_installsTheRelay() throws {
        try withTempDir { dir in
            let settings = try shimSettings([], userStatusLine: ["type": "command", "command": "mine.sh"], in: dir)
            #expect(settings["hooks"] != nil)
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            let command = try #require(statusLine["command"] as? String)
            #expect(try command.hasSuffix("/AgentIntegrationHookHelper \(Self.relayArguments())"))
            #expect(!command.contains(" Weir.app"))
        }
    }

    @Test("leaves the slot empty when the person has no status line")
    func shim_withoutAStatusLine_setsNone() throws {
        try withTempDir { dir in
            let settings = try shimSettings([], in: dir)
            #expect(settings["hooks"] != nil)
            #expect(settings["statusLine"] == nil)
        }
    }

    @Test("keeps the relay when the person passes a status line of their own")
    func shim_userSettings_keepTheRelay() throws {
        try withTempDir { dir in
            let theirs = #"{"statusLine":{"type":"command","command":"theirs.sh","padding":2}}"#
            let settings = try shimSettings(["--settings", theirs], in: dir)
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            #expect(try (statusLine["command"] as? String)?.hasSuffix(" \(Self.relayArguments())") == true)
            // Their options carry over; their command runs inside the relay.
            #expect(statusLine["padding"] as? Int == 2)
        }
    }
}
