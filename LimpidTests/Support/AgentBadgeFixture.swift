// AgentBadgeFixture.swift
// Limpid — a badge read from the projection's JSON, as the app reads one.

import Foundation
@testable import Limpid

extension AgentBadge {
    /// A finished run's badge whose `field` holds the JSON `value`, or leaves
    /// the key out when `value` is nil.
    static func decoded(field: String, value: String?, updatedAt: String = "2026-10-28T05:00:00Z") throws -> AgentBadge {
        let extra = value.map { #","\#(field)":\#($0)"# } ?? ""
        let json = #"{"state":"finished","updatedAt":"\#(updatedAt)""# + extra + "}"
        return try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(json.utf8)).asAgentBadge
    }
}
