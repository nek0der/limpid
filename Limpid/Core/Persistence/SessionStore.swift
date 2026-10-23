// SessionStore.swift
// Limpid — reads/writes the session snapshot to disk under the
// per-build Application Support directory resolved by `LimpidPaths`
// (`Limpid/` for Release, `Limpid Dev/` for Debug, a per-run temporary
// folder for the XCTest host). Tests should inject a `WithTempDir` URL via
// `init(directory:)` rather than rely on the default.
//
// We debounce writes with a small leading-edge timer so a burst of
// changes (e.g. resizing the sidebar) doesn't slam the file system.

import Foundation
import OSLog

private let log = Logger.limpid("session.store")

extension VersionedDocumentMigrator {
    /// `state.json`: version 5 is brought to 6 (`SessionSnapshotV5`);
    /// anything older is set aside.
    static let session = VersionedDocumentMigrator(
        versionKey: "version",
        currentVersion: SessionSnapshot.currentVersion,
        versionWhenAbsent: nil,
        steps: [SessionSnapshotV5.step]
    )
}

@MainActor
final class SessionStore {
    /// `state.json`. Read outside for the notice that names it while
    /// saving is suspended.
    let fileURL: URL
    private let migrator: VersionedDocumentMigrator
    private let saveDebounce = DebouncedSave()
    private let queue = DispatchQueue(label: "dev.limpid.session-store")
    /// Set when the file this build cannot use could not be moved aside.
    /// Saving would then write over the only copy, so every save is skipped
    /// until the next launch tries again.
    private(set) var isSavingSuspended = false
    /// A migration whose copy and ledger exist but whose write failed. The
    /// session is in use from memory, and the first save that reaches disk
    /// finishes the ledger with the bytes it wrote, so the ledger says the
    /// migration was written, as it would have.
    private var pendingMigration: MigrationBackupRecord?
    /// See `init`.
    private let writesFiles: Bool

    /// The app builds it with the support directory and its own decision on
    /// writing; tests pass an isolated temp directory so they don't clobber
    /// the user's real state.json. `migrator` is injectable so tests can
    /// drive the migration path before production has a step to run.
    ///
    /// `writesFiles` is false in demo mode, which the app decides: the
    /// store then neither creates its directory nor saves. `load()` still
    /// sets aside and migrates what it reads, so a run that may not write
    /// does not call it; the app shows `DemoFixture` instead.
    init(directory: URL, migrator: VersionedDocumentMigrator = .session, writesFiles: Bool = true) {
        if writesFiles {
            SecureFileWrite.ensureUserOnlyDirectory(directory)
        }
        self.fileURL = directory.appendingPathComponent("state.json")
        self.migrator = migrator
        self.writesFiles = writesFiles
    }

    /// Outcome of attempting to restore the persisted session.
    /// Surfacing version mismatches and decode failures separately
    /// lets the boot path show a user-visible warning instead of
    /// silently dropping a corrupted file (and the user's history).
    /// `decodeFailed` also carries a failed migration step, a backup that
    /// could not be taken, a migrated file that does not decode, and a file
    /// that is there but could not be read.
    enum LoadOutcome {
        /// No `state.json` at all: a first launch.
        case absent
        case loaded(SessionSnapshot)
        case versionMismatch(found: Int, expected: Int)
        case decodeFailed(any Error)
    }

