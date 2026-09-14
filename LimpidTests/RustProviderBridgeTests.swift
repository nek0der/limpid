// RustProviderBridgeTests.swift
// Limpid — provider request and response translation across the Rust ABI.
//
// The translation rules live in the provider crates and are specified by the
// recorded fixtures; this suite proves the Swift wrapper hands bytes across
// the boundary faithfully and keeps the exact output the providers expect.

import Foundation
import Testing
@testable import Limpid

@Suite("RustProviderBridge")
struct RustProviderBridgeTests {
    private func request(provider: String, _ object: [String: Any]) throws -> [String: Any]? {
        let payload = try JSONSerialization.data(withJSONObject: object)
        guard let translated = try RustProviderBridge.approvalRequest(provider: provider, payload: payload)
        else { return nil }
        return try JSONSerialization.jsonObject(with: translated) as? [String: Any]
    }

    @Test("decodes Claude PermissionRequest without trusting a pane identifier")
    func decodeClaudePermissionRequest() throws {
        let request = try #require(try request(provider: "claude", [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"],
            "LIMPID_PANE_ID": UUID().uuidString
        ]))

        #expect(request["provider"] as? String == "claude")
        #expect(request["session_id"] as? String == "claude-session")
        #expect(request["operation_id"] == nil)
        #expect(request["tool_name"] as? String == "Bash")
        #expect(request["summary"] as? String == "make test")
        #expect(request["timeout_ms"] as? Int == 570_000)
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

    @Test("locates the bundled Codex lifecycle fallback beside the helper")
    func codexLifecycleFallbackPath() throws {
        try withTempDir { directory in
            let executable = directory.appendingPathComponent(
                "Limpid Dev.app/Contents/MacOS/AgentIntegrationHookHelper"
            )
            let script = directory.appendingPathComponent(
                "Limpid Dev.app/Contents/Resources/codex-shim/limpid-hook"
            )
            try FileManager.default.createDirectory(
                at: script.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: script)

            #expect(
                AgentApprovalHookFallback.codexLifecycleScript(
                    forExecutableURL: executable
                ) == script
            )
        }
    }
}
