// main.swift
// Limpid — signed PermissionRequest bridge to the authenticated approval service.

import Foundation

/// Upper bound on one wait for a decision; the request's own timeout comes
/// from the provider crate and is shorter.
private let approvalWaitSeconds = 580
private let inputReadChunkBytes = 64 * 1024

func readBoundedStandardInput() throws -> Data {
    var input = Data()
    let limit = AgentIntegrationConfiguration.maximumXPCRequestBytes
    while input.count <= limit {
        let remaining = limit + 1 - input.count
        guard let chunk = try FileHandle.standardInput.read(
            upToCount: min(inputReadChunkBytes, remaining)
        ), !chunk.isEmpty else {
            return input
        }
        input.append(chunk)
    }
    throw AgentIntegrationError.invalidArguments("The provider approval request is too large.")
}

func run(input: Data) throws -> Data? {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "permission-request" else {
        throw AgentIntegrationError.invalidArguments(
            "Usage: AgentIntegrationHookHelper permission-request [claude|codex]"
        )
    }
    let provider = CommandLine.arguments[2]
    guard let translated = try RustProviderBridge.approvalRequest(provider: provider, payload: input),
          let request = try JSONSerialization.jsonObject(with: translated) as? [String: Any],
          let toolName = request["tool_name"] as? String,
          let requestInput = request["input"],
          let timeoutMilliseconds = request["timeout_ms"] as? Int
    else {
        throw AgentIntegrationError.invalidArguments("The provider approval request is invalid.")
    }
    let client = try AgentIntegrationXPCClient(role: .requester)
    let bootstrap = try client.openSession()
    guard let runID = bootstrap.runID,
          try AgentIntegrationServiceArtifact.matchesBundle(
              bootstrap.serviceArtifact,
              containing: URL(fileURLWithPath: CommandLine.arguments[0])
          )
    else { throw AgentIntegrationError.invalidResponse }

    let hello = try AgentIntegrationApprovalWire.object(from: client.exchange(
        AgentIntegrationApprovalWire.hello(clientVersion: "limpid-hook-helper-v1")
    ))
    let epoch = try AgentIntegrationApprovalWire.epoch(from: hello)
    let requestID = UUID()
    let submitted = try AgentIntegrationApprovalWire.object(from: client.exchange(
        AgentIntegrationApprovalWire.submit(
            epoch: epoch,
            submission: AgentIntegrationApprovalSubmission(
                runID: runID,
                requestID: requestID,
                provider: provider,
                sessionID: request["session_id"] as? String,
                operationID: request["operation_id"] as? String,
                toolName: toolName,
                summary: request["summary"] as? String,
                input: requestInput,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
    ))
    guard submitted["type"] as? String == "approval.result" else {
        throw AgentIntegrationError.invalidResponse
    }
    let response = try AgentIntegrationApprovalWire.object(from: client.exchange(
        AgentIntegrationApprovalWire.wait(
            epoch: epoch,
            runID: runID,
            requestID: requestID,
            maximumWaitMilliseconds: timeoutMilliseconds
        ),
        timeoutSeconds: approvalWaitSeconds
    ))
    guard response["type"] as? String == "approval.result",
          let body = response["body"] as? [String: Any],
          let state = body["state"] as? [String: Any],
          state["status"] as? String == "resolved",
          let result = state["result"] as? [String: Any],
          let decision = result["decision"] as? String
    else {
        return nil
    }
    var neutralDecision: [String: Any] = ["decision": decision]
    neutralDecision["message"] = result["message"] as? String
    return try RustProviderBridge.approvalOutput(
        provider: provider,
        decisionJSON: JSONSerialization.data(withJSONObject: neutralDecision)
    )
}

func publishCodexLifecycleFallback(input: Data) {
    guard CommandLine.arguments.last == "codex",
          let script = AgentApprovalHookFallback.codexLifecycleScript(
              forExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0])
                  .resolvingSymlinksInPath()
          )
    else { return }
    let process = Process()
    let standardInput = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.standardInput = standardInput
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
    } catch {
        // A failed observer fallback must not affect the provider decision.
    }
}

var input: Data?
do {
    let boundedInput = try readBoundedStandardInput()
    input = boundedInput
    if let output = try run(input: boundedInput) {
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        publishCodexLifecycleFallback(input: boundedInput)
    }
} catch {
    // No output delegates to the provider's native permission flow. Never
    // convert an integration or decoding failure into an approval decision.
    if ProcessInfo.processInfo.environment["LIMPID_HOOK_LOG"] == "1" {
        FileHandle.standardError.write(Data("Limpid approval helper: \(error)\n".utf8))
    }
    if let input {
        publishCodexLifecycleFallback(input: input)
    }
}
