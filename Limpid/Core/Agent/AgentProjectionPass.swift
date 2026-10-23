// AgentProjectionPass.swift
// Limpid — the part of a projection pass that runs off the main actor, and what crosses to it and back.

import Foundation

/// A projection pass in two halves: `AgentProjectionAdapter` reads what
/// only the main actor can and applies the answer there, and `run` does
/// what needs neither the interface nor the adapter (the turn records and
/// the round trip through the rules) on a detached task. Kept apart so the
/// values that cross between the halves are plain `Sendable` data, with
/// nothing of the adapter's own state in reach of the detached half.
enum AgentProjectionPass {
    /// What a pass reads on the main actor, for the part that runs off it.
    struct Work: Sendable {
        /// What protected turns from the sweep, as the input carries it.
        let sweptWith: TurnProtection?
        var input: AgentProjectionInput
        let now: [String: AnyEncodableInstant]
        /// The turn records as the last pass left them, or nil to list them.
        let unchanged: TurnRecordCache.Read?
        let turnSources: [TurnRecordCache.Source]
        let sent: TurnRecordCache.Snapshot
        let contentBudgetBytes: Int
    }

    /// What the part off the main actor came back with.
    struct Answer: Sendable {
        let turns: TurnRecordCache.Read
        let response: AgentProjectionResponse
        let proposal: UInt64
    }

    struct Outcome: Sendable {
        let answer: Result<Answer, any Error>
        /// The input's size, when it was encoded: a pass the bridge refused
        /// for its size is the one that most needs it logged.
        let inputBytes: Int?
    }

    /// The part of a pass that touches neither the interface nor the
    /// adapter: the turn records, and the round trip through the rules.
    static func run(
        _ work: Work,
        engine: any ProjectionPassing
    ) -> Outcome {
        let turns = work.unchanged ?? TurnRecordCache.read(work.turnSources, after: work.sent, contentBudgetBytes: work.contentBudgetBytes)
        var input = work.input
        input.turnFiles = turns.files
        // Nothing is deleted while the projection does not know every turn:
        // one it has not read is no turn it can judge.
        if !turns.isComplete {
            input.turnSweep = nil
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(input)
        } catch {
            return Outcome(answer: .failure(error), inputBytes: nil)
        }
        let answer = Result {
            let pass = try engine.pass(input: encoded, now: JSONEncoder().encode(work.now))
            let response = try JSONDecoder().decode(AgentProjectionResponse.self, from: pass.body)
            return Answer(turns: turns, response: response, proposal: pass.proposal)
        }
        return Outcome(answer: answer, inputBytes: encoded.count)
    }
}
