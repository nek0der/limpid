// KeyboardSettingsFixture.swift
// Limpid — the shortcuts the keyboard suites bind, keyboard settings normalized as a load does, and a settings file of a schema.

import Foundation
@testable import Limpid

/// The shortcuts the keyboard suites bind and take back.
enum TestShortcuts {
    /// New Worktree…'s default.
    static let commandN = StoredShortcut(key: "n", modifiers: [.command])
    /// Create Worktree Now's default.
    static let optionCommandN = StoredShortcut(key: "n", modifiers: [.command, .option])
    /// Find's default.
    static let commandF = StoredShortcut(key: "f", modifiers: [.command])
    /// Reserved for the decision bar's primary action.
    static let commandReturn = StoredShortcut(key: "return", modifiers: [.command])
}

extension KeyboardSettings {
    /// These settings, and the quick terminal's `hotKey`, as a load leaves
    /// them (`normalize(quickTerminalHotKey:)`).
    func normalizedForTest(hotKey: StoredShortcut? = nil) -> (keyboard: KeyboardSettings, hotKey: StoredShortcut?) {
        var keyboard = self
        var hotKey = hotKey
        keyboard.normalize(quickTerminalHotKey: &hotKey)
        return (keyboard, hotKey)
    }
}

extension LimpidSettings {
    /// A settings file of schema `version` with `overrides`, as it is
    /// written to disk.
    static func testFileData(version: Int, overrides: [String: StoredShortcut]) throws -> Data {
        var settings = LimpidSettings()
        settings.schemaVersion = version
        settings.keyboard.overrides = overrides
        return try LimpidSettings.makeFileEncoder().encode(settings)
    }
}
