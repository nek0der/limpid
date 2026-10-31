// QuickTerminalSettingsTests.swift
// Weir — the quick terminal settings: which hotkeys the recorder accepts, which it warns about, and how the section decodes.

import Foundation
import Testing
@testable import Weir

@Suite("QuickTerminal settings")
@MainActor
struct QuickTerminalSettingsTests {

    // MARK: - Recorder validation

    private static let noSystemHotKeys: (StoredShortcut) -> Bool = { _ in false }

    @Test func validateHotKey_requiresCommandOrControl() {
        let settings = QuickTerminalSettings()
        let keyboard = KeyboardSettings()
        #expect(settings.validateHotKey(.init(key: "k", modifiers: [.option]), keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.shift, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        )
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(.init(key: "k", modifiers: []), keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.control, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.command, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
    }

    @Test func validateHotKey_rejectsDefaultMenuShortcut() {
        let result = QuickTerminalSettings().validateHotKey(
            .init(key: "t", modifiers: [.command]),
            keyboard: KeyboardSettings(),
            isTakenBySystem: Self.noSystemHotKeys
        )
        #expect(result == .conflictsWithMenu(.newTab))
    }

    @Test func validateHotKey_rejectsOverriddenMenuShortcut() {
        var keyboard = KeyboardSettings()
        let custom = StoredShortcut(key: "k", modifiers: [.control, .option])
        keyboard.setOverride(custom, for: .toggleSidebar)
        #expect(QuickTerminalSettings()
            .validateHotKey(custom, keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys) == .conflictsWithMenu(.toggleSidebar))
    }

    @Test func validateHotKey_rejectsReservedTrigger() {
        let settings = QuickTerminalSettings()
        #expect(settings
            .validateHotKey(.init(key: "q", modifiers: [.command]), keyboard: .init(), isTakenBySystem: Self.noSystemHotKeys) == .reserved)
        #expect(settings
            .validateHotKey(.init(key: "3", modifiers: [.command]), keyboard: .init(), isTakenBySystem: Self.noSystemHotKeys) == .reserved)
    }

    @Test func validateHotKey_takenBySystem_isRejected() {
        let spotlight = StoredShortcut(key: "space", modifiers: [.command])
        let result = QuickTerminalSettings().validateHotKey(spotlight, keyboard: .init()) { $0 == spotlight }
        #expect(result == .takenBySystem)
    }

    /// Ordinary app commands are warned about in the pane, not rejected.
    @Test func validateHotKey_appCommandNotTakenBySystem_isAccepted() {
        let settings = QuickTerminalSettings()
        #expect(settings.validateHotKey(
            .init(key: "s", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
        #expect(settings.validateHotKey(
            .init(key: "c", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
    }

    /// Reserved combinations keep their more specific message even when
    /// macOS also uses them.
    @Test func validateHotKey_reservedWinsOverSystem() {
        let result = QuickTerminalSettings().validateHotKey(
            .init(key: "q", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: { _ in true }
        )
        #expect(result == .reserved)
    }

    // MARK: - App command warning

    @Test(arguments: [
        (StoredShortcut(key: "s", modifiers: [.command]), true),
        (StoredShortcut(key: "space", modifiers: [.command]), true),
        (StoredShortcut(key: "k", modifiers: [.control]), true),
        (StoredShortcut(key: "k", modifiers: [.command, .control]), false),
        (StoredShortcut(key: "`", modifiers: [.control]), false),
        (StoredShortcut(key: "k", modifiers: [.command, .option]), false),
        (StoredShortcut(key: "k", modifiers: [.control, .shift]), false)
    ])
    func mayOverlapAppCommands(_ shortcut: StoredShortcut, expected: Bool) {
        #expect(QuickTerminalSettings.mayOverlapAppCommands(shortcut) == expected, "\(shortcut.displayString)")
    }

    // MARK: - Settings decoding

    @Test func decode_settingsWithoutQuickTerminal_usesDefaults() throws {
        let data = try JSONEncoder().encode(WeirSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["quickTerminal"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WeirSettings.self, from: legacy)

        #expect(decoded.quickTerminal == QuickTerminalSettings())
        #expect(decoded.quickTerminal.hotKey == nil)
        #expect(decoded.quickTerminal.position == .top)
        #expect(decoded.quickTerminal.sizePercent == 50)
        #expect(decoded.quickTerminal.hidesOnFocusLoss)
    }

    @Test func decode_emptySection_usesDefaults() throws {
        let decoded = try JSONDecoder().decode(QuickTerminalSettings.self, from: Data("{}".utf8))
        #expect(decoded == QuickTerminalSettings())
    }

    @Test func decode_partialSection_keepsPresentKeys() throws {
        let json = #"{"position":"left","hotKey":{"key":"`","modifiers":8}}"#
        let decoded = try JSONDecoder().decode(QuickTerminalSettings.self, from: Data(json.utf8))
        #expect(decoded.position == .left)
        #expect(decoded.hotKey == StoredShortcut(key: "`", modifiers: [.control]))
        #expect(decoded.sizePercent == 50)
        #expect(decoded.hidesOnFocusLoss)
    }

    @Test func decode_unknownPosition_fallsBackToTop() throws {
        let decoded = try JSONDecoder().decode(
            QuickTerminalSettings.self,
            from: Data(#"{"position":"diagonal"}"#.utf8)
        )
        #expect(decoded.position == .top)
    }

    @Test func decode_outOfRangeSize_isClampedAndSnapped() throws {
        for (raw, expected) in [(5, 30), (95, 90), (44, 40), (46, 50), (70, 70)] {
            let decoded = try JSONDecoder().decode(
                QuickTerminalSettings.self,
                from: Data(#"{"sizePercent":\#(raw)}"#.utf8)
            )
            #expect(decoded.sizePercent == expected, "\(raw)")
        }
    }

    @Test func codable_roundTrip_preservesEveryField() throws {
        var settings = QuickTerminalSettings()
        settings.hotKey = StoredShortcut(key: "space", modifiers: [.command, .shift])
        settings.position = .center
        settings.sizePercent = 70
        settings.hidesOnFocusLoss = false
        let restored = try JSONDecoder().decode(
            QuickTerminalSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(restored == settings)
    }

    @Test func encode_unboundHotKey_omitsTheKey() throws {
        let data = try JSONEncoder().encode(QuickTerminalSettings())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hotKey"] == nil)
    }
}
