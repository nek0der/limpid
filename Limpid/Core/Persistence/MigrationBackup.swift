// MigrationBackup.swift
// Limpid — keeps a copy of a document before a migration rewrites it, once per source.

import CryptoKit
import Foundation
import OSLog

private let log = Logger.limpid("persistence.migration-backup")

/// What the ledger beside a migrated document remembers: which bytes were
/// copied where, and how far the migration got.
struct MigrationBackupRecord: Codable, Equatable {
    enum Stage: String, Codable {
        /// The copy exists; the migrated document may not have been written.
        case backedUp
        /// The migrated document was written over the original.
        case written
        /// Written, and an earlier build told the person so. No longer
        /// written; kept so the ledgers such a build left still decode, as
        /// one that does not counts as absent.
        case acknowledged
    }

    var sourceSHA256: String
    /// The SHA-256 of the bytes the migration writes, or of the first save
    /// that wrote the migrated document when the migration's own write
    /// failed (`markWritten(_:for:bytes:)`). A relaunch counts the migration
    /// as written only when the document on disk is exactly these bytes:
    /// "different from the source" would also match a file that a later
    /// save replaced with an empty session after the original was set aside.
    var migratedSHA256: String
    var fromVersion: Int
    var toVersion: Int
    /// The copy's file name, beside the document.
    var backupFileName: String
    var stage: Stage
}

/// The copy taken before a migration writes over a document, and the ledger
/// that lets a relaunch reuse it.
///
/// The migrated document is written right after the copy, but the process can
/// end at any point in between. The next launch sees the same old document
/// and migrates it again; if it took a fresh copy every time, each crash would
/// add one more. So a copy is matched by content: the ledger records the
/// source's SHA-256, and when the ledger is missing (the process ended
/// between the copy and the ledger) the existing copies are hashed instead.
/// Only a source that changed since (an older build ran and saved again) gets
/// a new generation.
enum MigrationBackup {
    enum BackupError: LimpidLocalizedError, Equatable {
        /// No free name for the copy; refusing rather than overwriting one.
        case noFreeBackupName
        /// The copy or the ledger could not be written. The underlying error
        /// goes to the log; the person only needs to know nothing changed.
        case copyFailed

        var message: DisplayText {
            .localized(text)
        }

        private var text: LocalizedStringResource {
            switch self {
            case .noFreeBackupName:
                // swiftlint:disable:next line_length
                "Limpid couldn’t back up the saved file before updating it, because too many earlier backups are next to it. The file wasn’t changed."
            case .copyFailed:
                "Limpid couldn’t back up the saved file before updating it. The file wasn’t changed."
            }
        }
    }

    /// `<name>.migration.json` beside the document.
    static func ledgerURL(for document: URL) -> URL {
        document.deletingLastPathComponent()
            .appendingPathComponent("\(document.lastPathComponent).migration.json")
    }

    /// Copies `source` (the document's current bytes) beside `document`
    /// before a migration to `toVersion` writes `migrated`, or returns the
    /// copy a previous attempt already took of the same bytes. A copy is
    /// reused only after its own bytes are read back and match: a copy that
    /// was damaged or replaced since would leave nothing to go back to once
    /// the original is overwritten.
    ///
    /// Throws `BackupError` when the copy or the ledger cannot be written; the
    /// caller must then leave the document as it is and not write the
    /// migrated one.
    static func keep(
        _ document: URL,
        source: Data,
        migrated: Data,
        from fromVersion: Int,
        to toVersion: Int,
        now: Date = Date()
    ) throws -> MigrationBackupRecord {
        let directory = document.deletingLastPathComponent()
        let digest = sha256(source)
        let migratedDigest = sha256(migrated)
        let reusable = readLedger(for: document).flatMap { existing -> String? in
            guard existing.sourceSHA256 == digest, existing.toVersion == toVersion else { return nil }
            return file(at: directory.appendingPathComponent(existing.backupFileName), matches: digest)
                ? existing.backupFileName : nil
        }
        do {
            let backupName: String
            if let copy = reusable ?? existingCopy(of: digest, for: document, toVersion: toVersion) {
                backupName = copy
            } else {
                let backup = try freeBackupURL(for: document, toVersion: toVersion, now: now)
                try SecureFileWrite.writeAtomic(source, to: backup)
                backupName = backup.lastPathComponent
            }
            let record = MigrationBackupRecord(
                sourceSHA256: digest,
                migratedSHA256: migratedDigest,
                fromVersion: fromVersion,
                toVersion: toVersion,
                backupFileName: backupName,
                stage: .backedUp
            )
            // Written even when the copy is reused: the migrated bytes of
            // this attempt are the ones a relaunch must find.
            try writeLedger(record, for: document)
            let name = document.lastPathComponent
            log.notice("kept \(name, privacy: .public) v\(fromVersion, privacy: .public) as \(backupName, privacy: .public)")
            return record
        } catch let error as BackupError {
            throw error
        } catch {
            log.error("migration backup failed: \(String(describing: error), privacy: .private)")
            throw BackupError.copyFailed
        }
    }

