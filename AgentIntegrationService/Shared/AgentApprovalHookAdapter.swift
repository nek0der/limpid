// AgentApprovalHookAdapter.swift
// Limpid — fail-closed Claude and Codex PermissionRequest translation.

import Foundation

struct AgentApprovalHookRequest {
    let provider: String
    let sessionID: String?
    let operationID: String?
    let toolName: String
    let summary: String?
    let input: Any

    static func decode(provider: String, data: Data) throws -> Self {
        guard provider == "claude" || provider == "codex",
              data.count <= AgentIntegrationConfiguration.maximumXPCRequestBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "PermissionRequest",
              let toolName = object["tool_name"] as? String,
              !toolName.isEmpty,
              let input = object["tool_input"],
              JSONSerialization.isValidJSONObject(input)
        else {
            throw AgentIntegrationError.invalidArguments("The provider approval request is invalid.")
        }
        let summary = (input as? [String: Any])?["command"] as? String
            ?? (input as? [String: Any])?["description"] as? String
        return Self(
            provider: provider,
            sessionID: object["session_id"] as? String,
            operationID: provider == "codex" ? object["turn_id"] as? String : nil,
            toolName: toolName,
            summary: summary,
            input: input
        )
    }

    static func providerOutput(decision: String, message: String?) throws -> Data? {
        switch decision {
        case "allow_once":
            return try output(behavior: "allow", message: nil)
        case "deny":
            return try output(behavior: "deny", message: message)
        case "delegate":
            return nil
        default:
            throw AgentIntegrationError.invalidResponse
        }
    }

    static func codexLifecycleFallbackScript(forExecutableURL executableURL: URL) -> URL? {
        let script = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/codex-shim/limpid-hook")
            .standardizedFileURL
        return FileManager.default.isReadableFile(atPath: script.path) ? script : nil
    }

    private static func output(behavior: String, message: String?) throws -> Data {
        var decision: [String: Any] = ["behavior": behavior]
        decision["message"] = message
        return try JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ], options: [.sortedKeys])
    }
}
