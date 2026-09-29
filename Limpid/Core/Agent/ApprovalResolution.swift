// ApprovalResolution.swift
// Limpid — the decision the controller sends back for an approval request.

import Foundation

/// What the controller sends back for one request.
enum ApprovalResolution: Equatable, Sendable {
    case allowOnce
    case deny
    /// No decision: the provider's own prompt takes over. Also used to
    /// release a request the terminal already answered.
    case delegate
    case answer([String: String])

    var wireDecision: String {
        switch self {
        case .allowOnce: "allow_once"
        case .deny: "deny"
        case .delegate: "delegate"
        case .answer: "answer"
        }
    }

    var answers: [String: String]? {
        if case let .answer(answers) = self {
            return answers
        }
        return nil
    }

    /// The decision limit in `docs/agent-integration-protocol.md`, enforced
    /// by the broker as `MAXIMUM_DECISION_BYTES`. The broker rejects a larger
    /// decision outright, so retrying the same answer can never succeed and
    /// the card has to say so before sending.
    static let maximumEncodedBytes = 8 * 1024

    /// Whether the broker will accept this decision's size. We measure the
    /// object `approval.resolve` sends; Foundation escapes `/` where serde
    /// does not, so the estimate only errs toward rejecting.
    var fitsDecisionLimit: Bool {
        let body = AgentIntegrationApprovalWire.decisionBody(decision: wireDecision, answers: answers)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        return data.count <= Self.maximumEncodedBytes
    }
}