    func load() -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            // A file that is there but cannot be read (its permissions, an
            // I/O error) is not a first launch. It may be readable again
            // by the time this launch saves, and that save must not
            // replace it with the fresh session.
            log.error("failed to read snapshot: \(String(describing: error), privacy: .private)")
            setAsideUnread()
            return .decodeFailed(error)
        }
        let outcome: VersionedDocumentMigrator.Outcome
        do {
            outcome = try migrator.migrate(data)
        } catch {
            // A step that throws leaves the file as it was; moving it aside
            // keeps the next save from replacing it with an empty session.
            log.error("snapshot migration failed: \(String(describing: error), privacy: .private)")
            setAside(reason: "migration-failed")
            return .decodeFailed(error)
        }
        switch outcome {
        case let .newer(found), let .unsupported(found):
            log.notice("snapshot version \(found, privacy: .public) cannot be read by this build")
            setAside(reason: "version-mismatch")
            return .versionMismatch(found: found, expected: SessionSnapshot.currentVersion)
        case let .migrated(from, migrated):
            return loadMigrated(original: data, migrated: migrated, from: from)
        case .current, .unreadableVersion:
            return decodeCurrent(data)
        }
    }

    /// Decodes a file already at the current version. An unreadable version
    /// lands here too, so the decoder reports what is actually wrong.
    private func decodeCurrent(_ data: Data) -> LoadOutcome {
        do {
            let decoder = PersistenceCoders.makeDecoder()
            let snapshot = try decoder.decode(SessionSnapshot.self, from: data)
            // The migrator has already compared versions, so this only
            // catches a file whose version it could not read but the decoder
            // could; it is treated like any other mismatch.
            guard snapshot.version == SessionSnapshot.currentVersion else {
                log
                    .notice(
                        """
                        snapshot version mismatch (got \
                        \(snapshot.version, privacy: .public), want \
                        \(SessionSnapshot.currentVersion, privacy: .public))
                        """
                    )
                // Move the unsupported snapshot aside so the next save
                // doesn't destroy it.
                setAside(reason: "version-mismatch")
                return .versionMismatch(
                    found: snapshot.version,
                    expected: SessionSnapshot.currentVersion
                )
            }
            // Refreshed on load as well as on save: an upgrade that adds this
            // file would otherwise leave the worktree hook with nothing to
            // read until the first save, and it would quietly pass every
            // interception through in the meantime.
            WorktreeRouting.write(projects: snapshot.projects, beside: fileURL)
            MigrationBackup.finishIfWritten(fileURL, current: data, version: SessionSnapshot.currentVersion)
            return .loaded(snapshot)
        } catch {
            log.error("failed to decode snapshot: \(String(describing: error), privacy: .private)")
            // We absolutely don't want the next `scheduleSave` to clobber
            // a file the user might still recover from. Rename it now,
            // before any mutation triggers a write.
            setAside(reason: "decode-failed")
            return .decodeFailed(error)
        }
    }

    /// Moves a file this build cannot use out of the way before anything
    /// saves. If it cannot be moved, saving stops instead: the next save
    /// would otherwise replace it with whatever session this launch starts.
    private func setAside(reason: String) {
        guard SecureFileWrite.setAside(fileURL, reason: reason) == .keptInPlace else { return }
        log.error("state.json stays in place; saving is suspended for this launch")
        isSavingSuspended = true
    }

    /// `setAside` for a file that could not be read. Saving goes on only
    /// once the file has actually moved: a folder that cannot be searched
    /// hides the file from `setAside`'s check that it is still there, and
    /// the file would then be replaced once the folder opens up again.
    private func setAsideUnread() {
        guard SecureFileWrite.quarantine(fileURL, reason: "read-failed") == nil else { return }
        log.error("unreadable state.json stays in place; saving is suspended for this launch")
        isSavingSuspended = true
    }

    /// Keeps a copy of the old file, then writes the migrated one at once
    /// rather than on the next save: a launch that ends before any edit would
    /// otherwise migrate again next time and leave the user on the old file
    /// indefinitely. The copy is reused across relaunches of the same source
    /// (`MigrationBackup`), so a crash between the copy and the write does
    /// not pile up copies.
    private func loadMigrated(original: Data, migrated: Data, from: Int) -> LoadOutcome {
        // Decoded and encoded before the copy, so a step that produces
        // something today's types cannot read leaves no copy or ledger
        // behind, and the ledger can name the exact bytes that get written.
        let snapshot: SessionSnapshot
        let encoded: Data
        do {
            snapshot = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: migrated)
            encoded = try PersistenceCoders.makeEncoder().encode(snapshot)
        } catch {
            log.error("migrated snapshot does not decode or encode: \(String(describing: error), privacy: .private)")
            setAside(reason: "decode-failed")
            return .decodeFailed(error)
        }
        let record: MigrationBackupRecord
        do {
            record = try MigrationBackup.keep(
                fileURL,
                source: original,
                migrated: encoded,
                from: from,
                to: SessionSnapshot.currentVersion
            )
        } catch {
            // Without a copy we do not write over the only one; the file
            // is moved aside unchanged, like any file this build cannot use.
            log.error("snapshot backup failed: \(String(describing: error), privacy: .private)")
            setAside(reason: "backup-failed")
            return .decodeFailed(error)
        }
        do {
            try Self.writeSnapshot(projects: snapshot.projects, bytes: encoded, to: fileURL)
        } catch {
            // The session is still usable from memory and the next save
            // writes it, finishing the ledger then. Until then it stays at
            // `backedUp`, so a relaunch first reuses the same copy.
            log.error("migrated snapshot write failed: \(String(describing: error), privacy: .private)")
            pendingMigration = record
            return .loaded(snapshot)
        }
        do {
            try MigrationBackup.markWritten(record, for: fileURL)
        } catch {
            // The file is on disk; only the ledger lags. A relaunch finishes
            // the ledger from the bytes on disk.
            log.error("migration ledger update failed: \(String(describing: error), privacy: .private)")
        }
        log.notice("migrated state.json from v\(from, privacy: .public)")
        return .loaded(snapshot)
    }

    /// Debounced save. Coalesces a burst of mutations into a single
    /// write 400ms after the last call. The snapshot value crosses
    /// onto the background queue inside the work item — `SessionSnapshot`
    /// is value-typed (Sendable) so the capture is safe.
    func scheduleSave(_ snapshot: SessionSnapshot) {
        // A demo run shows `DemoFixture`; writing it would replace the
        // person's state.json with the fixture.
        guard writesFiles, !isSavingSuspended else { return }
        let url = fileURL
        saveDebounce.schedule { [queue, snapshot, weak self] in
            // This runs on the main actor, where the unfinished migration is
            // read as it stands when the write starts, not when it was
            // scheduled.
            let pendingMigration = self?.pendingMigration
            queue.async {
                guard Self.write(snapshot, to: url, finishing: pendingMigration) else { return }
                DispatchQueue.main.async { self?.didFinishMigration() }
            }
        }
    }

    /// Synchronous save — pending work is canceled and the snapshot is
    /// written through the same serial queue so it cannot race against a
    /// debounced write that may already be in flight. Call from
    /// applicationWillTerminate so the file actually lands before the
    /// process exits.
    func saveSynchronously(_ snapshot: SessionSnapshot) {
        guard writesFiles, !isSavingSuspended else { return }
        saveDebounce.cancel()
        let url = fileURL
        if queue.sync(execute: { Self.write(snapshot, to: url, finishing: pendingMigration) }) {
            didFinishMigration()
        }
    }

    /// The migrated session reached disk through an ordinary save, and the
    /// ledger says so: later saves have nothing left to finish.
    private func didFinishMigration() {
        pendingMigration = nil
    }

    /// Writes the snapshot, and when a migration's own write had failed
    /// (`pending`), records these bytes as its written document right away,
    /// on the queue, so the ledger does not wait for the main actor (an app
    /// quitting in between would leave it unfinished). Whether it finished
    /// that ledger: false when there was nothing to finish or the write
    /// failed. A ledger that fails to update is tried again on the next save.
    private nonisolated static func write(
        _ snapshot: SessionSnapshot,
        to url: URL,
        finishing pending: MigrationBackupRecord?
    ) -> Bool {
        let data: Data
        do {
            data = try PersistenceCoders.makeEncoder().encode(snapshot)
            try writeSnapshot(projects: snapshot.projects, bytes: data, to: url)
        } catch {
            log.error("write failed: \(String(describing: error), privacy: .private)")
            return false
        }
        guard let pending else { return false }
        do {
            try MigrationBackup.markWritten(pending, for: url, bytes: data)
            return true
        } catch {
            log.error("migration ledger update failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// The one path that puts a snapshot on disk, so a migration's write and
    /// an ordinary save update the routing file the same way. Each caller
    /// hands over the exact bytes, so a migration writes the bytes its
    /// ledger recorded.
    private nonisolated static func writeSnapshot(projects: [Project], bytes: Data, to url: URL) throws {
        defer {
            // The only place the routing is written from, so every save
            // updates it. A separate write, best effort: a failure leaves
            // the hook on the rule it read last (`WorktreeRouting.write`).
            WorktreeRouting.write(projects: projects, beside: url)
        }
        try SecureFileWrite.writeAtomic(bytes, to: url)
    }
}
