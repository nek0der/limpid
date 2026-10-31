// VersionedDocumentMigrator.swift
// Weir — brings a persisted JSON document forward one version at a time.

import Foundation

/// One step of a document's history: turns the JSON written at `fromVersion`
/// into the JSON of `fromVersion + 1`.
///
/// Steps work on bytes rather than on the current Swift types because the
/// types only know today's shape. A step reads the old shape on its own
/// terms, as `SessionSnapshotV5` does on the JSON itself, and writes the
/// next one.
struct DocumentMigrationStep: Sendable {
    let fromVersion: Int
    let migrate: @Sendable (Data) throws -> Data
}

/// Reads a document's version and runs the steps that bring it to
/// `currentVersion`.
///
/// The stores that persist JSON (`state.json`, `settings.json`, review
/// drafts) each describe their document with one of these, so reading the
/// version and running the steps work the same way everywhere. The migrator
/// only reports what it found; what to do with a newer or unsupported file is
/// each store's call. `SessionStore` sets such a file aside, while settings
/// keep reading a newer file so a rollback through Sparkle does not reset
/// them.
struct VersionedDocumentMigrator: Sendable {
    /// The top-level key that holds the version (`version`, `schemaVersion`).
    let versionKey: String
    let currentVersion: Int
    /// The version to assume when the key is absent, for documents written
    /// before they carried one. `nil` means an absent key is unreadable.
    let versionWhenAbsent: Int?
    let steps: [DocumentMigrationStep]

    enum Outcome: Equatable {
        /// Already at `currentVersion`; decode the original bytes.
        case current
        /// Brought forward from `from`; decode `data`.
        case migrated(from: Int, data: Data)
        /// Written by a newer build (a downgrade, for example after
        /// Sparkle rolls back). Never rewritten here.
        case newer(found: Int)
        /// Older than the oldest step we keep.
        case unsupported(found: Int)
        /// Not a JSON object, or no readable version and no default. The
        /// caller's own decode reports what is wrong with it.
        case unreadableVersion
    }

    enum MigrationError: WeirLocalizedError, Equatable {
        /// A step produced a document that does not carry the version it
        /// promised, so the next step would run on the wrong shape.
        case stepProducedWrongVersion(from: Int, found: Int?)

        var message: DisplayText {
            .localized("Weir couldn’t update the saved file to this version. The file wasn’t changed.")
        }
    }

    /// Reads the version and runs the steps in order. Throws only when a
    /// step throws or breaks its contract; the caller then leaves the file
    /// untouched apart from setting it aside.
    func migrate(_ data: Data) throws -> Outcome {
        guard let found = version(of: data) else { return .unreadableVersion }
        if found == currentVersion {
            return .current
        }
        if found > currentVersion {
            return .newer(found: found)
        }
        // Two steps from one version are a programming error: which one runs
        // would depend on the order they were listed in.
        assert(Set(steps.map(\.fromVersion)).count == steps.count, "duplicate migration step")
        let byVersion = Dictionary(steps.map { ($0.fromVersion, $0) }, uniquingKeysWith: { first, _ in first })
        guard (found..<currentVersion).allSatisfy({ byVersion[$0] != nil }) else {
            return .unsupported(found: found)
        }
        var document = data
        for from in found..<currentVersion {
            guard let step = byVersion[from] else { return .unsupported(found: found) }
            document = try step.migrate(document)
            let reached = version(of: document)
            guard reached == from + 1 else {
                throw MigrationError.stepProducedWrongVersion(from: from, found: reached)
            }
        }
        return .migrated(from: found, data: document)
    }

    /// The version the document declares, or the default for an absent key.
    func version(of data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let value = object[versionKey] else { return versionWhenAbsent }
        // JSONSerialization hands numbers back as NSNumber; a Bool would
        // also bridge to Int, so reject it explicitly.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let version = number.intValue
        return Double(version) == number.doubleValue ? version : nil
    }
}
