// AgentIntegrationApprovalBridgeTests.swift
// Limpid — Swift-to-Rust approval session boundary tests.

import Foundation
import Testing
@testable import Limpid

struct AgentIntegrationApprovalBridgeTests {
    @Test func requesterCancellationReleasesOnlyItsOwnPendingQuestion() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let otherRequestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        _ = try completeHello(on: controller)
        for id in [requestID, otherRequestID] {
            _ = try requester.exchange(AgentIntegrationApprovalWire.submit(
                epoch: epoch,
                submission: AgentIntegrationApprovalSubmission(
                    runID: runID, requestID: id, provider: "claude", sessionID: "session",
                    operationID: nil, toolName: "AskUserQuestion", summary: nil,
                    input: ["questions": [["question": "Which color?"]]],
                    questions: nil, timeoutMilliseconds: 60000
                )
            ))
        }
        let canceled = try AgentIntegrationApprovalWire.object(from: requester.exchange(
            AgentIntegrationApprovalWire.cancel(epoch: epoch, runID: runID, requestID: requestID)
        ))
        let canceledBody = try #require(canceled["body"] as? [String: Any])
        let canceledState = try #require(canceledBody["state"] as? [String: Any])
        #expect(canceledState["status"] as? String == "canceled")
        let remaining = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.get(epoch: epoch, runID: runID, requestID: otherRequestID)
        ))
        let remainingBody = try #require(remaining["body"] as? [String: Any])
        let remainingState = try #require(remainingBody["state"] as? [String: Any])
        #expect(remainingState["status"] as? String == "pending")
    }

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

    @Test func previousServiceEpochCannotResolveAfterRestart() throws {
        let previousService = try RustApprovalService(maximumRecords: 8)
        let previousController = try previousService.controllerSession()
        let previousEpoch = try completeHello(on: previousController)

        let currentService = try RustApprovalService(maximumRecords: 8)
        let currentController = try currentService.controllerSession()
        _ = try completeHello(on: currentController)
        let response = try AgentIntegrationProbeWire.response(currentController.exchange(
            AgentIntegrationProbeWire.resolve(
                epoch: previousEpoch,
                runID: UUID(),
                requestID: UUID()
            )
        ))

        #expect(response["type"] as? String == "error")
        let body = try #require(response["body"] as? [String: Any])
        #expect(body["code"] as? String == "epoch_mismatch")
    }

    /// The broker reads `body.questions` and `body.decision.answers` by name,
    /// so a renamed key would silently drop the question card or the answer.
    @Test func approvalWire_questionsAndAnswers_useTheBrokerKeys() throws {
        let submission = AgentIntegrationApprovalSubmission(
            runID: UUID(),
            requestID: UUID(),
            provider: "claude",
            sessionID: nil,
            operationID: nil,
            toolName: "AskUserQuestion",
            summary: "Which color?",
            input: [String: Any](),
            questions: [["prompt": "Which color?", "options": [["label": "Red"]], "multi_select": false]],
            timeoutMilliseconds: 1000
        )
        let submitted = try AgentIntegrationApprovalWire.object(from: AgentIntegrationApprovalWire.submit(
            epoch: UUID(),
            submission: submission
        ))
        let submitBody = try #require(submitted["body"] as? [String: Any])
        let questions = try #require(submitBody["questions"] as? [[String: Any]])
        #expect(questions.first?["prompt"] as? String == "Which color?")

        let answered = try AgentIntegrationApprovalWire.object(from: AgentIntegrationApprovalWire.resolve(
            epoch: UUID(),
            runID: submission.runID,
            requestID: submission.requestID,
            decision: "answer",
            answers: ["Which color?": "Red"]
        ))
        let answerBody = try #require(answered["body"] as? [String: Any])
        let answerDecision = try #require(answerBody["decision"] as? [String: Any])
        #expect(answerDecision["decision"] as? String == "answer")
        let answers = try #require(answerDecision["answers"] as? [String: String])
        #expect(answers["Which color?"] == "Red")

        let denied = try AgentIntegrationApprovalWire.object(from: AgentIntegrationApprovalWire.resolve(
            epoch: UUID(),
            runID: submission.runID,
            requestID: submission.requestID,
            decision: "deny"
        ))
        let denyBody = try #require(denied["body"] as? [String: Any])
        let denyDecision = try #require(denyBody["decision"] as? [String: Any])
        #expect(denyDecision["decision"] as? String == "deny")
        #expect(denyDecision["answers"] == nil)
    }

    /// The card refuses to send an answer `fitsDecisionLimit` rejects, so its
    /// limit has to be the broker's to the byte: a smaller one blocks answers
    /// the broker would take, and a larger one lets through answers that can
    /// only fail.
    @Test func answerAtTheDecisionLimit_isWhatTheBrokerAccepts() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let runID = UUID()
        let requestID = UUID()
        let requester = try service.requesterSession(runID: runID)
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: requester)
        _ = try completeHello(on: controller)
        _ = try AgentIntegrationProbeWire.requireType(
            "approval.result",
            in: requester.exchange(AgentIntegrationProbeWire.submit(epoch: epoch, runID: runID, requestID: requestID))
        )

        // ASCII without `/` encodes the same in Foundation and serde, so the
        // padding lands the decision exactly on the limit.
        let emptyDecision = try JSONSerialization.data(withJSONObject: AgentIntegrationApprovalWire.decisionBody(
            decision: "answer",
            answers: ["q": ""]
        ))
        let padding = ApprovalResolution.maximumEncodedBytes - emptyDecision.count
        let atLimit = ApprovalResolution.answer(["q": String(repeating: "a", count: padding)])
        let overLimit = ApprovalResolution.answer(["q": String(repeating: "a", count: padding + 1)])
        #expect(atLimit.fitsDecisionLimit)
        #expect(!overLimit.fitsDecisionLimit)

        func resolve(_ resolution: ApprovalResolution) throws -> [String: Any] {
            try AgentIntegrationProbeWire.response(controller.exchange(AgentIntegrationApprovalWire.resolve(
                epoch: epoch,
                runID: runID,
                requestID: requestID,
                decision: resolution.wireDecision,
                answers: resolution.answers
            )))
        }
        #expect(try resolve(overLimit)["type"] as? String == "error")
        #expect(try resolve(atLimit)["type"] as? String == "approval.result")
    }

    private func completeHello(on session: RustApprovalSession) throws -> UUID {
        let (hello, _) = try AgentIntegrationProbeWire.hello()
        return try AgentIntegrationProbeWire.epoch(
            from: AgentIntegrationProbeWire.response(session.exchange(hello))
        )
    }
}
