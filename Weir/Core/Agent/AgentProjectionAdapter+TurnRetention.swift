// AgentProjectionAdapter+TurnRetention.swift
// Weir — asks the retention sweep how many turn records a change of the limits deletes.

import Foundation
import OSLog

private let log = Logger.weir("agent.projection.adapter")

extension AgentProjectionAdapter {
    /// How many turn records going from `old` to `new` deletes now, as the
    /// sweep would choose them from what the last pass committed
    /// (`WeirProjectionBridge.Engine.turnsTaken`), or `nil` when the rules
    /// could not say. None before the host has judged the turns, when the
    /// sweep deletes nothing. Asked off the main actor: it waits for the
    /// engine's lock, which a requested pass holds while it runs.
    func turnsTaken(from old: TurnRetentionLimits, to new: TurnRetentionLimits) async -> Int? {
        guard let protection = turnProtection() else { return 0 }
        let engine = engine
        do {
            let change = try JSONEncoder().encode(AgentProjectionTurnSweepChange(
                from: AgentProjectionTurnSweep(limits: old, protection: protection),
                to: AgentProjectionTurnSweep(limits: new, protection: protection)
            ))
            let now = try JSONEncoder().encode(AnyEncodableInstant.now())
            return try await Task.detached(priority: .userInitiated) {
                try engine.turnsTaken(change: change, now: now)
            }.value
        } catch {
            log.error("counting the turns a retention change deletes failed: \(error, privacy: .private)")
            return nil
        }
    }
}
