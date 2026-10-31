// HookHelperLifecycleTests.swift
// Weir — runs the bundled Hook Helper's `hook` subcommand end to end,
// one smoke case per provider, against a scratch state directory.

import Foundation
import Testing
@testable import Weir

@Suite(
    "Hook Helper lifecycle",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(1))
)
struct HookHelperLifecycleTests {
    private static let paneID = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10"
    private static let runID = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"

    private func fixturePayload(_ provider: String, _ name: String) throws -> Data {
        let root = try #require(RepoFixture.weirRoot)
        return try Data(contentsOf: root
            .appendingPathComponent("rust/fixtures/\(provider)/2026-09/session-basic/\(name)"))
    }

    private func environment(_ agent: HookAgent, in directory: URL) -> [String: String] {
        var env = agent.environment(in: directory, paneID: Self.paneID)
        env["WEIR_AGENT_RUN_ID"] = Self.runID
        env["WEIR_TURN_SNAPSHOT"] = "0"
        env["WEIR_HOOK_LOG"] = directory.appendingPathComponent("hook.log").path
        return IsolatedProcessEnvironment.make(env)
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
        // The wrapper mints an id for every call; run directly, the helper
        // gets one here, or it records the run but logs that its turn could
        // not be told apart from a retry.
        var environment = environment
        environment["WEIR_HOOK_INVOCATION_ID"] = environment["WEIR_HOOK_INVOCATION_ID"] ?? UUID().uuidString
        process.environment = environment
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: payload)
        try stdin.fileHandleForWriting.close()
        #expect(process.waitUntilExit(within: 10), "the helper did not exit within ten seconds")
        let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }

    private func record(in directory: URL) throws -> [String: Any]? {
        let url = try directory.appendingPathComponent("states/\(AgentRecordFixtures.recordFileName(Self.runID))")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test("writes a version 3 record without opening the approval service", arguments: HookAgent.allCases)
    func lifecycleHook_writesTheRecord(agent: HookAgent) throws {
        try withTempDir { directory in
            let env = environment(agent, in: directory)
            for name in ["0000-SessionStart.json", "0001-UserPromptSubmit.json"] {
                let result = try runHelper(
                    ["hook", agent.rawValue], payload: fixturePayload(agent.rawValue, name), environment: env
                )
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
            let hint = try directory.appendingPathComponent("sessions/\(AgentRecordFixtures.hintFileName(Self.paneID))")
            #expect(FileManager.default.fileExists(atPath: hint.path))
            let recordURL = try directory.appendingPathComponent("states/\(AgentRecordFixtures.recordFileName(Self.runID))")
            // The dictionary assertions above only prove the JSON says what we
            // expect. Running it through a typed reader as well is what catches
            // a field whose Rust shape stopped being readable, which otherwise
            // surfaces as a badge that silently stops updating.
            let typed = try AgentRecordFixtures.decode(AgentStateRecordFixture.self, at: recordURL)
            #expect(typed.schemaVersion == 3)
            #expect(typed.state == "running")
            #expect(typed.runId == Self.runID)
            #expect(typed.paneId == Self.paneID)
            #expect(typed.revision == 2)
            #expect(typed.firstPrompt?.isEmpty == false)
            // The pid comes from an ancestor walk that finds nothing under the
            // test host, so we only pin its encoding.
            #expect(typed.pid.map { $0.allSatisfy(\.isNumber) } != false)
            let session = try AgentRecordFixtures.decode(AgentSessionHintFixture.self, at: hint)
            #expect(session.paneId == Self.paneID)
            #expect(session.sessionId.isEmpty == false)
            #expect(session.runId == Self.runID)
            #expect((try? String(contentsOf: directory.appendingPathComponent("hook.log"), encoding: .utf8)) == nil)
        }
    }

    /// The app locks a record's sidecar before it rewrites the record. The
    /// helper names the sidecar itself, so it has to hold off while the app
    /// holds that lock; one that locked another file would write straight
    /// through.
    @Test("skips the write while Weir holds the record lock", arguments: HookAgent.allCases)
    func lifecycleHook_yieldsToTheSwiftLock(agent: HookAgent) throws {
        try withTempDir { directory in
            let env = environment(agent, in: directory)
            let states = directory.appendingPathComponent("states")
            try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
            let recordURL = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.runID))
            let outcome = try AgentFileLock.withLock(for: recordURL) {
                let payload = try fixturePayload(agent.rawValue, "0000-SessionStart.json")
                let result = try runHelper(["hook", agent.rawValue], payload: payload, environment: env)
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
            let env = environment(.claude, in: directory)
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

    @Test("writes nothing outside a Weir pane")
    func lifecycleHook_writesNothingWithoutTheShimEnvironment() throws {
        try withTempDir { directory in
            let env = IsolatedProcessEnvironment.make(["PATH": "/usr/bin:/bin", "HOME": directory.path])
            let result = try runHelper(["hook", "codex"], payload: fixturePayload("codex", "0000-SessionStart.json"), environment: env)
            #expect(result.status == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }
}
