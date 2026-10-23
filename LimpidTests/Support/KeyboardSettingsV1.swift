// KeyboardSettingsV1.swift
// Limpid — the keyboard settings type as schema 1 builds read it, kept to prove they can read schema 2.

import Foundation
@testable import Limpid

/// `KeyboardSettings` as it stood at schema 1: overrides and the fields it
/// did not know. A build from before the supervision window decodes a
/// schema 2 file with this shape, so `unbound` and `retired` must land in
/// `unknownFields` and survive that build's next save; a rollback to it then
/// keeps them.
struct KeyboardSettingsV1: Codable, Equatable {
    var overrides: [String: StoredShortcut] = [:]
    var unknownFields: [String: LimpidJSONValue] = [:]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try c.decodeIfPresent([String: StoredShortcut].self, forKey: .overrides) ?? [:]
        unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: ["overrides"])
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overrides, forKey: .overrides)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey {
        case overrides
    }
}
