// SettingsMigration.swift
// Limpid — moving settings.json between schema versions.

import Foundation

extension VersionedDocumentMigrator {
    /// `settings.json`. A file from before the version key existed is
    /// schema 1. A newer file is read as is rather than set aside: the
    /// settings decoder keeps fields it does not know, and losing a
    /// person's settings to a rollback would be worse than ignoring a few.
    static let settings = VersionedDocumentMigrator(
        versionKey: "schemaVersion",
        currentVersion: LimpidSettings.currentSchemaVersion,
        versionWhenAbsent: 1,
        steps: [
            DocumentMigrationStep(fromVersion: 1) { try LimpidSettings.migrateFromV1($0) }
        ]
    )
}

extension LimpidSettings {
    /// The encoder `settings.json` is written with: pretty in every build,
    /// since it is the one file people are expected to open in an editor,
    /// and sorted so a hand edit diffs cleanly.
    static func makeFileEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Schema 1 to 2: the keyboard's new actions and reserved keys
    /// (`normalizeKeyboard`), and the keys whose meaning changed
    /// (`KeyboardSettings.noteChangedKeys(since:)`). Everything else is
    /// carried as it was, including fields this build does not know.
    static func migrateFromV1(_ data: Data) throws -> Data {
        var settings = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data)
        let schema1 = settings.keyboard
        settings.normalizeKeyboard()
        settings.keyboard.noteChangedKeys(since: schema1)
        settings.schemaVersion = 2
        return try makeFileEncoder().encode(settings)
    }

    /// See `KeyboardSettings.normalize`; the quick terminal's hotkey takes
    /// keys the same way an action's binding does.
    mutating func normalizeKeyboard() {
        keyboard.normalize(quickTerminalHotKey: &quickTerminal.hotKey)
    }
}
