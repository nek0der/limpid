// WeirJSONValue.swift
// Weir — value-typed JSON sum used as the sidecar that preserves
// unknown fields across `settings.json` / `state.json` round trips.
//
// Pattern: every Codable struct that lives on disk carries a
// `var unknownFields: [String: WeirJSONValue] = [:]`. Its custom
// `init(from:)` captures keys the build doesn't recognize via the
// `WeirDynamicKey` keyed container, and its custom `encode(to:)` writes
// them back. The result is lossless across downgrades — a newer build's
// fields survive a Sparkle rollback to an older one, then re-surface
// when the user updates again. The original schema-anti-pattern study
// flagged this as the #1 forward-compat hazard for Weir.

import Foundation

// MARK: - JSON value sum

// `WeirJSONValue` is an indirect enum with self-referential
// associated values; Swift can't auto-synthesise `Sendable` for that
// shape, so the conformance has to stay explicit (otherwise
// `static let WeirSettings.default` fails the Swift 6 concurrency
// check). `swiftformat`'s `redundantSendable` rule would strip it.
// swiftformat:disable redundantSendable
/// Loss-free representation of a JSON value. Used only as the storage
/// type for the unknown-fields sidecar; typed fields stay on their
/// proper Codable types.
indirect enum WeirJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([WeirJSONValue])
    case object([String: WeirJSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        // Bool must be tried before Int — `JSONDecoder` will happily
        // decode `true` / `false` as `1` / `0` if asked for Int first.
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
            return
        }
        // Int before Double, so `1` round-trips as `.int(1)` rather
        // than `.double(1.0)` and the encoded form stays compact.
        if let v = try? c.decode(Int.self) {
            self = .int(v)
            return
        }
        if let v = try? c.decode(Double.self) {
            self = .double(v)
            return
        }
        if let v = try? c.decode(String.self) {
            self = .string(v)
            return
        }
        if let v = try? c.decode([WeirJSONValue].self) {
            self = .array(v)
            return
        }
        if let v = try? c.decode([String: WeirJSONValue].self) {
            self = .object(v)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "WeirJSONValue: unrecognized JSON value"
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}

// swiftformat:enable redundantSendable

// MARK: - WeirDynamicKey

/// `CodingKey` whose name is supplied at runtime. Lets the sidecar
/// walk every key in a JSON object without committing to a fixed
/// `CodingKeys` enum.
struct WeirDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        Int(stringValue)
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
    }
}

// MARK: - Sidecar helpers

enum CodableSidecar {
    /// Pull every key the typed `CodingKeys` doesn't recognize out of
    /// the supplied decoder and return them as a JSON-valued map. Pass
    /// the typed keys' raw string values in `knownKeys`; everything
    /// else lands in the result.
    static func decodeUnknownFields(
        from decoder: any Decoder,
        knownKeys: Set<String>
    ) throws -> [String: WeirJSONValue] {
        let c = try decoder.container(keyedBy: WeirDynamicKey.self)
        var result: [String: WeirJSONValue] = [:]
        for key in c.allKeys where !knownKeys.contains(key.stringValue) {
            result[key.stringValue] = try c.decode(WeirJSONValue.self, forKey: key)
        }
        return result
    }

    /// Overload that accepts the `CodingKeys` type directly. The Set
    /// is materialized once per call here too, but each caller no
    /// longer rebuilds it inline — callers that hit a hot path can
    /// keep a cached `Set` and use the original overload.
    static func decodeUnknownFields<K: CodingKey & CaseIterable>(
        from decoder: any Decoder,
        knownKeys keysType: K.Type
    ) throws -> [String: WeirJSONValue] {
        try decodeUnknownFields(
            from: decoder,
            knownKeys: Set(K.allCases.map(\.stringValue))
        )
    }

    /// Write the captured unknown fields back into the supplied
    /// encoder. Safe to call after the typed-field encode pass —
    /// `KeyedEncodingContainer` allows multiple keyed-container
    /// openings on the same encoder as long as the key sets don't
    /// collide, which the sidecar contract guarantees.
    static func encodeUnknownFields(
        _ fields: [String: WeirJSONValue],
        to encoder: any Encoder
    ) throws {
        guard !fields.isEmpty else { return }
        var c = encoder.container(keyedBy: WeirDynamicKey.self)
        for (key, value) in fields {
            try c.encode(value, forKey: WeirDynamicKey(stringValue: key))
        }
    }
}
