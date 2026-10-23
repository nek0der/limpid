// ApprovalResolution+Wire.swift
// Limpid — an approval decision as the broker reads and writes it, and the size it accepts.

import Foundation

extension ApprovalResolution {
    /// Reads a decision as the broker reports it (`state.result`). `nil` for
    /// a decision this build does not know, so it is never mistaken for one
    /// it does.
    init?(wire: [String: Any]) {
        switch wire["decision"] as? String {
        case "allow_once": self = .allowOnce
        case "deny": self = .deny
        case "delegate": self = .delegate
        case "answer":
            guard let answers = wire["answers"] as? [String: String] else { return nil }
            self = .answer(answers)
        default: return nil
        }
    }

    var wireDecision: String {
        switch self {
        case .allowOnce: "allow_once"
        case .deny: "deny"
        case .delegate: "delegate"
        case .answer: "answer"
        }
    }

    /// The decision limit in `docs/agent-integration-protocol.md`, enforced
    /// by the broker as `MAXIMUM_DECISION_BYTES`. The broker rejects a larger
    /// decision outright, so retrying the same answer can never succeed and
    /// the card has to say so before sending. The two sides check the value
    /// against `rust/fixtures/contract/shared-values.json`.
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
