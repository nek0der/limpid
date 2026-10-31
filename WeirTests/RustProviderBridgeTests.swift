// RustProviderBridgeTests.swift
// Weir — provider request and response translation across the Rust ABI.
//
// The translation rules live in the provider crates and are specified by the
// recorded fixtures; this suite proves the Swift wrapper hands bytes across
// the boundary faithfully and keeps the exact output the providers expect.

import Foundation
import Testing
@testable import Weir

@Suite("RustProviderBridge")
struct RustProviderBridgeTests {
    private func request(provider: String, _ object: [String: Any]) throws -> [String: Any]? {
        let payload = try JSONSerialization.data(withJSONObject: object)
        guard let translated = try RustProviderBridge.approvalRequest(provider: provider, payload: payload)
        else { return nil }
        return try JSONSerialization.jsonObject(with: translated) as? [String: Any]
    }

    /// What the hook wrote reaches Rust and comes back translated. Which
    /// fields the translation keeps is the provider crate's to test.
    @Test("hands a Claude PermissionRequest across and reads back its translation")
    func decodeClaudePermissionRequest() throws {
        let request = try #require(try request(provider: "claude", [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"]
        ]))

        #expect(request["provider"] as? String == "claude")
        #expect(request["session_id"] as? String == "claude-session")
        #expect(request["tool_name"] as? String == "Bash")
        #expect((request["input"] as? [String: Any])?["command"] as? String == "make test")
    }

    @Test("preserves the Codex turn identifier only as correlation metadata")
    func decodeCodexPermissionRequest() throws {
        let request = try #require(try request(provider: "codex", [
            "hook_event_name": "PermissionRequest",
            "session_id": "codex-session",
            "turn_id": "turn-7",
            "tool_name": "shell",
            "tool_input": ["description": "Inspect status"]
        ]))

        #expect(request["operation_id"] as? String == "turn-7")
        #expect(request["summary"] as? String == "Inspect status")
    }

    @Test("maps only supported terminal decisions to provider output")
    func providerOutputIsExact() throws {
        func output(_ decision: [String: Any]) throws -> Data? {
            try RustProviderBridge.approvalOutput(
                provider: "claude",
                requestJSON: JSONSerialization.data(withJSONObject: ["tool_name": "Bash", "input": [:]]),
                decisionJSON: JSONSerialization.data(withJSONObject: decision)
            )
        }
        let allow = try #require(try output(["decision": "allow_once"]))
        let deny = try #require(try output(["decision": "deny", "message": "Blocked"]))

        #expect(try #require(String(bytes: allow, encoding: .utf8))
            == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(try #require(String(bytes: deny, encoding: .utf8))
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Blocked"},"hookEventName":"PermissionRequest"}}"#)
        #expect(try output(["decision": "delegate"]) == nil)
        #expect(throws: AgentIntegrationError.self) {
            try output(["decision": "ask"])
        }
    }

    @Test("renders an answer through the v2 output with the request input")
    func answerOutputEchoesQuestions() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "tool_name": "AskUserQuestion",
            "input": ["questions": [["question": "Which color?", "options": [["label": "Red"]]]]]
        ])
        let decision = try JSONSerialization.data(withJSONObject: [
            "decision": "answer", "answers": ["Which color?": "Red"]
        ])
        let output = try #require(try RustProviderBridge.approvalOutput(
            provider: "claude", requestJSON: request, decisionJSON: decision
        ))
        let text = try #require(String(bytes: output, encoding: .utf8))
        #expect(text.contains(#""updatedInput":{"answers":{"Which color?":"Red"}"#))
    }

    @Test("reports non-permission events as no request and unknown providers as failures")
    func rejectsOtherEventsAndProviders() throws {
        #expect(try request(provider: "claude", [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"]
        ]) == nil)
        #expect(throws: AgentIntegrationError.self) {
            try request(provider: "gemini", ["hook_event_name": "PermissionRequest"])
        }
        #expect(throws: AgentIntegrationError.self) {
            try RustProviderBridge.approvalRequest(provider: "claude", payload: Data("[]".utf8))
        }
    }

    /// The hook helper's usage limit watcher finds Codex by these names, so
    /// they are the descriptor's own, not a copy that a new name would miss.
    @Test("reads a provider's process names from its Rust descriptor")
    func processNamesAreTheDescriptors() throws {
        let codex = try RustProviderBridge.processNames(provider: "codex")
        #expect(codex.contains("codex"))
        #expect(codex == Set(AgentProviderRegistry.processNames(for: .codex)))
        #expect(try RustProviderBridge.processNames(provider: "gemini").isEmpty)
    }

    @Test func hookObservationClockCanBeControlledWithoutReorderingTheRecord() throws {
        try withTempDir { directory in
            let pane = UUID().uuidString
            let run = UUID().uuidString
            var environment = HookAgent.codex.environment(in: directory, paneID: pane)
            environment["WEIR_AGENT_RUN_ID"] = run
            environment["WEIR_TURN_SNAPSHOT"] = "0"
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "SessionStart",
                "source": "startup",
                "session_id": "clock-fixture",
                "model": "gpt-fixture",
                "permission_mode": "default",
                "cwd": directory.path
            ])
            let observations: [(UInt64, UInt64)] = [(100, 100), (50, 100), (200, 200)]
            for (observed, expected) in observations {
                let outcome = try RustProviderBridge.runHook(
                    provider: "codex", kind: .lifecycle, payload: payload,
                    environment: environment, observationClock: { observed }
                )
                #expect(outcome.exitCode == 0)
                let url = try directory.appendingPathComponent("states/\(AgentRecordFixtures.recordFileName(run))")
                let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                #expect((record["runObservedOrder"] as? NSNumber)?.uint64Value == expected)
            }
        }
    }

}
