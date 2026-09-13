// main.swift
// Limpid — development requester that submits and waits through macOS XPC.

import Foundation

private func write(_ value: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((value + "\n").utf8))
}

do {
    let command = CommandLine.arguments.dropFirst().first ?? "submit-wait"
    if command == "controller-endpoint" {
        let requesterClient = try AgentIntegrationXPCClient(role: .requester)
        let requesterBootstrap = try requesterClient.openSession()
        guard requesterBootstrap.role == .requester else {
            throw AgentIntegrationError.invalidResponse
        }
        do {
            let client = try AgentIntegrationXPCClient(role: .controller)
            _ = try client.openSession()
        } catch {
            write("controller-endpoint=rejected pid=\(requesterBootstrap.serviceProcessID)")
            exit(EXIT_SUCCESS)
        }
        throw AgentIntegrationError.invalidResponse
    }
    guard command == "submit-wait" || command == "self-resolve" else {
        throw AgentIntegrationError.invalidArguments(
            "Usage: AgentIntegrationRequesterProbe [submit-wait|self-resolve|controller-endpoint]"
        )
    }

    let client = try AgentIntegrationXPCClient(role: .requester, timeoutSeconds: 65)
    let bootstrap = try client.openSession()
    guard bootstrap.role == .requester, let runID = bootstrap.runID else {
        throw AgentIntegrationError.invalidResponse
    }
    let (hello, _) = try AgentIntegrationProbeWire.hello()
    let helloResponse = try AgentIntegrationProbeWire.response(client.exchange(hello))
    let epoch = try AgentIntegrationProbeWire.epoch(from: helloResponse)
    let requestID = UUID()
    _ = try AgentIntegrationProbeWire.requireType(
        "approval.result",
        in: client.exchange(AgentIntegrationProbeWire.submit(
            epoch: epoch,
            runID: runID,
            requestID: requestID
        ))
    )
    write("epoch=\(epoch.uuidString) run=\(runID.uuidString) request=\(requestID.uuidString) pid=\(bootstrap.serviceProcessID)")

    if command == "self-resolve" {
        let response = try AgentIntegrationProbeWire.response(client.exchange(
            AgentIntegrationProbeWire.resolve(epoch: epoch, runID: runID, requestID: requestID)
        ))
        guard response["type"] as? String == "error",
              let body = response["body"] as? [String: Any],
              body["code"] as? String == "unauthorized"
        else {
            throw AgentIntegrationError.invalidResponse
        }
        write("self-resolve=rejected")
        exit(EXIT_SUCCESS)
    }

    let result = try AgentIntegrationProbeWire.requireType(
        "approval.result",
        in: client.exchange(AgentIntegrationProbeWire.wait(
            epoch: epoch,
            runID: runID,
            requestID: requestID
        ))
    )
    guard let body = result["body"] as? [String: Any],
          let state = body["state"] as? [String: Any],
          state["status"] as? String == "resolved"
    else {
        throw AgentIntegrationError.invalidResponse
    }
    write("result=resolved")
} catch {
    write("Requester probe failed: \(error)", to: .standardError)
    exit(EXIT_FAILURE)
}
