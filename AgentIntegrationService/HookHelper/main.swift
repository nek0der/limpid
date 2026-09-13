// main.swift
// Limpid — signed PermissionRequest bridge to the authenticated approval service.

import Foundation

private let approvalTimeoutMilliseconds = 570_000
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
    let request = try AgentApprovalHookRequest.decode(provider: CommandLine.arguments[2], data: input)
    let client = try AgentIntegrationXPCClient(role: .requester, timeoutSeconds: 580)
    let bootstrap = try client.openSession()
    guard let runID = bootstrap.runID else { throw AgentIntegrationError.invalidResponse }

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
                provider: request.provider,
                sessionID: request.sessionID,
                operationID: request.operationID,
                toolName: request.toolName,
                summary: request.summary,
                input: request.input,
                timeoutMilliseconds: approvalTimeoutMilliseconds
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
            maximumWaitMilliseconds: approvalTimeoutMilliseconds
        )
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
    return try AgentApprovalHookRequest.providerOutput(
        decision: decision,
        message: result["message"] as? String
    )
}

func publishCodexLifecycleFallback(input: Data) {
    guard CommandLine.arguments.last == "codex",
          let script = AgentApprovalHookRequest.codexLifecycleFallbackScript(
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
