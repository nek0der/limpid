// SettingsStoreTests.swift
// Weir — guards the on-disk lifecycle of `settings.json`. The Codable
// round-trip is covered by `WeirSettingsTests`; this suite pins the
// quarantine-on-decode-failure behavior that protects the user's bytes
// from a default-save clobber after a hand-edit typo.

import Foundation
import Testing
@testable import Weir

@MainActor
struct SettingsStoreTests {

    /// A garbled `settings.json` is renamed aside on init and the
    /// subsequent `saveNow()` lands on a fresh file, preserving the
    /// user's original bytes.
    @Test("decode failure quarantines settings.json before defaults take over")
    func decodeFailureQuarantinesFile() throws {
        try withTempDir { dir in
            let originalBytes = Data(#"{ "garbled": true, "#.utf8)
            let live = dir.appendingPathComponent("settings.json")
            try originalBytes.write(to: live)

            let store = SettingsStore(directory: dir)

            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let quarantined = entries.first { $0.hasPrefix("settings.json.bak-decode-failed-") }
            try #require(quarantined != nil, "expected a quarantine sibling of settings.json")
            let quarantinedURL = dir.appendingPathComponent(quarantined!)
            #expect(try Data(contentsOf: quarantinedURL) == originalBytes)

            // The store should hold the schema default, not the bad bytes.
            #expect(store.settings == .default)

            // A subsequent save lands at the fresh `settings.json` path
            // without overwriting the bak file.
            store.saveNow()
            #expect(FileManager.default.fileExists(atPath: live.path))
            #expect(try Data(contentsOf: quarantinedURL) == originalBytes)
        }
    }

    /// The file name is what users edit by hand and what older builds
    /// read, so we pin it here rather than through the store's helper.
    @Test("the store saves to and loads from settings.json in its directory")
    func saveAndLoad_useSettingsJSONInDirectory() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let store = SettingsStore(directory: dir)
            #expect(store.settingsFileURL == file)

            store.settings.terminal.minPaneSize = 120
            store.saveNow()
            #expect(FileManager.default.fileExists(atPath: file.path))

            let reloaded = SettingsStore(directory: dir)
            #expect(reloaded.settings.terminal.minPaneSize == 120)
        }
    }

    /// A file a newer build wrote is read but never written back: this
    /// build would write its own schema under the newer version number, and
    /// the newer build would then skip the step that moves it forward.
    @Test func aNewerSchemaFile_isReadButNotWrittenBack() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            var newer = WeirSettings.default
            newer.schemaVersion = 99
            newer.terminal.minPaneSize = 140
            let bytes = try WeirSettings.makeFileEncoder().encode(newer)
            try bytes.write(to: file)

            let store = SettingsStore(directory: dir)
            #expect(store.settings.terminal.minPaneSize == 140)
            #expect(store.savingSuspension == .newerVersion)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    /// A newer build may change the type of a key this build knows. Its file
    /// then does not decode here, and it is still that build's: it stays
    /// where it is, unread and unwritten, and this launch runs on the
    /// defaults without saving them over it.
    @Test func aNewerSchemaFileThatDoesNotDecode_staysInPlace_andIsNotWritten() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            var newer = try #require(
                JSONSerialization.jsonObject(with: WeirSettings.makeFileEncoder().encode(WeirSettings.default)) as? [String: Any]
            )
            newer["schemaVersion"] = 99
            newer["terminal"] = "a newer shape"
            let bytes = try JSONSerialization.data(withJSONObject: newer)
            try bytes.write(to: file)

            let store = SettingsStore(directory: dir)
            #expect(store.savingSuspension == .newerVersionUnreadable)
            #expect(store.settings.terminal == WeirSettings.default.terminal)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == bytes)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!entries.contains { $0.contains(".bak-") })

            // The watcher reading it again keeps it as it is too.
            store.reloadFromDisk()
            store.flushSynchronously()
            #expect(store.savingSuspension == .newerVersionUnreadable)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    /// A settings.json that is there but cannot be read is set aside under a
    /// new name as it is, so the defaults saved later do not land on it.
    @Test func aFileThatCannotBeRead_isSetAside() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let original = try WeirSettings.testFileData(version: 2, overrides: ["newTab": TestShortcuts.commandN])
            try original.write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

            let store = SettingsStore(directory: dir)
            #expect(store.savingSuspension == nil)
            #expect(store.settings.keyboard.overrides.isEmpty, "the defaults, as nothing could be read")
            let aside = try #require(try manager.contentsOfDirectory(atPath: dir.path)
                .first { $0.hasPrefix("settings.json.bak-read-failed-") })
            let asideURL = dir.appendingPathComponent(aside)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asideURL.path)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()

            #expect(try Data(contentsOf: asideURL) == original)
            #expect(manager.fileExists(atPath: file.path))
        }
    }

    /// A folder that cannot be searched hides the file in it: that is not a
    /// first launch either. Saving stops, so a save once the folder opens
    /// up again cannot replace the file with the defaults.
    @Test func aFileInAFolderThatCannotBeSearched_stopsSaving() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("settings.json")
            let original = try WeirSettings.makeFileEncoder().encode(WeirSettings.default)
            try original.write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = SettingsStore(directory: dir)
            #expect(store.savingSuspension == .unreadable)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == original)
        }
    }

    /// The file watcher sees our own save as a change on disk. Reading it
    /// back must not undo a change made after that save and not yet saved.
    @Test func reloadAfterOwnSave_keepsALaterChange() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            store.settings.terminal.minPaneSize = 140

            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 140)
        }
    }

    /// An edit made by hand after our save is taken in, and so is a hand
    /// edit that puts the file back to what we last saved: an edit like any
    /// other, not our own save's echo.
    @Test func anEditByHandBackToOurSave_isTakenIn() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            let saved = try Data(contentsOf: store.settingsFileURL)
            var edited = store.settings
            edited.terminal.minPaneSize = 180
            try WeirSettings.makeFileEncoder().encode(edited).write(to: store.settingsFileURL)
            store.reloadFromDisk()
            #expect(store.settings.terminal.minPaneSize == 180)

            try saved.write(to: store.settingsFileURL)
            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 120)
        }
    }

    @Test func moveSettingsFileAside_leavesNoSettingsFileBehind() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try Data("{}".utf8).write(to: file)
            SettingsStore.moveSettingsFileAside(at: file)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(entries.count == 1)
            #expect(entries.first?.hasPrefix("settings.json.bak-init-failure-") == true)
        }
    }
}
