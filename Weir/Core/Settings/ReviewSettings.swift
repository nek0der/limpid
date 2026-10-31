// ReviewSettings.swift
// Weir — the review's settings: the person's own Git tool for the changes panel.

import Foundation

/// The review's section of `settings.json`. A section of its own rather
/// than more root keys (`jumpOpensTurnReview` predates it) so a newer
/// build's review settings round-trip through an older one in
/// `unknownFields`.
struct ReviewSettings: Codable, Equatable {
    /// The command "Open in {tool}" types in a new tab of the session's
    /// folder: the person's diff or Git tool, which the changes panel
    /// offers beside "Create PR". Free text, and empty by default,
    /// which hides the button: no tool is named in our source, so none is
    /// assumed installed.
    var externalDiffCommand = ""

    /// See `WeirSettings.unknownFields`.
    var unknownFields: [String: WeirJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.externalDiffCommand = try c.decodeIfPresent(String.self, forKey: .externalDiffCommand) ?? ""
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(externalDiffCommand, forKey: .externalDiffCommand)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case externalDiffCommand
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}
