// ReviewDraftStore.swift
// Weir — the review draft on disk, apart from the state it restores.

import Foundation
import OSLog

private let log = Logger.weir("review.draft")

/// What one repository's review is between sessions: the comments, and which
/// files the reader has finished with, each by the comparison it belongs to.
struct ReviewDraft: Codable {
    static let currentVersion = 2

    /// Which shape the rest of the file is in. A key that is renamed or
    /// nested fails to decode on its own, but one merely bundled into a new
    /// optional would read as absent, so a change of shape bumps this and a
    /// step in `ReviewDraftMigrator` brings the older files forward.
    var version = Self.currentVersion
    /// Each with the scopes it belongs to. A comment kept for two scopes is
    /// here once.
    var comments: [ReviewComment] = []
    /// Read marks by scope ID, then by `ReviewFile.id`: a file read in one
    /// comparison is not read in another.
    var viewed: [String: [String: ReviewViewMark]] = [:]
    /// The file the reader had open, by scope ID, so reopening review returns
    /// to it.
    ///
    /// Beside the read marks because it is the same kind of thing: where this
    /// reader had got to in this worktree. Closing review is one keystroke and
    /// an insert does it too, and coming back to the top of the first changed
    /// file meant finding your place again by hand every time — a real cost in
    /// a fifty-file branch, where the file you were in is the whole context.
    ///
    /// Only ever a hint: the file may be gone by the time it is read back, in
    /// which case the first changed file answers as before.
    var lastFileID: [String: String] = [:]
    /// Comments a version 1 draft held whose scope cannot be proven (a turn's,
    /// a branch's): shown, and moved into a scope only by the reader, after
    /// the insert's check. `nil` when there are none.
    var legacy: [ReviewComment]?
    /// The fixed ranges of turns the comments and marks above belong to, so
    /// a comment written against one range is still checked against it
    /// after review moves on. `nil` when there are none.
    var ranges: [ReviewTurnRange]?

    /// Every comment, scoped or not, for the limits that bound the file.
    var allComments: [ReviewComment] {
        comments + (legacy ?? [])
    }
}

/// Why a draft was read but must not be saved over this launch.
enum ReviewDraftLoadError: Error {
    /// The file could not be used, and could not be moved out of the way
    /// either. It is the only copy, so the review starts empty and saves
    /// nothing.
    case keptInPlace
    /// An older draft was brought forward, but no copy of the original could
    /// be kept, so the original is left as it is and the draft is used
    /// without being saved.
    case migratedWithoutCopy(ReviewDraft)
}

/// Reading and writing a draft, named so the writer can be exercised without a
/// filesystem and so the file format can change without touching the state
/// machine that produces it.
protocol ReviewDraftStoring: Sendable {
    /// The draft for this repository, or `nil` when there is none. Throws when
    /// one exists and cannot be trusted — the caller starts empty and says so.
    func load(root: URL) throws -> ReviewDraft?
    func save(_ draft: ReviewDraft, root: URL) throws
}

/// The draft as a file under the reviews directory, one per repository.
struct FileReviewDraftStore: ReviewDraftStoring {
    let directory: URL

    /// The cap `load` refuses, applied on the way out as well: a draft written
    /// past it is one this app will not read back, and every caller that can
    /// grow the unresolved count already answers for that with a message of
    /// its own. The session's cap, so what it lets a person add is what this
    /// writes and reads back.
    static let maxComments = ReviewSession.maxComments
    static let maxBytes = 2 * 1024 * 1024

    /// The draft's versions, and the step from each to the next.
    static let migrator = VersionedDocumentMigrator(
        versionKey: "version",
        currentVersion: ReviewDraft.currentVersion,
        versionWhenAbsent: nil,
        steps: [ReviewDraftMigrator.step]
    )

    /// Where a repository's draft is kept. Static so the deletion path can
    /// name it without a store: the reader deleting a worktree is not
    /// reviewing it.
    static func url(root: URL, directory: URL) -> URL {
        directory.appendingPathComponent(
            ReviewDiff.hash(Data(root.resolvingSymlinksInPath().path.utf8)) + ".json"
        )
    }

