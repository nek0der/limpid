// AgentIntegrationApprovalWire.swift
// Limpid — provider-neutral approval messages shared by the app and Hook Helper.

import Foundation

struct AgentIntegrationApprovalSubmission {
    let runID: UUID
    let requestID: UUID
    let provider: String
    let sessionID: String?
    let operationID: String?
    let toolName: String
    let summary: String?
    let input: Any
    let timeoutMilliseconds: Int
}

enum AgentIntegrationApprovalWire {
    static func hello(clientVersion: String) throws -> Data {
        try encode([
            "version": 1,
            "message_id": UUID().uuidString,
            "type": "hello",
            "body": ["client_version": clientVersion]
        ])
    }

    static func submit(epoch: UUID, submission: AgentIntegrationApprovalSubmission) throws -> Data {
        var body: [String: Any] = [
            "run_id": submission.runID.uuidString,
            "request_id": submission.requestID.uuidString,
            "provider": submission.provider,
            "tool_name": submission.toolName,
            "input": submission.input,
            "timeout_ms": submission.timeoutMilliseconds
        ]
        body["session_id"] = submission.sessionID
        body["operation_id"] = submission.operationID
        body["summary"] = submission.summary
        return try request(type: "approval.submit", epoch: epoch, body: body)
    }

    static func wait(
        epoch: UUID,
        runID: UUID,
        requestID: UUID,
        maximumWaitMilliseconds: Int
    ) throws -> Data {
        try request(type: "approval.wait", epoch: epoch, body: [
            "run_id": runID.uuidString,
            "request_id": requestID.uuidString,
            "maximum_wait_ms": maximumWaitMilliseconds
        ])
    }

    static func get(epoch: UUID, runID: UUID, requestID: UUID) throws -> Data {
        try request(type: "approval.get", epoch: epoch, body: [
            "run_id": runID.uuidString,
            "request_id": requestID.uuidString
        ])
    }

    static func resolve(
        epoch: UUID,
        runID: UUID,
        requestID: UUID,
        decision: String,
        message: String? = nil
    ) throws -> Data {
        var decisionBody: [String: Any] = ["decision": decision]
        decisionBody["message"] = message
        return try request(type: "approval.resolve", epoch: epoch, body: [
            "run_id": runID.uuidString,
            "request_id": requestID.uuidString,
            "decision": decisionBody
        ])
    }

    static func snapshot(epoch: UUID) throws -> Data {
        try request(type: "approval.snapshot", epoch: epoch, body: nil)
    }

    static func subscribe(
        epoch: UUID,
        afterSequence: UInt64,
        maximumWaitMilliseconds: Int
    ) throws -> Data {
        try request(type: "approval.subscribe", epoch: epoch, body: [
            "after_sequence": afterSequence,
            "maximum_wait_ms": maximumWaitMilliseconds
        ])
    }

    static func object(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIntegrationError.invalidResponse
        }
        return value
    }

    static func epoch(from response: [String: Any]) throws -> UUID {
        guard response["type"] as? String == "hello.result",
              let rawEpoch = response["service_epoch"] as? String,
              let epoch = UUID(uuidString: rawEpoch)
        else {
            throw AgentIntegrationError.invalidResponse
        }
        return epoch
    }

    private static func request(type: String, epoch: UUID, body: Any?) throws -> Data {
        var value: [String: Any] = [
            "version": 1,
            "message_id": UUID().uuidString,
            "service_epoch": epoch.uuidString,
            "type": type
        ]
        value["body"] = body
        return try encode(value)
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw AgentIntegrationError.invalidArguments("The approval payload is not valid JSON.")
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
