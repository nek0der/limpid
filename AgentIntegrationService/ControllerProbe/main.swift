// main.swift
// Limpid — development controller that resolves through the authenticated lane.

import Foundation

private func write(_ value: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((value + "\n").utf8))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "requester-endpoint" {
        let controllerClient = try AgentIntegrationXPCClient(role: .controller)
        let controllerBootstrap = try controllerClient.openSession()
        guard controllerBootstrap.role == .controller else {
            throw AgentIntegrationError.invalidResponse
        }
        do {
            let client = try AgentIntegrationXPCClient(role: .requester)
            _ = try client.openSession()
        } catch {
            write("requester-endpoint=rejected pid=\(controllerBootstrap.serviceProcessID)")
            exit(EXIT_SUCCESS)
        }
        throw AgentIntegrationError.invalidResponse
    }
    guard arguments.count == 4,
          arguments[0] == "resolve",
          let expectedEpoch = UUID(uuidString: arguments[1]),
          let runID = UUID(uuidString: arguments[2]),
          let requestID = UUID(uuidString: arguments[3])
    else {
        throw AgentIntegrationError.invalidArguments(
            "Usage: AgentIntegrationControllerProbe resolve EPOCH RUN_ID REQUEST_ID"
        )
    }

    let client = try AgentIntegrationXPCClient(role: .controller)
    let bootstrap = try client.openSession()
    guard bootstrap.role == .controller, bootstrap.runID == nil else {
        throw AgentIntegrationError.invalidResponse
    }
    let (hello, _) = try AgentIntegrationProbeWire.hello()
    let helloResponse = try AgentIntegrationProbeWire.response(client.exchange(hello))
    let epoch = try AgentIntegrationProbeWire.epoch(from: helloResponse)
    guard epoch == expectedEpoch else {
        throw AgentIntegrationError.invalidResponse
    }
    _ = try AgentIntegrationProbeWire.requireType(
        "approval.result",
        in: client.exchange(AgentIntegrationProbeWire.resolve(
            epoch: epoch,
            runID: runID,
            requestID: requestID
        ))
    )
    write("result=resolved pid=\(bootstrap.serviceProcessID)")
} catch {
    write("Controller probe failed: \(error)", to: .standardError)
    exit(EXIT_FAILURE)
}
