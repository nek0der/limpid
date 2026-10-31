// VersionedDocumentMigratorTests.swift
// Weir — reading a document's version and running its steps in order.

import Foundation
import Testing
@testable import Weir

struct VersionedDocumentMigratorTests {
    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A step that bumps the version and records that it ran.
    private static func bump(from version: Int) -> DocumentMigrationStep {
        DocumentMigrationStep(fromVersion: version) { data in
            var object = try object(data)
            object["version"] = version + 1
            object["ran", default: [Int]()] = ((object["ran"] as? [Int]) ?? []) + [version]
            return try json(object)
        }
    }

    private static func migrator(current: Int, steps: [DocumentMigrationStep], absent: Int? = nil) -> VersionedDocumentMigrator {
        VersionedDocumentMigrator(versionKey: "version", currentVersion: current, versionWhenAbsent: absent, steps: steps)
    }

    /// What cannot be brought forward: a document already current, one from
    /// a newer build, one older than every step, and one a gap in the chain
    /// leaves behind.
    @Test(arguments: [
        (current: 3, stepsFrom: [Int](), found: 3, expected: VersionedDocumentMigrator.Outcome.current),
        (current: 3, stepsFrom: [3], found: 4, expected: .newer(found: 4)),
        (current: 3, stepsFrom: [], found: 2, expected: .unsupported(found: 2)),
        (current: 4, stepsFrom: [3], found: 2, expected: .unsupported(found: 2))
    ])
    func aDocumentNoStepApplies_isLeftAlone(
        current: Int, stepsFrom: [Int], found: Int, expected: VersionedDocumentMigrator.Outcome
    ) throws {
        let outcome = try Self.migrator(current: current, steps: stepsFrom.map(Self.bump(from:)))
            .migrate(Self.json(["version": found]))
        #expect(outcome == expected)
    }

    @Test func steps_runInOrderToTheCurrentVersion() throws {
        let migrator = Self.migrator(current: 4, steps: [Self.bump(from: 3), Self.bump(from: 2)])
        let outcome = try migrator.migrate(Self.json(["version": 2]))
        guard case let .migrated(from, data) = outcome else {
            Issue.record("expected a migration, got \(outcome)")
            return
        }
        #expect(from == 2)
        let result = try Self.object(data)
        #expect(result["version"] as? Int == 4)
        #expect(result["ran"] as? [Int] == [2, 3])
    }

    @Test func stepThatThrows_propagates() throws {
        struct Boom: Error {}
        let failing = DocumentMigrationStep(fromVersion: 2) { _ in throw Boom() }
        #expect(throws: Boom.self) {
            try Self.migrator(current: 3, steps: [failing]).migrate(Self.json(["version": 2]))
        }
    }

    @Test func stepThatMissesItsVersion_throws() throws {
        let lazy = DocumentMigrationStep(fromVersion: 2) { $0 }
        #expect(throws: VersionedDocumentMigrator.MigrationError.stepProducedWrongVersion(from: 2, found: 2)) {
            try Self.migrator(current: 3, steps: [lazy]).migrate(Self.json(["version": 2]))
        }
    }

    @Test func absentVersion_usesTheDefault() throws {
        let migrator = Self.migrator(current: 2, steps: [Self.bump(from: 1)], absent: 1)
        let outcome = try migrator.migrate(Self.json(["other": true]))
        guard case .migrated(from: 1, _) = outcome else {
            Issue.record("expected a migration from 1, got \(outcome)")
            return
        }
    }

    @Test func absentVersionWithoutDefault_isUnreadable() throws {
        let outcome = try Self.migrator(current: 2, steps: []).migrate(Self.json(["other": true]))
        #expect(outcome == .unreadableVersion)
    }

    @Test(arguments: [#"[1, 2]"#, #"not json"#, #"{"version": "5"}"#, #"{"version": 5.5}"#, #"{"version": true}"#])
    func unreadableDocuments_areReportedNotThrown(text: String) throws {
        let outcome = try Self.migrator(current: 5, steps: []).migrate(Data(text.utf8))
        #expect(outcome == .unreadableVersion)
    }

    @Test func sessionMigrator_matchesTheSnapshotVersion() {
        #expect(VersionedDocumentMigrator.session.currentVersion == SessionSnapshot.currentVersion)
        #expect(VersionedDocumentMigrator.session.versionKey == "version")
    }
}
