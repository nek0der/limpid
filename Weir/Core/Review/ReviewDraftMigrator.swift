// ReviewDraftMigrator.swift
// Weir — brings a review draft written before scopes were recorded forward to version 2.

import Foundation

/// The draft's history, for `VersionedDocumentMigrator`.
///
/// Version 1 knew a comment's scope only by its file's layer, and a read
/// mark only by the file ID, which carries the layer. That was enough to
/// tell the working copy from a branch or a turn, but not which turn: every
/// turn's comments shared the one `turn` layer, so a comment written against
/// one prompt's snapshot was offered against the next.
///
/// Worked on the JSON rather than on today's types: version 1's comment is
/// version 2's without `scopeIDs`, and a read-only copy of the whole shape
/// would be one more thing to keep in step with nothing. The names are
/// version 1's and version 2's own, written out, so renaming a type later
/// cannot change what this step does to a file already on disk.
enum ReviewDraftMigrator {
    static let step = DocumentMigrationStep(fromVersion: 1, migrate: migrateFromVersion1)

    /// The layers whose comments and marks belonged to the working copy.
    private static let uncommittedLayers: Set<String> = ["staged", "unstaged", "untracked"]
    /// Version 2's scope for the working copy.
    private static let uncommittedScope = "uncommitted"

    /// Version 1 to 2.
    ///
    /// - A working-copy comment (staged, unstaged, untracked) goes to the
    ///   `uncommitted` scope.
    /// - A turn's comment cannot be placed: version 1 recorded neither the
    ///   snapshot it was compared against nor the conversation, and nothing
    ///   in today's turn records proves which one it was. A branch comment
    ///   cannot either, since version 1 did not record the base. Both go to
    ///   `legacy`, shown but not inserted until the reader moves one into a
    ///   scope that passes the insert's own check.
    /// - The working copy's read marks move under `uncommitted`. A turn's go
    ///   with its comments' scope. A branch's go too: version 1 did not
    ///   record the base they were read against, and marking a file again
    ///   costs a click.
    /// - The open file is kept when it was in the working copy.
    @Sendable
    static func migrateFromVersion1(_ data: Data) throws -> Data {
        guard var draft = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReviewError.storageFailed
        }
        // Version 1 refused a draft whose keys held the wrong kind of value.
        // Read as empty instead, such a draft would come out as a valid one
        // with its comments gone, and nothing would set the original aside.
        guard let comments = draft["comments"] as? [Any] else { throw ReviewError.storageFailed }
        let viewed = try optional(draft["viewed"], as: [String: Any].self) ?? [:]
        guard viewed.values.allSatisfy({ $0 is [String: Any] }) else { throw ReviewError.storageFailed }
        let lastFileID = try optional(draft["lastFileID"], as: String.self)

        var scoped: [[String: Any]] = []
        var legacy: [[String: Any]] = []
        for element in comments {
            // Version 1 refused a draft with a comment it could not read;
            // dropping one here would lose it without a word.
            guard var comment = element as? [String: Any] else { throw ReviewError.storageFailed }
            if isUncommitted(layerOf: comment) {
                comment["scopeIDs"] = [uncommittedScope]
                scoped.append(comment)
            } else {
                comment["scopeIDs"] = [String]()
                legacy.append(comment)
            }
        }
        draft["comments"] = scoped
        if legacy.isEmpty {
            draft.removeValue(forKey: "legacy")
        } else {
            draft["legacy"] = legacy
        }

        let marks = viewed.filter { isUncommitted(fileID: $0.key) }
        draft["viewed"] = marks.isEmpty ? [String: Any]() : [uncommittedScope: marks]

        if let lastFileID, isUncommitted(fileID: lastFileID) {
            draft["lastFileID"] = [uncommittedScope: lastFileID]
        } else {
            draft["lastFileID"] = [String: String]()
        }

        draft["version"] = 2
        return try JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys])
    }

    /// A key version 1 decoded as optional: absent or `null` reads as none,
    /// as it did there, and a value of another type is refused, as it was.
    private static func optional<Value>(_ value: Any?, as _: Value.Type) throws -> Value? {
        guard let value, !(value is NSNull) else { return nil }
        guard let typed = value as? Value else { throw ReviewError.storageFailed }
        return typed
    }

    private static func isUncommitted(layerOf comment: [String: Any]) -> Bool {
        guard let file = comment["file"] as? [String: Any], let layer = file["layer"] as? String else { return false }
        return uncommittedLayers.contains(layer)
    }

    /// `ReviewFile.id` is `<layer>:<path>`.
    private static func isUncommitted(fileID: String) -> Bool {
        guard let layer = fileID.split(separator: ":", maxSplits: 1).first else { return false }
        return uncommittedLayers.contains(String(layer))
    }
}
