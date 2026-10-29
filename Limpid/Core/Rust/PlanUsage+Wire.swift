// PlanUsage+Wire.swift
// Limpid — plan usage in the form the Rust side writes it: camel case, with ISO-8601 times.

import Foundation

extension PlanUsage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case windows, observedAt, resetCredits
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            windows: container.decode([PlanUsageWindow].self, forKey: .windows),
            observedAt: PlanUsageWire.date(container.decode(String.self, forKey: .observedAt), forKey: .observedAt, in: container),
            resetCredits: container.decodeIfPresent(PlanResetCredits.self, forKey: .resetCredits)
        )
    }

    /// Decodes the record the status line relay writes, or the usage in an
    /// answer the bridge read (`limpid_agent_model::PlanUsage`).
    static func decode(_ data: Data) throws -> PlanUsage {
        try JSONDecoder().decode(PlanUsage.self, from: data)
    }
}

extension PlanResetCredits: Decodable {
    private enum CodingKeys: String, CodingKey {
        case available, expiresAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            available: container.decode(Int.self, forKey: .available),
            expiresAt: container.decodeIfPresent(String.self, forKey: .expiresAt).map {
                try PlanUsageWire.date($0, forKey: .expiresAt, in: container)
            }
        )
    }
}

extension PlanUsageWindow: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, usedPercent, resetsAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(String.self, forKey: .kind),
            usedPercent: container.decode(Double.self, forKey: .usedPercent),
            resetsAt: container.decodeIfPresent(String.self, forKey: .resetsAt).map {
                try PlanUsageWire.date($0, forKey: .resetsAt, in: container)
            }
        )
    }
}

private enum PlanUsageWire {
    /// The Rust side writes every time as ISO-8601 UTC with second precision.
    static func date<Key: CodingKey>(
        _ text: String,
        forKey key: Key,
        in container: KeyedDecodingContainer<Key>
    ) throws -> Date {
        guard let date = try? Date(text, strategy: .iso8601) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not an ISO-8601 time")
        }
        return date
    }
}
