// AgentApprovalHookAdapterTests.swift
// Limpid — exact provider request and response translation coverage.

import Foundation
import Testing
@testable import Limpid

@Suite("AgentApprovalHookAdapter")
struct AgentApprovalHookAdapterTests {
    @Test("decodes Claude PermissionRequest without trusting a pane identifier")
    func decodeClaudePermissionRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"],
            "LIMPID_PANE_ID": UUID().uuidString
        ])

        let request = try AgentApprovalHookRequest.decode(provider: "claude", data: data)

        #expect(request.provider == "claude")
        #expect(request.sessionID == "claude-session")
        #expect(request.operationID == nil)
        #expect(request.toolName == "Bash")
        #expect(request.summary == "make test")
    }

    @Test("preserves the Codex turn identifier only as correlation metadata")
    func decodeCodexPermissionRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "codex-session",
            "turn_id": "turn-7",
            "tool_name": "shell",
            "tool_input": ["description": "Inspect status"]
        ])

        let request = try AgentApprovalHookRequest.decode(provider: "codex", data: data)

        #expect(request.operationID == "turn-7")
        #expect(request.summary == "Inspect status")
    }

    @Test("maps only supported terminal decisions to provider output")
    func providerOutputIsExact() throws {
        let allowOutput = try AgentApprovalHookRequest.providerOutput(
            decision: "allow_once", message: nil
        )
        let denyOutput = try AgentApprovalHookRequest.providerOutput(
            decision: "deny", message: "Blocked"
        )
        let allow = try #require(allowOutput)
        let deny = try #require(denyOutput)

        #expect(try #require(String(bytes: allow, encoding: .utf8))
            == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(try #require(String(bytes: deny, encoding: .utf8))
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Blocked"},"hookEventName":"PermissionRequest"}}"#)
        #expect(try AgentApprovalHookRequest.providerOutput(decision: "delegate", message: nil) == nil)
    }

    @Test("rejects non-permission events")
    func rejectsOtherEvents() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"]
        ])

        #expect(throws: AgentIntegrationError.self) {
            try AgentApprovalHookRequest.decode(provider: "claude", data: data)
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
                AgentApprovalHookRequest.codexLifecycleFallbackScript(
                    forExecutableURL: executable
                ) == script
            )
        }
    }
}
