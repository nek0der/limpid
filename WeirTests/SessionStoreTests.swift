// SessionStoreTests.swift
// Weir — `SessionStore` loading state.json (moving an older one forward, or aside) and saving it.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.tags(.persistence))
struct SessionStoreTests {
    /// A migrator whose one step turns the previous version into an empty
    /// current snapshot: what the store does around a step, apart from what
    /// the real step (`SessionSnapshotV5.step`) makes of the file.
    private static func oneStep(_ migrate: @escaping @Sendable (Data) throws -> Data) -> VersionedDocumentMigrator {
        VersionedDocumentMigrator(
            versionKey: "version",
            currentVersion: SessionSnapshot.currentVersion,
            versionWhenAbsent: nil,
            steps: [DocumentMigrationStep(fromVersion: SessionSnapshot.currentVersion - 1, migrate: migrate)]
        )
    }

    private static let upgrade: @Sendable (Data) throws -> Data = { _ in
        try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
    }

    private static func previousVersionFile(in dir: URL) throws -> Data {
        let data = Data("{\"version\":\(SessionSnapshot.currentVersion - 1)}".utf8)
        try data.write(to: dir.appendingPathComponent("state.json"))
        return data
    }

    private static func files(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func migratedFile_isWrittenAtOnceWithOneBackup() throws {
        try withTempDir { dir in
            let original = try Self.previousVersionFile(in: dir)
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))

            guard case .loaded = store.load() else {
                Issue.record("expected the migrated session to load")
                return
            }
            let written = try Data(contentsOf: dir.appendingPathComponent("state.json"))
            let decoded = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: written)
            #expect(decoded.version == SessionSnapshot.currentVersion)
            let backup = "state.json.pre-v\(SessionSnapshot.currentVersion)"
            #expect(try Data(contentsOf: dir.appendingPathComponent(backup)) == original)
            let ledger = MigrationBackup.readLedger(for: dir.appendingPathComponent("state.json"))
            #expect(ledger?.stage == .written)
            #expect(ledger?.backupFileName == backup)
        }
    }

    /// How far a first launch got with the migration before it ended.
    enum InterruptedMigration: CaseIterable, Sendable {
        /// The copy is on disk; the ledger is not.
        case copied
        /// The copy and the ledger are on disk; the migrated file is not.
        case backedUp
        /// The migrated file is on disk; the ledger still says `backedUp`.
        case written
    }

    /// A relaunch after any of those points keeps the one copy and finishes
    /// the ledger. Each rule it rests on is `MigrationBackupTests`'s: a copy
    /// found by its bytes, a backup reused for the same source, and a ledger
    /// finished once the migrated bytes are on disk.
    @Test(arguments: InterruptedMigration.allCases)
    func aRelaunchAfterAnInterruptedMigration_keepsOneCopy_andFinishesTheLedger(
        _ interrupted: InterruptedMigration
    ) throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let original = try Self.previousVersionFile(in: dir)
            let migrated = try Self.upgrade(original)
            switch interrupted {
            case .copied:
                try original.write(to: dir.appendingPathComponent("state.json.pre-v\(SessionSnapshot.currentVersion)"))
            case .backedUp, .written:
                _ = try MigrationBackup.keep(
                    document,
                    source: original,
                    migrated: migrated,
                    from: SessionSnapshot.currentVersion - 1,
                    to: SessionSnapshot.currentVersion
                )
                if interrupted == .written {
                    try migrated.write(to: document)
                }
            }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))

            guard case .loaded = store.load() else {
                Issue.record("expected the session to load")
                return
            }
            #expect(try Self.files(in: dir).filter { $0.contains(".pre-v") }.count == 1)
            #expect(MigrationBackup.readLedger(for: document)?.stage == .written)
        }
    }

    @Test func backupFailure_leavesTheFileUnchanged() throws {
        try withTempDir { dir in
            let original = try Self.previousVersionFile(in: dir)
            let manager = FileManager.default
            // A read-only directory refuses the copy (and the quarantine
            // rename, so the file stays where it was).
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            let outcome = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade)).load()

            guard case let .decodeFailed(error) = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(error as? MigrationBackup.BackupError == .copyFailed)
            #expect(try Data(contentsOf: dir.appendingPathComponent("state.json")) == original)
            let files = try Self.files(in: dir)
            #expect(!files.contains { $0.contains(".pre-v") || $0.contains(".migration.json") })
        }
    }

    @Test func stepThatDoesNotDecode_leavesNoCopy() throws {
        try withTempDir { dir in
            _ = try Self.previousVersionFile(in: dir)
            let migrator = Self.oneStep { _ in Data("{\"version\":\(SessionSnapshot.currentVersion)}".utf8) }
            let outcome = SessionStore(directory: dir, migrator: migrator).load()

            guard case .decodeFailed = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            let files = try Self.files(in: dir)
            #expect(!files.contains { $0.contains(".pre-v") || $0.contains(".migration.json") })
            #expect(files.contains { $0.hasPrefix("state.json.bak-decode-failed-") })
        }
    }

    @Test func loadingTheMigratedFileAgain_isANoOp() throws {
        try withTempDir { dir in
            _ = try Self.previousVersionFile(in: dir)
            let migrator = Self.oneStep(Self.upgrade)
            _ = SessionStore(directory: dir, migrator: migrator).load()
            let before = try Self.files(in: dir)
            let second = SessionStore(directory: dir, migrator: migrator)
            guard case .loaded = second.load() else {
                Issue.record("expected the current file to load")
                return
            }
            #expect(try Self.files(in: dir) == before)
            #expect(MigrationBackup.readLedger(for: dir.appendingPathComponent("state.json"))?.stage == .written)
        }
    }

    @Test func aMigrationWhoseWriteFailed_isRecordedOnceALaterSaveWrites() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            _ = try Self.previousVersionFile(in: dir)
            let manager = FileManager.default
            // The copy and the ledger can be written; the file itself cannot
            // be replaced.
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))

            guard case .loaded = store.load() else {
                Issue.record("expected the migrated session to load from memory")
                return
            }
            #expect(MigrationBackup.readLedger(for: file)?.stage == .backedUp, "nothing reached disk yet")

            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))
            #expect(MigrationBackup.readLedger(for: file)?.stage == .written)

            let relaunched = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))
            _ = relaunched.load()
            #expect(MigrationBackup.readLedger(for: file)?.stage == .written, "and after a relaunch")
        }
    }

    @Test func aDebouncedSave_finishesTheMigrationToo() async throws {
        try await withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            _ = try Self.previousVersionFile(in: dir)
            let manager = FileManager.default
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))
            _ = store.load()

            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            store.scheduleSave(SessionSnapshot(projects: [], tabs: []))
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { MigrationBackup.readLedger(for: file)?.stage == .written }

            #expect(MigrationBackup.readLedger(for: file)?.stage == .written, "finished on the queue")
        }
    }

    @Test func aStoreThatMayNotWrite_savesNothing() throws {
        // Demo mode: the app shows its fixture and the person's file stays.
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = Data("{}".utf8)
            try original.write(to: file)
            let store = SessionStore(directory: dir, writesFiles: false)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func aFileThatCannotBeSetAside_stopsSaving() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = Data("not json".utf8)
            try original.write(to: file)
            let manager = FileManager.default
            // An immutable file cannot be renamed, so it cannot be set aside.
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the unreadable file to fail")
                return
            }
            #expect(store.isSavingSuspended)
            // Writable again, so only the suspension can keep the save off it.
            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))

            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func aFileSetAside_leavesSavingOn() throws {
        try withTempDir { dir in
            try Data("not json".utf8).write(to: dir.appendingPathComponent("state.json"))
            let store = SessionStore(directory: dir)
            _ = store.load()
            #expect(!store.isSavingSuspended)
        }
    }

    /// A state.json that is there but cannot be read is not a first launch:
    /// it is set aside as it is, so the save that follows once it could be
    /// written lands on a fresh name instead of replacing it.
    @Test func aFileThatCannotBeRead_isSetAside_notTakenForAFirstLaunch() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
            try original.write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the unreadable file to be reported")
                return
            }
            #expect(!store.isSavingSuspended)
            let aside = try #require(try Self.files(in: dir).first { $0.hasPrefix("state.json.bak-read-failed-") })
            let asideURL = dir.appendingPathComponent(aside)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asideURL.path)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))

            #expect(try Data(contentsOf: asideURL) == original)
            #expect(manager.fileExists(atPath: file.path))
        }
    }

    /// One that can be neither read nor moved stops saving, so a save once
    /// it is readable and writable again cannot replace it.
    @Test func aFileThatCannotBeReadOrSetAside_stopsSaving() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
            try original.write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the unreadable file to be reported")
                return
            }
            #expect(store.isSavingSuspended)
            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))

            #expect(try Data(contentsOf: file) == original)
        }
    }

    /// Keys a later build added to a tab, a project, or a worktree are
    /// written back as they were, through a restore and a save, so going
    /// back a build and forward again keeps them. The keys this build reads
    /// and no longer writes stay gone.
    @Test func keysALaterBuildAdded_toATabProjectOrWorktree_surviveARestoreAndASave() throws {
        try withTempDir { dir in
            let root = WorkspaceSessionFixture.projectRootURL("unknown-keys")
            let worktree = Worktree(label: "w", workingDirectory: root.appendingPathComponent("w"), origin: .userPinned)
            let project = Project(name: "repo", rootURL: root, worktrees: [worktree])
            let tab = Tab.newWithSinglePane(title: "t", container: .project(project.id)).tab
            let encoded = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [project], tabs: [tab]))
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var tabs = try #require(object["tabs"] as? [String: Any])
            var tabObject = try #require(tabs[tab.id.uuidString] as? [String: Any])
            tabObject["futureTabField"] = ["nested": [1, 2]]
            tabObject["claudeSessions"] = [String: Any]()
            tabs[tab.id.uuidString] = tabObject
            object["tabs"] = tabs
            var containers = try #require(object["containers"] as? [[String: Any]])
            var projectObject = try #require(containers[0]["project"] as? [String: Any])
            projectObject["futureProjectField"] = "kept"
            projectObject["isExpanded"] = true
            var worktreeObjects = try #require(projectObject["worktrees"] as? [[String: Any]])
            worktreeObjects[0]["futureWorktreeField"] = 7
            projectObject["worktrees"] = worktreeObjects
            containers[0]["project"] = projectObject
            object["containers"] = containers
            let file = dir.appendingPathComponent("state.json")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let store = SessionStore(directory: dir)

            guard case let .loaded(snapshot) = store.load() else {
                Issue.record("expected the file to load")
                return
            }
            let session = WorkspaceSession()
            session.restore(from: snapshot)
            store.saveSynchronously(session.makeSnapshot())

            let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let writtenTab = try #require((written["tabs"] as? [String: Any])?[tab.id.uuidString] as? [String: Any])
            #expect((writtenTab["futureTabField"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
            #expect(writtenTab["claudeSessions"] == nil)
            let writtenProject = try #require((written["containers"] as? [[String: Any]])?.first?["project"] as? [String: Any])
            #expect(writtenProject["futureProjectField"] as? String == "kept")
            #expect(writtenProject["isExpanded"] == nil)
            let writtenWorktree = try #require((writtenProject["worktrees"] as? [[String: Any]])?.first)
            #expect(writtenWorktree["futureWorktreeField"] as? Int == 7)
        }
    }

    /// A folder that cannot be searched hides the file in it, even from the
    /// check that it was moved aside: saving stops, so a save once the
    /// folder opens up again cannot replace the file.
    @Test func aFileInAFolderThatCannotBeSearched_stopsSaving() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("state.json")
            let original = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
            try original.write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the hidden file to be reported")
                return
            }
            #expect(store.isSavingSuspended)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))

            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func noFile_isAFirstLaunch() throws {
        try withTempDir { dir in
            let store = SessionStore(directory: dir)
            guard case .absent = store.load() else {
                Issue.record("expected no file to read as a first launch")
                return
            }
            #expect(!store.isSavingSuspended)
        }
    }

    @Test func throwingStep_movesTheFileAsideUnchanged() throws {
        try withTempDir { dir in
            struct Boom: Error {}
            let original = try Self.previousVersionFile(in: dir)
            let outcome = SessionStore(directory: dir, migrator: Self.oneStep { _ in throw Boom() }).load()

            guard case .decodeFailed = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
            let aside = try #require(try Self.files(in: dir).first { $0.hasPrefix("state.json.bak-migration-failed-") })
            #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == original)
            let files = try Self.files(in: dir)
            #expect(!files.contains { $0.contains(".pre-v") })
        }
    }

    @Test func olderVersionWithoutAStep_isSetAsideAsBefore() throws {
        try withTempDir { dir in
            // Version 4 and older have no step.
            try Data("{\"version\":4}".utf8).write(to: dir.appendingPathComponent("state.json"))
            let outcome = SessionStore(directory: dir).load()

            guard case let .versionMismatch(found, expected) = outcome else {
                Issue.record("expected a version mismatch, got \(outcome)")
                return
            }
            #expect(found == 4)
            #expect(expected == SessionSnapshot.currentVersion)
            let files = try Self.files(in: dir)
            #expect(files.contains { $0.hasPrefix("state.json.bak-version-mismatch-") })
        }
    }

    @Test func newerVersion_isSetAsideNotMigrated() throws {
        try withTempDir { dir in
            try Data("{\"version\":\(SessionSnapshot.currentVersion + 1)}".utf8)
                .write(to: dir.appendingPathComponent("state.json"))
            let outcome = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade)).load()

            guard case let .versionMismatch(found, _) = outcome else {
                Issue.record("expected a version mismatch, got \(outcome)")
                return
            }
            #expect(found == SessionSnapshot.currentVersion + 1)
            let files = try Self.files(in: dir)
            #expect(!files.contains { $0.contains(".pre-v") })
        }
    }

    @Test func currentFile_loadsWithoutABackup() throws {
        try withTempDir { dir in
            let store = SessionStore(directory: dir)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))
            guard case .loaded = store.load() else {
                Issue.record("expected the saved session to load")
                return
            }
            let files = try Self.files(in: dir)
            #expect(!files.contains { $0.contains(".pre-v") || $0.contains(".migration.json") })
        }
    }
}