    func load(root: URL) throws -> ReviewDraft? {
        let file = Self.url(root: root, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data: Data
        let outcome: VersionedDocumentMigrator.Outcome
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
            guard data.count <= Self.maxBytes else { throw ReviewError.storageFailed }
            outcome = try Self.migrator.migrate(data)
        } catch {
            try Self.setAside(file, reason: "decode-failed")
        }
        switch outcome {
        case .current:
            let draft = try decodeOrSetAside(data, file: file)
            // A launch can end after writing the migrated draft but before
            // its ledger; this read never migrates, so it finishes the ledger
            // when the file is exactly the bytes the migration recorded.
            MigrationBackup.finishIfWritten(file, current: data, version: ReviewDraft.currentVersion)
            return draft
        case let .migrated(from, migrated):
            let draft = try decodeOrSetAside(migrated, file: file)
            try writeMigrated(draft, source: data, from: from, file: file)
            return draft
        case .newer:
            // A newer build's draft. Moved aside rather than read: its shape
            // may hold what this build would drop on the next save. The newer
            // build does not read it back on its own; the person can put it
            // back (`docs/data-migration.md`).
            try Self.setAside(file, reason: "newer-version")
        case .unsupported, .unreadableVersion:
            try Self.setAside(file, reason: "decode-failed")
        }
    }

    /// Moves a draft this build cannot use out of the way and refuses it. When
    /// it cannot be moved it is the only copy, so the writer must not save
    /// over it this launch (`ReviewDraftLoadError.keptInPlace`).
    private static func setAside(_ file: URL, reason: String) throws -> Never {
        switch SecureFileWrite.setAside(file, reason: reason) {
        case .cleared: throw ReviewError.storageFailed
        case .keptInPlace: throw ReviewDraftLoadError.keptInPlace
        }
    }

    /// The draft in `data`, checked against the limits `save` keeps, or the
    /// file moved aside.
    private func decodeOrSetAside(_ data: Data, file: URL) throws -> ReviewDraft {
        let draft: ReviewDraft
        do {
            // Paired with `makeEncoder`, which writes dates as ISO 8601. A
            // bare decoder read every draft correctly until a comment first
            // carried a date, and then read none of them.
            draft = try PersistenceCoders.makeDecoder().decode(ReviewDraft.self, from: data)
        } catch {
            try Self.setAside(file, reason: "decode-failed")
        }
        // Against the unresolved count, the same as `add` — a draft whose
        // resolved comments had grown past the cap would otherwise be refused
        // whole on the next launch, which reads as the drafts having been
        // lost. And a run has to stay a run: nothing else bounds what a file
        // on disk claims, and the row counts walk every id in the range, so
        // one corrupt end would hang the surface rather than fail it.
        guard draft.allComments.count(where: { !$0.isResolved }) <= Self.maxComments,
              draft.allComments.allSatisfy({ $0.lineID >= 0 && $0.lastLineID - $0.lineID <= ReviewDiffParser.maxRows })
        else {
            // Moved aside rather than kept, and saving stays on. Refusing to
            // save was meant to protect a draft we could not read, but nothing
            // ever turned it back on: one draft written past a limit locked
            // that repository out of review for good, with the only way back
            // being to find the file and delete it. The reader starts from an
            // empty draft and their bytes survive beside it, which is what
            // `SettingsStore` and `SessionStore` already do.
            try Self.setAside(file, reason: "decode-failed")
        }
        return draft
    }

    /// Writes the migrated draft over the original, after a copy of the
    /// original is kept beside it (`MigrationBackup`), so going back to the
    /// build before still finds its draft. Nobody is told: a draft is one
    /// file per repository, and the migration changes nothing the reader
    /// sees.
    ///
    /// When the copy cannot be made the original stays as it is, and the
    /// migrated draft is used without being saved this launch
    /// (`ReviewDraftLoadError.migratedWithoutCopy`), as settings do; the next
    /// launch migrates it again. A failed write after the copy only leaves
    /// the original, which the next save or the next launch replaces, the
    /// copy already kept; that save finishes the ledger (`finishMigration`).
    private func writeMigrated(_ draft: ReviewDraft, source: Data, from: Int, file: URL) throws {
        let encoded: Data
        do {
            encoded = try PersistenceCoders.makeEncoder().encode(draft)
        } catch {
            throw ReviewDraftLoadError.migratedWithoutCopy(draft)
        }
        // Grown past the limit by what version 2 adds: a file this build
        // would refuse on the next launch. Set aside unmigrated, like any
        // draft this build cannot use.
        guard encoded.count <= Self.maxBytes else {
            try Self.setAside(file, reason: "migration-too-large")
        }
        let record: MigrationBackupRecord
        do {
            record = try MigrationBackup.keep(file, source: source, migrated: encoded, from: from, to: ReviewDraft.currentVersion)
        } catch {
            log.error("review draft backup failed: \(String(describing: error), privacy: .private)")
            throw ReviewDraftLoadError.migratedWithoutCopy(draft)
        }
        do {
            try SecureFileWrite.writeAtomic(encoded, to: file)
            try MigrationBackup.markWritten(record, for: file)
        } catch {
            log.error("review draft migration not written: \(String(describing: error), privacy: .private)")
        }
    }

