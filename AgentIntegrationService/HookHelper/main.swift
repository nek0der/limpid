// main.swift
// Limpid — signed PermissionRequest bridge to the authenticated approval
// service, and the process every lifecycle hook runs in.
//
// Two subcommands, deliberately separate: `permission-request <provider>`
// opens the approval service and waits for a decision. `hook <provider>
// [worktree]` runs the Rust hook runtime in-process without opening an XPC
// connection, so lifecycle hooks remain independent of approval-service
// availability.

import Foundation

/// Upper bound on one wait for a decision; the request's own timeout comes
/// from the provider crate and is shorter.
private let approvalWaitSeconds = 580
private let inputReadChunkBytes = 64 * 1024

/// Diagnostics go where `LIMPID_HOOK_LOG` points, as the Rust runtime's own
/// lines do, so one file collects both sides of a failed hook. The providers
/// discard the stderr of a hook that exits 0, which is why stderr alone is
/// not enough. The value `1` keeps the old meaning of "print to stderr".
func logHookDiagnostic(_ message: String) {
    guard let target = ProcessInfo.processInfo.environment["LIMPID_HOOK_LOG"], !target.isEmpty else {
        return
    }
    let line = Data((message + "\n").utf8)
    guard target != "1", let handle = FileHandle(forWritingAtPath: target) ?? createLog(at: target) else {
        FileHandle.standardError.write(line)
        return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    handle.write(line)
}

private func createLog(at path: String) -> FileHandle? {
    guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        return nil
    }
    return FileHandle(forWritingAtPath: path)
}

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

/// Runs a lifecycle or worktree hook and exits the process with the
/// runtime's status. Only a successful worktree intercept exits non-zero;
/// every failure is logged by the runtime and exits zero so the agent is
/// never blocked by Limpid.
func runLifecycleHook(provider: String, kind: RustProviderBridge.HookKind) -> Never {
    let input: Data
    do {
        input = try readBoundedStandardInput()
    } catch {
        logHookDiagnostic("Limpid hook helper: \(error)")
        exit(0)
    }
    do {
        let outcome = try RustProviderBridge.runHook(
            provider: provider,
            kind: kind,
            payload: input,
            environment: ProcessInfo.processInfo.environment
        )
        if let message = outcome.message, outcome.exitCode != 0 {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        exit(outcome.exitCode)
    } catch {
        logHookDiagnostic("Limpid hook helper: \(error)")
        exit(0)
    }
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
    guard CommandLine.arguments.last == "codex" else { return }
    // With the Rust backend the lifecycle record is written in-process; the
    // shell receiver is only re-run while the shell backend is selected. An
    // unset variable means the default backend, as the wrappers read it.
    let backend = ProcessInfo.processInfo.environment[AgentHookBackend.environmentKey]
    if backend != AgentHookBackend.shell.rawValue {
        _ = try? RustProviderBridge.runHook(
            provider: "codex",
            kind: .lifecycle,
            payload: input,
            environment: ProcessInfo.processInfo.environment
        )
        return
    }
    guard let script = AgentApprovalHookFallback.codexLifecycleScript(
        forExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
    ) else { return }
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

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "hook" {
    let kind: RustProviderBridge.HookKind = CommandLine.arguments.dropFirst(3).first == "worktree"
        ? .worktree
        : .lifecycle
    runLifecycleHook(provider: CommandLine.arguments[2], kind: kind)
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
    logHookDiagnostic("Limpid approval helper: \(error)")
    if let input {
        publishCodexLifecycleFallback(input: input)
    }
}
