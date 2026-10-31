// SettingsStoreMigrationTests.swift
// Weir — the settings store moving a file to schema 2: the copy it keeps first, what it writes, and when it holds off saving.

import Foundation
import Testing
@testable import Weir

@MainActor
struct SettingsStoreMigrationTests {
    @Test func theStore_keepsACopy_andWritesSchemaTwo() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn]).write(to: file)

            let store = SettingsStore(directory: dir)
            #expect(store.settings.schemaVersion == 2)
            #expect(store.settings.keyboard.retired["find"] == TestShortcuts.commandReturn)
            let ledger = MigrationBackup.readLedger(for: file)
            #expect(ledger?.fromVersion == 1)
            #expect(ledger?.stage == .written)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.contains { $0.hasPrefix("settings.json.pre-v2") })
            let onDisk = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: file))
            #expect(onDisk.schemaVersion == 2, "written at once, not on the next save")
        }
    }

    @Test func aRolledBackFile_isBroughtBackInLine_onLoad() throws {
        try withTempDir { dir in
            // An earlier build left ⌘⏎ on Find in a schema 2 file.
            try WeirSettings.testFileData(version: 2, overrides: ["find": TestShortcuts.commandReturn])
                .write(to: dir.appendingPathComponent("settings.json"))
            let store = SettingsStore(directory: dir)
            #expect(store.settings.keyboard.retired["find"] == TestShortcuts.commandReturn)
            #expect(store.settings.keyboard.shortcut(for: .find) == WeirShortcutAction.find.defaultShortcut)
        }
    }

    @Test func demoMode_migratesInMemory_andWritesNothing() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let v1 = try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn])
            try v1.write(to: file)

            let store = SettingsStore(directory: dir, writesFiles: false)
            #expect(store.settings.schemaVersion == 2)
            store.saveNow()
            #expect(try Data(contentsOf: file) == v1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
        }
    }

    @Test func changesMadeInTheStore_keepTheKeysInLine() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.keyboard.setOverride(TestShortcuts.commandN, for: .newTab)
            store.settings.keyboard.resetOverride(for: .newWorktree)
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == nil)

            store.settings.keyboard.resetOverride(for: .newTab)
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == TestShortcuts.commandN)

            // Restore leaves the hotkey where it is, so its keys stay taken.
            store.settings.quickTerminal.hotKey = TestShortcuts.commandN
            store.settings.keyboard.restoreDefaults()
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == nil)
            store.settings.quickTerminal.hotKey = nil
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == TestShortcuts.commandN)
        }
    }

    @Test func aMoveWhoseWriteFailed_isRecordedOnceALaterSaveWrites() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn]).write(to: file)
            // The copy and the ledger can be written; the file itself cannot
            // be replaced.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }

            let store = SettingsStore(directory: dir)
            #expect(store.settings.schemaVersion == 2, "the move is in use")
            #expect(MigrationBackup.readLedger(for: file)?.stage == .backedUp, "nothing reached disk yet")

            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            store.settings.terminal.minPaneSize = 140
            store.saveNow()
            #expect(MigrationBackup.readLedger(for: file)?.stage == .written)
            _ = SettingsStore(directory: dir)
            #expect(MigrationBackup.readLedger(for: file)?.stage == .written, "and after a relaunch")
        }
    }

    @Test func withoutACopy_theFileIsReadAsItWas_andNotWritten() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let v1 = try WeirSettings.testFileData(version: 1, overrides: ["newTab": TestShortcuts.commandN])
            try v1.write(to: file)
            // A folder the copy cannot be written into.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = SettingsStore(directory: dir)
            #expect(store.settings.schemaVersion == 1, "the next launch tries again")
            #expect(MigrationBackup.readLedger(for: file) == nil)
            #expect(store.savingSuspension == .notMoved)
            #expect(try Data(contentsOf: file) == v1)
            // The keys are still kept consistent in memory.
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == nil)
        }
    }

    /// Without a copy the store holds off saving, so a change made in a
    /// folder it could write still leaves the only copy of the file as it was.
    @Test func withoutACopy_inAWritableFolder_aSaveLeavesTheFileAsItWas() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let v1 = try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn])
            try v1.write(to: file)
            // Every name a copy could take in the next few seconds is
            // taken by something else, so no copy can be made.
            let now = Int(Date().timeIntervalSince1970)
            var names = ["settings.json.pre-v2"]
            for stamp in (now - 1)...(now + 5) {
                names += ["settings.json.pre-v2.\(stamp)"] + (1...99).map { "settings.json.pre-v2.\(stamp)-\($0)" }
            }
            for name in names {
                try Data().write(to: dir.appendingPathComponent(name))
            }

            let store = SettingsStore(directory: dir)
            #expect(store.settings.schemaVersion == 1, "the next launch tries again")
            #expect(store.savingSuspension == .notMoved)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            #expect(try Data(contentsOf: file) == v1, "a save would leave no copy of what the person had")
        }
    }

    @Test func reloadingFromDisk_migratesAFileAnEarlierBuildWrote() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let store = SettingsStore(directory: dir)
            try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn]).write(to: file)

            store.reloadFromDisk()

            #expect(store.settings.schemaVersion == 2)
            #expect(MigrationBackup.readLedger(for: file)?.fromVersion == 1)
        }
    }

    /// The reload's move writes the file again, and the watcher reports
    /// that write too: by then the person may have changed a setting that
    /// is not saved yet, which the migrated file must not replace.
    @Test func aReloadsMove_reportedByTheWatcher_keepsAChangeMadeSince() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let store = SettingsStore(directory: dir)
            try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn]).write(to: file)
            store.reloadFromDisk()
            #expect(store.settings.schemaVersion == 2)
            let migrated = try Data(contentsOf: file)

            store.settings.terminal.minPaneSize = 120
            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 120)
            #expect(try Data(contentsOf: file) == migrated, "nothing else was written meanwhile")
            store.flushSynchronously()
        }
    }

    @Test func anUnreadableFile_thatCannotBeMovedAside_isNeverSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let garbled = Data(#"{ "garbled": true, "#.utf8)
            try garbled.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = SettingsStore(directory: dir)
            #expect(store.settings == .default)
            #expect(store.savingSuspension == .unreadable)
            store.settings.terminal.minPaneSize = 120
            store.saveNow()
            #expect(try Data(contentsOf: file) == garbled)

            // Fixed by hand, the file is read again and saving resumes.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try WeirSettings.testFileData(version: 2, overrides: [:]).write(to: file)
            store.reloadFromDisk()
            #expect(store.savingSuspension == nil)
            store.settings.terminal.minPaneSize = 140
            store.saveNow()
            let saved = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: file))
            #expect(saved.terminal.minPaneSize == 140)
        }
    }

    /// A run that writes nothing (demo mode) tells no suspension, even for
    /// an older file it can neither move nor read: it saves nothing anyway,
    /// and the file belongs to the build the person runs, untouched.
    @Test func aStoreThatMayNotWrite_tellsNoSuspension() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try Self.versionlessMistyped.write(to: file)

            let store = SettingsStore(directory: dir, writesFiles: false)
            #expect(store.settings == .default)
            #expect(store.savingSuspension == nil)
            store.reloadFromDisk()
            #expect(store.savingSuspension == nil)
            #expect(try Data(contentsOf: file) == Self.versionlessMistyped)
        }
    }

    /// A hand-written file with no schema version (read as version 1) and a
    /// value of the wrong type cannot be moved to this version's format nor
    /// read as it stands. It is set aside like any file that does not
    /// decode, and saving goes on: it is not an older file read as it was.
    @Test func aVersionlessFileThatDoesNotDecode_isSetAside_andSavingGoesOn() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try Self.versionlessMistyped.write(to: file)

            let store = SettingsStore(directory: dir)
            #expect(store.settings == .default)
            #expect(store.savingSuspension == nil)
            #expect(SavingSuspendedNotice.atLaunch(
                settings: store.savingSuspension, settingsFile: file, locale: Locale(identifier: "en")
            ) == nil)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.contains { $0.hasPrefix("settings.json.bak-decode-failed-") })
            #expect(MigrationBackup.readLedger(for: file) == nil)

            store.settings.terminal.minPaneSize = 140
            store.saveNow()
            let saved = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: file))
            #expect(saved.terminal.minPaneSize == 140)
        }
    }

    /// No `schemaVersion`, and `terminal` is not an object.
    private static let versionlessMistyped = Data(#"{"terminal":"wide"}"#.utf8)
}
