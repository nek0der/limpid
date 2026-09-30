// SettingsStoreTests.swift
// Limpid — guards the on-disk lifecycle of `settings.json`. The Codable
// round-trip is covered by `LimpidSettingsTests`; this suite pins the
// quarantine-on-decode-failure behavior that protects the user's bytes
// from a default-save clobber after a hand-edit typo.

import Foundation
import Testing
@testable import Limpid

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
}
