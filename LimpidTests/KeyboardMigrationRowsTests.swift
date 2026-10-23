// KeyboardMigrationRowsTests.swift
// Limpid — the rows Settings → Keyboard lists for what the update did to a person's shortcuts.

import Foundation
import Testing
@testable import Limpid

struct KeyboardMigrationRowsTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// A binding kept aside comes before a default left unassigned.
    @Test func keptAsideThenUnassigned_areListedInThatOrder() {
        var keyboard = KeyboardSettings()
        keyboard.retired = ["oldAction": StoredShortcut(key: "x", modifiers: [.command, .option])]
        keyboard.setOverride(StoredShortcut(key: "j", modifiers: [.command, .control]), for: .newTab)
        keyboard = keyboard.normalizedForTest().keyboard
        let rows = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: nil, locale: Self.japanese)
        #expect(rows.map(\.id) == ["retired.oldAction", "unassigned.showNeedsAttention"])
        #expect(rows[0].detail == "割り当てを外しました：⌥⌘X")
        #expect(rows[1].detail?.hasPrefix("デフォルトの ⌃⌘J は ") == true)
    }

    /// A default the quick terminal's hotkey holds names the hotkey.
    @Test func aDefaultTheHotkeyHolds_namesTheHotkey() {
        let (keyboard, hotKey) = KeyboardSettings().normalizedForTest(hotKey: StoredShortcut(key: "j", modifiers: [.command, .control]))
        let rows = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: hotKey, locale: Self.english)
        #expect(rows.first { $0.id == "unassigned.showNeedsAttention" }?.detail == "Default ⌃⌘J is used by Quick Terminal hotkey")
    }
}
