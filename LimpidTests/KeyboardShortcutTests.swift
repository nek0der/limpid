// KeyboardShortcutTests.swift
// Limpid — model + serializer + validation coverage for the
// user-customizable shortcut layer. We can't drive `NSEvent` capture
// from a unit test (no key delivery in a headless run), so the
// recorder path is exercised indirectly: `StoredShortcut` round-trips
// through Codable + the Ghostty trigger string, and the bridge proves
// the lines reach the generated config.

import Foundation
import Testing
@testable import Limpid

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

    @Test("Trigger string concatenates modifiers and key")
    func ghosttyTrigger_format() {
        let s = StoredShortcut(key: "t", modifiers: [.command, .shift])
        #expect(s.ghosttyTrigger == "super+shift+t")
    }

    @Test("Display string maps named keys to glyphs")
    func displayString_namedKeys() {
        #expect(StoredShortcut(key: "left", modifiers: [.command]).displayString == "⌘←")
        #expect(StoredShortcut(key: "return", modifiers: [.command, .shift]).displayString == "⇧⌘⏎")
        #expect(StoredShortcut(key: "t", modifiers: [.command]).displayString == "⌘T")
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
        #expect(kb.shortcut(for: .newTab) == LimpidShortcutAction.newTab.defaultShortcut)
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
        #expect(kb.shortcut(for: .newTab) == LimpidShortcutAction.newTab.defaultShortcut)
    }

    // MARK: - GhosttyConfigBridge integration

    /// The bridge MUST emit user keybinds *after* its hardcoded
    /// `keybind = …` lines so libghostty's last-write-wins merging
    /// guarantees the user's choice trumps Ghostty defaults.
    @Test("User overrides appear after forced-override keybinds")
    func bridge_overridesAppearLast() {
        // Pick a libghostty-routed action (font size) so the
        // override actually lands in the emitted config. Menu-owned
        // actions like `.newTab` deliberately skip emit.
        var settings = LimpidSettings.default
        settings.keyboard.setOverride(
            .init(key: "k", modifiers: [.command, .control]),
            for: .increaseFontSize
        )
        let config = GhosttyConfigBridge.makeConfigString(
            settings: settings,
            resourcesDir: nil,
            appearance: .dark
        )
        guard
            let forcedIdx = config.range(of: "keybind = super+q=unbind"),
            let userIdx = config.range(of: "keybind = super+ctrl+k=increase_font_size:1")
        else {
            Issue.record("expected both forced override and user binding to appear in config")
            return
        }
        #expect(forcedIdx.lowerBound < userIdx.lowerBound)
    }

    @Test("Every libghostty-routed action with a default emits a keybind line")
    func bridge_defaultsEmitAllGhosttyActions() {
        let config = GhosttyConfigBridge.makeConfigString(
            settings: .default,
            resourcesDir: nil,
            appearance: .dark
        )
        for action in LimpidShortcutAction.allCases {
            guard let ghosttyAction = action.ghosttyAction,
                  let shortcut = action.defaultShortcut
            else { continue }
            let expected = "keybind = \(shortcut.ghosttyTrigger)=\(ghosttyAction)"
            #expect(
                config.contains(expected),
                "expected default binding for \(action.rawValue): \(expected)"
            )
        }
    }

    /// The set of `ghosttyAction` strings we emit must stay limited
    /// to actions with **no menu item** — otherwise the menu's
    /// `keyboardShortcut` and libghostty's keybind both fire for the
    /// same keystroke, producing duplicate actions (e.g. ⌘D
    /// splitting twice). Snapshot test — when someone adds a new
    /// non-`nil` `ghosttyAction`, this fails until they confirm the
    /// action has no menu Button.
    @Test("Emitted libghostty actions stay limited to menu-less actions")
    func bridge_emittedActionsMatchHandlers() {
        let emitted = Set(LimpidShortcutAction.allCases.compactMap(\.ghosttyAction))
        let expected: Set = [
            // Font-size actions are the only ones libghostty owns —
            // they have no menu item, so there's no risk of the menu
            // path also firing.
            "increase_font_size:1",
            "decrease_font_size:1",
            "reset_font_size"
        ]
        #expect(emitted == expected, """
        `ghosttyAction` set drifted. Adding a binding for an action \
        that also has a menu Button reintroduces the double-fire bug \
        (two splits per ⌘D, two tab closes per ⌘⌥W, etc.). See \
        `LimpidShortcutAction.ghosttyAction` doc.
        """)
    }

    /// Menu-owned actions must NOT have a libghostty keybind emitted.
    /// If they did, `eventHitsKeybind` would claim the event and the
    /// resulting `action_cb` would silently drop (no Limpid handler).
    /// Regression guard against the "NEW_TAB never fires when a
    /// surface is focused" bug.
    @Test("Menu-owned actions are absent from libghostty's keybind section")
    func bridge_skipsMenuOwnedActions() throws {
        let config = GhosttyConfigBridge.makeConfigString(
            settings: .default,
            resourcesDir: nil,
            appearance: .dark
        )
        // newTab / nextTab / focus* live in the menu — no libghostty
        // keybind for them. newWorktree is Limpid-only (no ghostty
        // action at all) so it's also absent.
        for action: LimpidShortcutAction in [.newTab, .nextTab, .focusPaneLeft, .newWorktree] {
            let trigger = try #require(action.defaultShortcut?.ghosttyTrigger)
            #expect(
                !config.contains("keybind = \(trigger)="),
                "menu-owned action \(action.rawValue) leaked into libghostty config"
            )
        }
    }

    @Test("keybind = clear is emitted to wipe libghostty defaults")
    func bridge_emitsKeybindClear() {
        let config = GhosttyConfigBridge.makeConfigString(
            settings: .default,
            resourcesDir: nil,
            appearance: .dark
        )
        #expect(config.contains("keybind = clear"))
    }

    // MARK: - Validation

    @Test("Validate rejects a trigger already used by another action")
    func validate_conflictDetected() throws {
        var kb = KeyboardSettings()
        // newTab default is ⌘T. Try to bind closeSurface to ⌘T.
        let stolen = try #require(LimpidShortcutAction.newTab.defaultShortcut)
        let result = kb.validate(stolen, for: .closeSurface)
        #expect(result == .conflict(.newTab))
        // No actual mutation happens — the recorder is responsible
        // for skipping setOverride on a non-.ok result.
        #expect(kb.overrides.isEmpty)
    }

    @Test("Validate rejects ⌘1 (reserved for tab jump)")
    func validate_reservedTrigger() {
        let kb = KeyboardSettings()
        let reserved = StoredShortcut(key: "1", modifiers: [.command])
        #expect(kb.validate(reserved, for: .newTab) == .reserved)
    }

    // MARK: - Encoding shape

    /// Punctuation keys must be stored as their literal character
    /// (not Ghostty's physical-key name like `equal` / `bracket_left`).
    /// This is the JIS-fix invariant: literal triggers route through
    /// libghostty's `utf8` / `unshifted_codepoint` match cascade,
    /// which works regardless of keyboard layout.
    @Test("Punctuation defaults are stored as literal characters")
    func encoding_punctuationDefaultsAreLiteral() throws {
        let increase = try #require(LimpidShortcutAction.increaseFontSize.defaultShortcut)
        #expect(increase.key == "=")
        let decrease = try #require(LimpidShortcutAction.decreaseFontSize.defaultShortcut)
        #expect(decrease.key == "-")
        let reset = try #require(LimpidShortcutAction.resetFontSize.defaultShortcut)
        #expect(reset.key == "0")
        let nextSection = try #require(LimpidShortcutAction.nextSection.defaultShortcut)
        #expect(nextSection.key == "]")
    }

    /// The literal `+` character can't be emitted between `+`
    /// separators (`super++` is ambiguous), so the trigger string
    /// uses Ghostty's `plus` alias.
    @Test("`+` key emits as `plus` alias in trigger")
    func encoding_plusAlias() {
        let s = StoredShortcut(key: "+", modifiers: [.command])
        #expect(s.ghosttyTrigger == "super+plus")
    }

    @Test("Validate allows an unused trigger")
    func validate_okOnFreeTrigger() {
        let kb = KeyboardSettings()
        let free = StoredShortcut(key: "k", modifiers: [.command, .control, .shift])
        #expect(kb.validate(free, for: .newTab) == .ok)
    }

    /// Re-saving an action's own current shortcut must not flag
    /// itself as a conflict. The recorder hits this when a user
    /// records the same key back into the same action — without the
    /// `other != action` filter in `validate` we'd refuse a no-op.
    @Test("Validate ignores self when checking conflicts")
    func validate_ignoresSelf() throws {
        var kb = KeyboardSettings()
        let current = try #require(LimpidShortcutAction.newTab.defaultShortcut)
        kb.setOverride(current, for: .newTab)
        #expect(kb.validate(current, for: .newTab) == .ok)
    }

    /// `super+q` is in `ReservedShortcuts.triggers` because Limpid
    /// routes ⌘Q through AppKit's terminate path (state save). A
    /// user binding to ⌘Q would race that path.
    @Test("Validate rejects ⌘Q (reserved by quit path)")
    func validate_reservedQuit() {
        let kb = KeyboardSettings()
        let quit = StoredShortcut(key: "q", modifiers: [.command])
        #expect(kb.validate(quit, for: .newTab) == .reserved)
    }

    /// A bare letter (no ⌘/⌥/⌃/⇧) would hijack every plain
    /// keypress of that character and break the terminal. The
    /// recorder must reject it — `missingModifier` is the gate.
    @Test("Validate rejects shortcut without any modifier")
    func validate_missingModifier() {
        let kb = KeyboardSettings()
        let bare = StoredShortcut(key: "k", modifiers: [])
        #expect(kb.validate(bare, for: .newTab) == .missingModifier)
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
         "appearance":{"windowTint":"default","backgroundOpacity":0.92,"transparency":"system"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{},
         "advanced":{"useGhosttyConfigFile":false}}
        """#
        let decoded = try JSONDecoder().decode(LimpidSettings.self, from: Data(legacy.utf8))
        #expect(decoded.keyboard.overrides.isEmpty)
        #expect(decoded.keyboard.shortcut(for: .newTab) == LimpidShortcutAction.newTab.defaultShortcut)
    }

    /// `ShortcutModifiers` is an `OptionSet` backed by a `UInt8`
    /// raw value. Bits we don't define are simply ignored — round-
    /// tripping a value with future bits set must not crash. Note
    /// that Swift's default `Codable` synth wraps `OptionSet` values
    /// as a single-key keyed container (`{"rawValue":N}`) — match
    /// that shape so the regression test exercises real on-disk
    /// behaviour.
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

    // MARK: - Bridge order

    /// `keybind = clear` must appear before user bindings so it
    /// wipes libghostty's built-in macOS defaults without erasing
    /// our re-emitted bindings on the next line. Order regression
    /// here would silently let Ghostty defaults leak through.
    @Test("keybind = clear precedes user-effective bindings")
    func bridge_clearBeforeUserBindings() {
        let config = GhosttyConfigBridge.makeConfigString(
            settings: .default,
            resourcesDir: nil,
            appearance: .dark
        )
        guard
            let clearIdx = config.range(of: "keybind = clear"),
            // `.increaseFontSize` is one of the few actions still
            // routed through libghostty (no menu item), so its
            // default ⌘+ shortcut shows up in the emitted config.
            let userIdx = config.range(of: "keybind = super+shift+==increase_font_size:1")
        else {
            Issue.record("expected `keybind = clear` and a default user binding to appear")
            return
        }
        #expect(clearIdx.lowerBound < userIdx.lowerBound)
    }
}
