// AgentIntegrationApprovalBridgeTests.swift
// Limpid — Swift-to-Rust approval session boundary tests.

import Foundation
import Testing
@testable import Limpid

struct AgentIntegrationApprovalBridgeTests {
    @Test func requesterAndControllerShareRustBroker() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        #expect(try completeHello(on: controller) == epoch)

        _ = try AgentIntegrationProbeWire.requireType(
            "approval.result",
            in: requester.exchange(AgentIntegrationProbeWire.submit(
                epoch: epoch,
                runID: runID,
                requestID: requestID
            ))
        )
        let resolved = try AgentIntegrationProbeWire.requireType(
            "approval.result",
            in: controller.exchange(AgentIntegrationProbeWire.resolve(
                epoch: epoch,
                runID: runID,
                requestID: requestID
            ))
        )
        let body = try #require(resolved["body"] as? [String: Any])
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["status"] as? String == "resolved")
    }

    @Test func requesterPrincipalCannotBeUpgradedByPayload() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let epoch = try completeHello(on: requester)
        _ = try requester.exchange(AgentIntegrationProbeWire.submit(
            epoch: epoch,
            runID: runID,
            requestID: requestID
        ))

        let response = try AgentIntegrationProbeWire.response(requester.exchange(
            AgentIntegrationProbeWire.resolve(
                epoch: epoch,
                runID: runID,
                requestID: requestID
            )
        ))
        #expect(response["type"] as? String == "error")
        let body = try #require(response["body"] as? [String: Any])
        #expect(body["code"] as? String == "unauthorized")
    }

    @Test func requesterCannotSubmitForAnotherRun() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let requester = try service.requesterSession(runID: UUID())
        let epoch = try completeHello(on: requester)
        let response = try AgentIntegrationProbeWire.response(requester.exchange(
            AgentIntegrationProbeWire.submit(
                epoch: epoch,
                runID: UUID(),
                requestID: UUID()
            )
        ))
        #expect(response["type"] as? String == "error")
        let body = try #require(response["body"] as? [String: Any])
        #expect(body["code"] as? String == "unauthorized")
    }

    @Test func malformedDiscreteMessageFailsWithoutResponse() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let requester = try service.requesterSession(runID: UUID())
        var didThrow = false
        do {
            _ = try requester.exchange(Data("not-json".utf8))
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    private func completeHello(on session: RustApprovalSession) throws -> UUID {
        let (hello, _) = try AgentIntegrationProbeWire.hello()
        return try AgentIntegrationProbeWire.epoch(
            from: AgentIntegrationProbeWire.response(session.exchange(hello))
        )
    }
}