    func save(_ draft: ReviewDraft, root: URL) throws {
        let file = Self.url(root: root, directory: directory)
        SecureFileWrite.ensureUserOnlyDirectory(file.deletingLastPathComponent())
        guard draft.allComments.count(where: { !$0.isResolved }) <= Self.maxComments else {
            throw ReviewError.commentLimitReached
        }
        let data = try PersistenceCoders.makeEncoder().encode(draft)
        guard data.count <= Self.maxBytes else {
            throw draft.allComments.contains(where: \.isResolved) ? ReviewError.resolvedBacklogTooLarge : ReviewError.storageFailed
        }
        // Looked up before the write, which replaces the bytes it matches.
        let unfinished = MigrationBackup.unfinishedRecord(for: file, version: ReviewDraft.currentVersion)
        try SecureFileWrite.writeAtomic(data, to: file)
        if let unfinished {
            Self.finishMigration(unfinished, of: file, wrote: data)
        }
    }

    /// Finishes a migration whose own write failed: the original stayed
    /// under the copy already kept, and this save is the first to put the
    /// migrated draft on disk. The ledger records these bytes so a relaunch
    /// matches the file it finds (`MigrationBackup.markWritten`).
    ///
    /// Found through the ledger rather than held from the load, since the
    /// store keeps nothing between the two
    /// (`MigrationBackup.unfinishedRecord`). A ledger that fails to update
    /// stays at `backedUp`; nothing about the draft depends on it.
    private static func finishMigration(_ record: MigrationBackupRecord, of file: URL, wrote data: Data) {
        do {
            try MigrationBackup.markWritten(record, for: file, bytes: data)
        } catch {
            log.error("review draft migration ledger update failed: \(String(describing: error), privacy: .private)")
        }
    }
}

/// A draft that lives only as long as the writer holding it, for demo mode and
/// for tests that have nothing to say about the filesystem.
struct EphemeralReviewDraftStore: ReviewDraftStoring {
    func load(root _: URL) throws -> ReviewDraft? {
        nil
    }

    func save(_: ReviewDraft, root _: URL) throws {}
}

/// We serialize all draft writes and deletions on this queue. The snapshot
/// generation is protected by a separate lock so scheduling never waits on disk I/O.
/// Edits and deletions invalidate navigation snapshots before their asynchronous hop.
final class ReviewDraftWriteCoordinator: @unchecked Sendable {
    static let shared = ReviewDraftWriteCoordinator()
    private let queue = DispatchQueue(label: "com.nekoder.weir.review.draft-write")
    private let generationLock = NSLock()
    private var generations: [URL: UUID] = [:]

    func beginNavigation(for root: URL) -> UUID {
        generationLock.withLock {
            let generation = UUID()
            generations[root] = generation
            return generation
        }
    }

    func save(_ draft: ReviewDraft, root: URL, storage: any ReviewDraftStoring) throws {
        try queue.sync {
            generationLock.withLock { generations[root] = UUID() }
            try storage.save(draft, root: root)
        }
    }

    func saveNavigation(
        _ draft: ReviewDraft, root: URL, storage: any ReviewDraftStoring, generation: UUID
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    guard self.generationLock.withLock({ self.generations[root] == generation }) else { return false }
                    try storage.save(draft, root: root)
                    return true
                })
            }
        }
    }

    /// Deletes the draft of a worktree being deleted, with what was kept
    /// beside it (the copy taken before a migration, its ledger, and drafts
    /// set aside): all of them quote that worktree's code.
    func remove(root: URL, directory: URL) {
        queue.sync {
            generationLock.withLock { generations[root] = UUID() }
            let draft = FileReviewDraftStore.url(root: root, directory: directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name == draft.lastPathComponent || name.hasPrefix(draft.lastPathComponent + ".") {
                try? SecureFileWrite.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
