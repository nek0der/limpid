// HookHelperLifecycleTests.swift
// Limpid — runs the bundled Hook Helper's `hook` subcommand end to end,
// one smoke case per provider, against a scratch state directory.

import Foundation
import Testing
@testable import Limpid

@Suite(
    "Hook Helper lifecycle",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host")
)
struct HookHelperLifecycleTests {
    private static let paneID = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10"
    private static let runID = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"

    private func fixturePayload(_ provider: String, _ name: String) throws -> Data {
        let root = try #require(RepoFixture.limpidRoot)
        return try Data(contentsOf: root
            .appendingPathComponent("rust/fixtures/\(provider)/2026-09/session-basic/\(name)"))
    }

    private func environment(provider: String, in directory: URL) -> [String: String] {
        let prefix = provider == "claude" ? "LIMPID" : "LIMPID_CODEX"
        var env = IsolatedProcessEnvironment.make([
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": directory.path,
            "LIMPID_PANE_ID": Self.paneID,
            "LIMPID_AGENT_RUN_ID": Self.runID,
            "LIMPID_TURN_SNAPSHOT": "0",
            "LIMPID_HOOK_LOG": directory.appendingPathComponent("hook.log").path,
            "\(prefix)_AGENT_STATES_DIR": directory.appendingPathComponent("states").path,
            "\(prefix)_SESSIONS_DIR": directory.appendingPathComponent("sessions").path
        ])
        if provider == "claude" {
            env["LIMPID_CWD_EVENTS_DIR"] = directory.appendingPathComponent("cwd").path
        }
        return env
    }

    @discardableResult
    private func runHelper(
        _ arguments: [String],
        payload: Data,
        environment: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let helper = try #require(HookHelperFixture.helperURL)
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: payload)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }

    private func record(in directory: URL) throws -> [String: Any]? {
        let url = directory.appendingPathComponent("states/\(Self.runID).state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Decode a file the Rust runtime wrote through the very decoder the
    /// Swift stores use. The dictionary assertions above only prove the
    /// JSON says what we expect; running it through the reader is what
    /// catches a field whose Rust shape no longer satisfies the Swift
    /// model, which otherwise surfaces as a badge that silently stops
    /// updating.
    private func decoded<Record: Decodable>(
        _: Record.Type,
        at url: URL
    ) throws -> Record {
        try PersistenceCoders.makeDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    @Test("writes a version 3 record without opening the approval service", arguments: ["claude", "codex"])
    func lifecycleHook_writesTheRecord(provider: String) throws {
        try withTempDir { directory in
            let env = environment(provider: provider, in: directory)
            for name in ["0000-SessionStart.json", "0001-UserPromptSubmit.json"] {
                let result = try runHelper(["hook", provider], payload: fixturePayload(provider, name), environment: env)
                #expect(result.status == 0)
                #expect(result.stderr.isEmpty)
            }
            let record = try #require(try record(in: directory))
            #expect(record["schemaVersion"] as? Int == 3)
            #expect(record["state"] as? String == "running")
            #expect(record["revision"] as? Int == 2)
            #expect(record["runId"] as? String == Self.runID)
            #expect(record["paneId"] as? String == Self.paneID)
            #expect(record["firstPrompt"] != nil)
            let hint = directory.appendingPathComponent("sessions/\(Self.paneID).json")
            #expect(FileManager.default.fileExists(atPath: hint.path))
            let recordURL = directory.appendingPathComponent("states/\(Self.runID).state.json")
            // The two providers have separate models, so each one has to be
            // decoded as itself rather than through a shared protocol.
            if provider == "claude" {
                let typed = try decoded(ClaudeAgentStateRecord.self, at: recordURL)
                #expect(typed.schemaVersion == 3)
                #expect(typed.state == "running")
                #expect(typed.runId == Self.runID)
                #expect(typed.paneId == Self.paneID)
                #expect(typed.revision == 2)
                #expect(typed.firstPrompt?.isEmpty == false)
                // The pid comes from an ancestor walk that finds nothing
                // under the test host, so we only pin its encoding.
                #expect(typed.pid.map { $0.allSatisfy(\.isNumber) } != false)
                let session = try decoded(ClaudeSessionRecord.self, at: hint)
                #expect(session.paneId == Self.paneID)
                #expect(session.sessionId.isEmpty == false)
                #expect(session.runId == Self.runID)
            } else {
                let typed = try decoded(CodexAgentStateRecord.self, at: recordURL)
                #expect(typed.schemaVersion == 3)
                #expect(typed.state == "running")
                #expect(typed.runId == Self.runID)
                #expect(typed.paneId == Self.paneID)
                #expect(typed.revision == 2)
                #expect(typed.firstPrompt?.isEmpty == false)
                #expect(typed.pid.map { $0.allSatisfy(\.isNumber) } != false)
                let session = try decoded(CodexSessionRecord.self, at: hint)
                #expect(session.paneId == Self.paneID)
                #expect(session.sessionId.isEmpty == false)
                #expect(session.runId == Self.runID)
            }
            #expect((try? String(contentsOf: directory.appendingPathComponent("hook.log"), encoding: .utf8)) == nil)
        }
    }

    @Test("skips the write while the Swift store holds the record lock")
    func lifecycleHook_yieldsToTheSwiftLock() throws {
        try withTempDir { directory in
            let env = environment(provider: "claude", in: directory)
            let states = directory.appendingPathComponent("states")
            try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
            let recordURL = states.appendingPathComponent("\(Self.runID).state.json")
            let outcome = try AgentFileLock.withLock(for: recordURL) {
                let payload = try fixturePayload("claude", "0000-SessionStart.json")
                let result = try runHelper(["hook", "claude"], payload: payload, environment: env)
                #expect(result.status == 0)
                return .applied
            }
            #expect(outcome == .applied)
            #expect(try record(in: directory) == nil)
            let log = try String(contentsOf: directory.appendingPathComponent("hook.log"), encoding: .utf8)
            #expect(log.contains("record lock busy"))
        }
    }

    @Test("passes a plain tool call through the worktree hook with exit 0")
    func worktreeHook_passesThroughOrdinaryCommands() throws {
        try withTempDir { directory in
            let env = environment(provider: "claude", in: directory)
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": ["command": "ls -la"]
            ])
            let result = try runHelper(["hook", "claude", "worktree"], payload: payload, environment: env)
            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try record(in: directory) == nil)
        }
    }

    @Test("writes nothing outside a Limpid pane")
    func lifecycleHook_writesNothingWithoutTheShimEnvironment() throws {
        try withTempDir { directory in
            let env = IsolatedProcessEnvironment.make(["PATH": "/usr/bin:/bin", "HOME": directory.path])
            let result = try runHelper(["hook", "codex"], payload: fixturePayload("codex", "0000-SessionStart.json"), environment: env)
            #expect(result.status == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }
}