    /// Moves the ledger to `written` when the document on disk is exactly
    /// the migrated bytes it recorded. Does nothing otherwise.
    ///
    /// A launch can end after writing the migrated document but before
    /// `markWritten`. The next launch reads a current document and never
    /// migrates, so without this the ledger would say `backedUp` forever
    /// about a migration that reached disk.
    static func finishIfWritten(_ document: URL, current: Data, version: Int) {
        guard let record = readLedger(for: document),
              record.stage == .backedUp,
              record.toVersion == version,
              record.migratedSHA256 == sha256(current)
        else { return }
        do {
            try markWritten(record, for: document)
        } catch {
            // The ledger stays at `backedUp` and the next launch tries again;
            // nothing about the document depends on it.
            log.error("migration ledger update failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// The ledger of a migration this save is about to finish, for a store
    /// that keeps no record between its load and its save: still `backedUp`,
    /// with the document on disk exactly the original it copied (the
    /// migration's own write failed) or the migrated bytes it recorded (the
    /// ledger update after it failed). `nil` otherwise. A document set aside
    /// or replaced since is neither, so a save that only starts it afresh
    /// does not count as the migrated one.
    static func unfinishedRecord(for document: URL, version: Int) -> MigrationBackupRecord? {
        guard let record = readLedger(for: document),
              record.stage == .backedUp,
              record.toVersion == version,
              let current = try? Data(contentsOf: document)
        else { return nil }
        let digest = sha256(current)
        return digest == record.sourceSHA256 || digest == record.migratedSHA256 ? record : nil
    }

    /// Records that the migrated document is on disk, and returns the record
    /// as it now stands. `bytes` is what was written when that was not the
    /// migration's own output (a later save of the migrated document, after
    /// the migration's write failed), so a relaunch matches the file it
    /// finds.
    @discardableResult
    static func markWritten(
        _ record: MigrationBackupRecord,
        for document: URL,
        bytes: Data? = nil
    ) throws -> MigrationBackupRecord {
        var written = record
        written.stage = .written
        if let bytes {
            written.migratedSHA256 = sha256(bytes)
        }
        try writeLedger(written, for: document)
        return written
    }

    /// The ledger, or `nil` when it is absent or unreadable. An unreadable
    /// ledger only costs the lookup of an existing copy by content, so it
    /// is not an error.
    static func readLedger(for document: URL) -> MigrationBackupRecord? {
        guard let data = try? Data(contentsOf: ledgerURL(for: document)) else { return nil }
        return try? JSONDecoder().decode(MigrationBackupRecord.self, from: data)
    }

    private static func writeLedger(_ record: MigrationBackupRecord, for document: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SecureFileWrite.writeAtomic(encoder.encode(record), to: ledgerURL(for: document))
    }

    /// The name of a copy for `toVersion` that already holds `digest`, left by
    /// a launch that ended before it wrote the ledger.
    private static func existingCopy(of digest: String, for document: URL, toVersion: Int) -> String? {
        let directory = document.deletingLastPathComponent()
        let base = "\(document.lastPathComponent).pre-v\(toVersion)"
        // An unreadable directory only costs one extra copy, as with the ledger.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0 == base || $0.hasPrefix("\(base).") }
            .sorted()
            .first { file(at: directory.appendingPathComponent($0), matches: digest) }
    }

    /// Whether the file at `url` reads back as exactly the bytes `digest`
    /// names. An unreadable file does not.
    private static func file(at url: URL, matches digest: String) -> Bool {
        (try? Data(contentsOf: url)).map(sha256) == digest
    }

    /// `<name>.pre-v<N>` the first time, `<name>.pre-v<N>.<unix>` after that,
    /// with a counter if two generations land in the same second.
    private static func freeBackupURL(for document: URL, toVersion: Int, now: Date) throws -> URL {
        let directory = document.deletingLastPathComponent()
        let base = "\(document.lastPathComponent).pre-v\(toVersion)"
        let stamp = Int(now.timeIntervalSince1970)
        let candidates = [base, "\(base).\(stamp)"] + (1...99).map { "\(base).\(stamp)-\($0)" }
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw BackupError.noFreeBackupName
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
