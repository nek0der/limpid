// AgentIntegrationProbeWire.swift
// Limpid — development probe messages for the Rust-owned approval protocol.

import Foundation

enum AgentIntegrationProbeWire {
    static func hello() throws -> (Data, UUID) {
        let messageID = UUID()
        return try (encode([
            "version": 1,
            "message_id": messageID.uuidString,
            "type": "hello",
            "body": ["client_version": "limpid-development-probe"]
        ]), messageID)
    }

    static func submit(epoch: UUID, runID: UUID, requestID: UUID) throws -> Data {
        try encode([
            "version": 1,
            "message_id": UUID().uuidString,
            "service_epoch": epoch.uuidString,
            "type": "approval.submit",
            "body": [
                "run_id": runID.uuidString,
                "request_id": requestID.uuidString,
                "provider": "claude",
                "tool_name": "Bash",
                "summary": "Validate the macOS approval service",
                "input": ["command": "make test"],
                "timeout_ms": 60000
            ]
        ])
    }

    static func wait(epoch: UUID, runID: UUID, requestID: UUID) throws -> Data {
        try encode([
            "version": 1,
            "message_id": UUID().uuidString,
            "service_epoch": epoch.uuidString,
            "type": "approval.wait",
            "body": [
                "run_id": runID.uuidString,
                "request_id": requestID.uuidString,
                "maximum_wait_ms": 60000
            ]
        ])
    }

    static func resolve(epoch: UUID, runID: UUID, requestID: UUID) throws -> Data {
        try encode([
            "version": 1,
            "message_id": UUID().uuidString,
            "service_epoch": epoch.uuidString,
            "type": "approval.resolve",
            "body": [
                "run_id": runID.uuidString,
                "request_id": requestID.uuidString,
                "decision": ["decision": "allow_once"]
            ]
        ])
    }

    static func response(_ data: Data) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIntegrationError.invalidResponse
        }
        return response
    }

    static func epoch(from response: [String: Any]) throws -> UUID {
        guard response["type"] as? String == "hello.result",
              let value = response["service_epoch"] as? String,
              let epoch = UUID(uuidString: value)
        else {
            throw AgentIntegrationError.invalidResponse
        }
        return epoch
    }

    static func requireType(_ expected: String, in data: Data) throws -> [String: Any] {
        let response = try response(data)
        guard response["type"] as? String == expected else {
            throw AgentIntegrationError.invalidResponse
        }
        return response
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
