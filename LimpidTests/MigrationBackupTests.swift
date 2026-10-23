// MigrationBackupTests.swift
// Limpid — the copy kept before a migration, reused for the same source.

import Foundation
import Testing
@testable import Limpid

@Suite(.tags(.persistence))
struct MigrationBackupTests {
    /// What the migration writes, for the tests that do not look at it.
    private static let migrated = Data(#"{"version":6}"#.utf8)

    private static func backups(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".pre-v") }
            .sorted()
    }

    @Test func firstBackup_copiesTheBytesUserOnly() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let record = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)

            #expect(record.backupFileName == "state.json.pre-v6")
            #expect(record.stage == .backedUp)
            let backup = dir.appendingPathComponent(record.backupFileName)
            #expect(try Data(contentsOf: backup) == source)
            let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            #expect(MigrationBackup.readLedger(for: document) == record)
        }
    }

    @Test func sameSource_reusesTheBackup() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let first = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)
            // A relaunch after a crash between the copy and the write.
            let second = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)

            #expect(first == second)
            #expect(try Self.backups(in: dir) == ["state.json.pre-v6"])
        }
    }

    @Test func changedSource_getsANewGeneration() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try MigrationBackup.keep(
                document,
                source: Data(#"{"version":5,"a":1}"#.utf8),
                migrated: Self.migrated,
                from: 5,
                to: 6,
                now: now
            )
            // An older build ran in between and saved different bytes.
            let changed = Data(#"{"version":5,"a":2}"#.utf8)
            let record = try MigrationBackup.keep(document, source: changed, migrated: Self.migrated, from: 5, to: 6, now: now)

            #expect(record.backupFileName == "state.json.pre-v6.1800000000")
            #expect(try Self.backups(in: dir) == ["state.json.pre-v6", "state.json.pre-v6.1800000000"])
            #expect(try Data(contentsOf: dir.appendingPathComponent(record.backupFileName)) == changed)
            // The first generation is never overwritten.
            #expect(try Data(contentsOf: dir.appendingPathComponent("state.json.pre-v6")) == Data(#"{"version":5,"a":1}"#.utf8))
        }
    }

    @Test func generationsInTheSameSecond_doNotCollide() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 0..<3 {
                _ = try MigrationBackup.keep(
                    document,
                    source: Data("{\"version\":5,\"i\":\(index)}".utf8),
                    migrated: Self.migrated,
                    from: 5,
                    to: 6,
                    now: now
                )
            }
            #expect(try Self.backups(in: dir) == [
                "state.json.pre-v6",
                "state.json.pre-v6.1800000000",
                "state.json.pre-v6.1800000000-1"
            ])
        }
    }

    @Test func missingBackupFile_isTakenAgain() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let first = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)
            try FileManager.default.removeItem(at: dir.appendingPathComponent(first.backupFileName))
            let second = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)

            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(second.backupFileName).path))
        }
    }

    @Test func unreadableLedger_findsTheCopyByContent() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let first = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)
            try Data("garbage".utf8).write(to: MigrationBackup.ledgerURL(for: document))
            let record = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)

            #expect(record == first)
            #expect(try Self.backups(in: dir).count == 1)
        }
    }

    @Test func copyWithoutALedger_isReusedOnlyForTheSameBytes() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            try Data(#"{"version":5,"old":true}"#.utf8).write(to: dir.appendingPathComponent("state.json.pre-v6"))
            let record = try MigrationBackup.keep(
                document,
                source: Data(#"{"version":5}"#.utf8),
                migrated: Self.migrated,
                from: 5,
                to: 6,
                now: Date(timeIntervalSince1970: 1000)
            )

            #expect(record.backupFileName == "state.json.pre-v6.1000")
            #expect(try Self.backups(in: dir).count == 2)
        }
    }

    @Test func finishIfWritten_onlyForTheMigratedBytes() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let record = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)

            // Still the source: the migrated file was never written.
            MigrationBackup.finishIfWritten(document, current: source, version: 6)
            #expect(MigrationBackup.readLedger(for: document)?.stage == .backedUp)
            // A current file that is not the migration (an empty session saved
            // after the original was set aside) proves nothing.
            MigrationBackup.finishIfWritten(document, current: Data(#"{"version":6,"tabs":[]}"#.utf8), version: 6)
            #expect(MigrationBackup.readLedger(for: document)?.stage == .backedUp)
            // Another target version is not this migration.
            MigrationBackup.finishIfWritten(document, current: Self.migrated, version: 7)
            #expect(MigrationBackup.readLedger(for: document)?.stage == .backedUp)

            MigrationBackup.finishIfWritten(document, current: Self.migrated, version: 6)
            var written = record
            written.stage = .written
            #expect(MigrationBackup.readLedger(for: document) == written)
        }
    }

    /// A ledger an earlier build marked as told still decodes rather than
    /// counting as absent.
    @Test func aLedgerAnEarlierBuildMarkedAsTold_stillReads() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            var record = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)
            record.stage = .acknowledged
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: MigrationBackup.ledgerURL(for: document))

            #expect(MigrationBackup.readLedger(for: document) == record)
        }
    }

    @Test func aRetry_recordsItsOwnMigratedBytes() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let first = try MigrationBackup.keep(document, source: source, migrated: Data("A".utf8), from: 5, to: 6)
            let second = try MigrationBackup.keep(document, source: source, migrated: Data("B".utf8), from: 5, to: 6)
            #expect(second.backupFileName == first.backupFileName)

            MigrationBackup.finishIfWritten(document, current: Data("A".utf8), version: 6)
            #expect(MigrationBackup.readLedger(for: document)?.stage == .backedUp)
            MigrationBackup.finishIfWritten(document, current: Data("B".utf8), version: 6)
            #expect(MigrationBackup.readLedger(for: document)?.stage == .written)
        }
    }

    @Test func aDamagedCopy_isNotReused() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let source = Data(#"{"version":5}"#.utf8)
            let first = try MigrationBackup.keep(document, source: source, migrated: Self.migrated, from: 5, to: 6)
            try Data("damaged".utf8).write(to: dir.appendingPathComponent(first.backupFileName))

            let second = try MigrationBackup.keep(
                document,
                source: source,
                migrated: Self.migrated,
                from: 5,
                to: 6,
                now: Date(timeIntervalSince1970: 1000)
            )

            #expect(second.backupFileName != first.backupFileName)
            #expect(try Data(contentsOf: dir.appendingPathComponent(second.backupFileName)) == source)
        }
    }

    @Test func everyNameTaken_throwsRatherThanOverwriting() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let names = ["state.json.pre-v6", "state.json.pre-v6.1000"] + (1...99).map { "state.json.pre-v6.1000-\($0)" }
            for name in names {
                try Data("other".utf8).write(to: dir.appendingPathComponent(name))
            }
            #expect(throws: MigrationBackup.BackupError.noFreeBackupName) {
                try MigrationBackup.keep(
                    document,
                    source: Data(#"{"version":5}"#.utf8),
                    migrated: Self.migrated,
                    from: 5,
                    to: 6,
                    now: Date(timeIntervalSince1970: 1000)
                )
            }
            #expect(try Data(contentsOf: dir.appendingPathComponent("state.json.pre-v6")) == Data("other".utf8))
        }
    }

    @Test func unwritableDirectory_throwsWithoutALedger() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("missing").appendingPathComponent("state.json")
            #expect(throws: MigrationBackup.BackupError.copyFailed) {
                try MigrationBackup.keep(document, source: Data(#"{"version":5}"#.utf8), migrated: Self.migrated, from: 5, to: 6)
            }
            #expect(MigrationBackup.readLedger(for: document) == nil)
        }
    }
}
