// KeyboardShortcutTests.swift
// Weir — a shortcut as it is stored, shown, and checked before it is bound.

// The recorder's `NSEvent` capture cannot be driven headlessly, so its path
// is exercised through what it writes: `StoredShortcut` round-trips through
// Codable and the Ghostty trigger string. The lines that reach libghostty
// are `GhosttyConfigBridgeTests`'.

import Foundation
import Testing
@testable import Weir

@Suite("KeyboardShortcut")
@MainActor
struct KeyboardShortcutTests {

    // MARK: - Modifiers

    @Test("Ghostty token order is super, ctrl, alt, shift")
    func ghosttyTokens_canonicalOrder() {
        let mods: ShortcutModifiers = [.shift, .command, .control, .option]
        #expect(mods.ghosttyTokens == ["super", "ctrl", "alt", "shift"])
    }

    @Test("Display symbols follow HIG order ⌃⌥⇧⌘")
    func displaySymbols_higOrder() {
        let mods: ShortcutModifiers = [.command, .shift, .control, .option]
        #expect(mods.displaySymbols == "⌃⌥⇧⌘")
    }

    // MARK: - StoredShortcut

    /// Modifiers then the key; Return under Ghostty's Enter name; and `+`
    /// under Ghostty's `plus` alias, since a literal `+` between the `+`
    /// separators (`super++`) is ambiguous.
    @Test("The trigger string is the modifiers and the key, in Ghostty's names", arguments: [
        (StoredShortcut(key: "t", modifiers: [.command, .shift]), "super+shift+t"),
        (StoredShortcut(key: "return", modifiers: [.command, .shift]), "super+shift+enter"),
        (StoredShortcut(key: "+", modifiers: [.command]), "super+plus")
    ])
    func ghosttyTrigger_namesTheModifiersAndTheKey(shortcut: StoredShortcut, trigger: String) {
        #expect(shortcut.ghosttyTrigger == trigger)
    }

    @Test("Display string maps named keys to glyphs")
    func displayString_namedKeys() {
        #expect(StoredShortcut(key: "left", modifiers: [.command]).displayString == "⌘←")
        #expect(StoredShortcut(key: "return", modifiers: [.command, .shift]).displayString == "⇧⌘⏎")
        #expect(StoredShortcut(key: "t", modifiers: [.command]).displayString == "⌘T")
    }

    @Test("Display tokens split modifiers and key into chips")
    func displayTokens_splitsChips() {
        #expect(StoredShortcut(key: "t", modifiers: [.command, .shift]).displayTokens == ["⇧", "⌘", "T"])
        #expect(StoredShortcut(key: "left", modifiers: [.command]).displayTokens == ["⌘", "←"])
        #expect(StoredShortcut(key: "k", modifiers: []).displayTokens == ["K"])
    }

    @Test("Codable round-trip preserves key and modifiers")
    func codable_roundTrip() throws {
        let original = StoredShortcut(key: "d", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredShortcut.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - KeyboardSettings

    @Test("Effective shortcut falls back to the action's default")
    func shortcut_defaultFallback() {
        let kb = KeyboardSettings()
        #expect(kb.shortcut(for: .newTab) == WeirShortcutAction.newTab.defaultShortcut)
    }

    @Test("Review Latest Turn is a View action on option-command-J")
    func reviewLatestTurn_isAViewActionOnOptionCommandJ() {
        #expect(WeirShortcutAction.reviewLatestTurn.category == .view)
        #expect(WeirShortcutAction.reviewLatestTurn.localizedTitle == "Review Latest Turn")
        #expect(WeirShortcutAction.reviewLatestTurn.iconName == ReviewPresentation.symbol)
        #expect(
            WeirShortcutAction.reviewLatestTurn.defaultShortcut
                == StoredShortcut(key: "j", modifiers: [.command, .option])
        )
    }

    @Test("Override wins over the default")
    func shortcut_overrideWins() {
        var kb = KeyboardSettings()
        let custom = StoredShortcut(key: "k", modifiers: [.command, .control])
        kb.setOverride(custom, for: .newTab)
        #expect(kb.shortcut(for: .newTab) == custom)
    }

    @Test("Reset restores the default")
    func shortcut_resetRestoresDefault() {
        var kb = KeyboardSettings()
        kb.setOverride(.init(key: "k", modifiers: [.command]), for: .newTab)
        kb.resetOverride(for: .newTab)
        #expect(kb.shortcut(for: .newTab) == WeirShortcutAction.newTab.defaultShortcut)
    }

    // MARK: - Validation

    @Test("Validate rejects a trigger already used by another action")
    func validate_conflictDetected() throws {
        let kb = KeyboardSettings()
        // newTab default is ⌘T. Try to bind closeSurface to ⌘T.
        let stolen = try #require(WeirShortcutAction.newTab.defaultShortcut)
        let result = kb.validate(stolen, for: .closeSurface)
        #expect(result == .conflict(.newTab))
        // No actual mutation happens — the recorder is responsible
        // for skipping setOverride on a non-.ok result.
        #expect(kb.overrides.isEmpty)
    }

    @Test func validate_rejectsTheQuickTerminalHotKey() {
        let hotKey = StoredShortcut(key: "`", modifiers: [.control])
        let keyboard = KeyboardSettings()
        #expect(keyboard.validate(hotKey, for: .newTab, quickTerminalHotKey: hotKey) == .quickTerminalConflict)
        #expect(keyboard.validate(hotKey, for: .newTab, quickTerminalHotKey: nil) == .ok)
        #expect(
            keyboard.validate(.init(key: "`", modifiers: [.command]), for: .newTab, quickTerminalHotKey: hotKey)
                == .ok
        )
    }

