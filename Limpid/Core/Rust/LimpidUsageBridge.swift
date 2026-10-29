// LimpidUsageBridge.swift
// Limpid — Swift entry point for reading an agent's plan usage answer through the Rust bridge.

import Foundation
import LimpidRustBridge

/// A usage call that could not be completed, with the C ABI's own status
/// (`limpid_usage_result`).
enum LimpidUsageBridgeError: Error {
    case rust(Int32)
}

/// The app's plan usage calls of the Rust bridge. The status line relay's
/// are the Hook Helper's (`RustStatusLineBridge`).
enum LimpidUsageBridge {
    /// What an agent's answer to a plan usage request says, as its adapter
    /// read it.
    enum Answer: Equatable, Sendable {
        case usage(PlanUsage)
        /// An answer with no plan in it: an API key, or signed out.
        case noPlan
        /// An error answer, or no answer at all. Not `noPlan`: the server
        /// failed, and there is nothing for the person to sign in to.
        case unreadable
    }

    /// What `provider`'s answer to a plan usage request says. The provider's
    /// adapter reads it, so the shape of Codex's answer is known in one place.
    static func planUsageAnswer(provider: AgentKind, answer: Data) throws -> Answer {
        // An answer that is not UTF-8 is not JSON, so there is nothing in it.
        guard let text = String(bytes: answer, encoding: .utf8) else { return .unreadable }
        let request = try JSONEncoder().encode(Request(provider: provider.rawValue, answer: text))
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let status = request.withUnsafeBytes { buffer in
            limpid_plan_usage_answer_v1(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &out, &outCount)
        }
        guard let out else { throw LimpidUsageBridgeError.rust(status) }
        // The bytes are ours whatever the status turned out to be.
        defer { limpid_approval_bytes_free_v1(out, outCount) }
        guard status == Int32(LIMPID_USAGE_OK.rawValue) else { throw LimpidUsageBridgeError.rust(status) }
        let body = try JSONDecoder().decode(Body.self, from: Data(bytes: out, count: outCount))
        switch body.outcome {
        case .usage:
            guard let usage = body.usage else { return .unreadable }
            return .usage(usage)
        case .noPlan: return .noPlan
        case .unreadable: return .unreadable
        }
    }

    private struct Request: Encodable {
        let provider: String
        let answer: String
    }

    private struct Body: Decodable {
        let outcome: Outcome
        /// Present with `usage` alone.
        let usage: PlanUsage?
    }

    /// The wire names of `Answer`'s cases.
    private enum Outcome: String, Decodable {
        case usage, noPlan, unreadable
    }
}