    // MARK: - Encoding shape

    /// Punctuation keys must be stored as their literal character
    /// (not Ghostty's physical-key name like `equal` / `bracket_left`).
    /// This is the JIS-fix invariant: literal triggers route through
    /// libghostty's `utf8` / `unshifted_codepoint` match cascade,
    /// which works regardless of keyboard layout.
    @Test("Punctuation defaults are stored as literal characters")
    func encoding_punctuationDefaultsAreLiteral() throws {
        let increase = try #require(WeirShortcutAction.increaseFontSize.defaultShortcut)
        #expect(increase.key == "=")
        let decrease = try #require(WeirShortcutAction.decreaseFontSize.defaultShortcut)
        #expect(decrease.key == "-")
        let reset = try #require(WeirShortcutAction.resetFontSize.defaultShortcut)
        #expect(reset.key == "0")
        let nextSection = try #require(WeirShortcutAction.nextSession.defaultShortcut)
        #expect(nextSection.key == "]")
    }

    /// Re-saving an action's own current shortcut must not flag
    /// itself as a conflict. The recorder hits this when a user
    /// records the same key back into the same action — without the
    /// `other != action` filter in `validate` we'd refuse a no-op.
    @Test("Validate ignores self when checking conflicts")
    func validate_ignoresSelf() throws {
        var kb = KeyboardSettings()
        let current = try #require(WeirShortcutAction.newTab.defaultShortcut)
        kb.setOverride(current, for: .newTab)
        #expect(kb.validate(current, for: .newTab) == .ok)
    }

    /// An unused trigger is free. ⌘1 is reserved for the tab jump, and
    /// ⌘Q because Weir routes it through AppKit's terminate path (state
    /// save), which a binding would race. A bare letter would hijack every
    /// plain keypress of that character and break the terminal, so the
    /// recorder rejects it.
    @Test("Validate frees an unused trigger, and rejects a reserved or modifierless one", arguments: [
        (StoredShortcut(key: "k", modifiers: [.command, .control, .shift]), ShortcutValidation.ok),
        (StoredShortcut(key: "1", modifiers: [.command]), .reserved),
        (StoredShortcut(key: "q", modifiers: [.command]), .reserved),
        (StoredShortcut(key: "k", modifiers: []), .missingModifier)
    ])
    func validate_freesAnUnusedTrigger_andRejectsReservedOrBareOnes(
        shortcut: StoredShortcut,
        result: ShortcutValidation
    ) {
        #expect(KeyboardSettings().validate(shortcut, for: .newTab) == result)
    }

    // MARK: - Persistence

    /// Old `settings.json` files written before the `keyboard`
    /// section existed must still decode — the root container drops
    /// `decode` for `keyboard` and uses `decodeIfPresent` exactly to
    /// keep the user's other (already-tuned) sections.
    @Test("Settings without a keyboard section decode with defaults")
    func decoder_keyboardMissingFallsBack() throws {
        let legacy = #"""
        {"schemaVersion":1,
         "appearance":{"accentColor":"default","backgroundOpacity":0.92,"transparency":"on"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{},
         "advanced":{"ghosttyConfig":"off"}}
        """#
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: Data(legacy.utf8))
        #expect(decoded.keyboard.overrides.isEmpty)
        #expect(decoded.keyboard.shortcut(for: .newTab) == WeirShortcutAction.newTab.defaultShortcut)
    }

    /// `ShortcutModifiers` is an `OptionSet` backed by a `UInt8`
    /// raw value. Bits we don't define are simply ignored — round-
    /// tripping a value with future bits set must not crash. Note
    /// that Swift's default `Codable` synth wraps `OptionSet` values
    /// as a single-key keyed container (`{"rawValue":N}`) — match
    /// that shape so the regression test exercises real on-disk
    /// behavior.
    @Test("ShortcutModifiers decodes future bits without crashing")
    func decoder_modifiersTolerateUnknownBits() throws {
        let original = ShortcutModifiers(rawValue: 0xFF)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutModifiers.self, from: data)
        #expect(decoded.contains(.command))
        #expect(decoded.contains(.shift))
        #expect(decoded.contains(.option))
        #expect(decoded.contains(.control))
        #expect(decoded.rawValue == 0xFF)
    }
}
