// NamedKeyTests.swift
// Weir — coverage for the named-key table: key codes in both directions,
// the stored names, a function key captured by the shortcut recorder, and
// the menu key a function key maps to.

import AppKit
import Testing
@testable import Weir

@Suite("NamedKey")
@MainActor
struct NamedKeyTests {
    @Test("every key code reads back as the key that lists it")
    func keyCode_roundTrip_returnsListingKey() {
        for key in NamedKey.allCases {
            #expect(!key.keyCodes.isEmpty)
            for code in key.keyCodes {
                #expect(NamedKey(keyCode: code) == key)
            }
        }
    }

    @Test("the keypad's Enter reads as Return, and we type the main-block key")
    func keypadEnter_readsAsReturn() {
        #expect(NamedKey(keyCode: 76) == .return)
        #expect(NamedKey.return.primaryKeyCode == 36)
    }

    @Test("a stored name resolves to its key, with enter as Return")
    func storedName_resolvesAliasAndRejectsCharacters() {
        #expect(NamedKey(storedName: "page_up") == .pageUp)
        #expect(NamedKey(storedName: "enter") == .return)
        #expect(NamedKey(storedName: "a") == nil)
    }

    @Test("a key that types a character has no name")
    func keyCode_letter_isNotNamed() {
        // Key code 0 types a letter on every layout: A on US, Q on AZERTY.
        #expect(NamedKey(keyCode: 0) == nil)
    }

    @Test("the recorder stores F13 by name, and the hotkey maps it back")
    func capture_f13_storesName() throws {
        let scalar = try #require(UnicodeScalar(UInt16(NSF13FunctionKey)))
        let f13 = String(Character(scalar))
        let event = try NSEvent.testKeyDown(keyCode: 105, characters: f13)

        #expect(StoredShortcut.capture(from: event)?.key == "f13")
        #expect(HotKeyMapping.keyCode(for: "f13", translate: { _ in nil }) == 105)
    }

    @Test("a function key shows its name in menus")
    func functionKey_glyph_isName() {
        #expect(NamedKey.f13.glyph == "F13")
        #expect(NamedKey.escape.keyEquivalent == .escape)
    }

    /// Each key's menu character is `MenuShortcutTests`'s, against AppKit's
    /// constant for that key.
    @Test("the function keys are F1 through F20, and no other key has a number")
    func functionKeys_areNumberedOneToTwenty() {
        let numbers = NamedKey.allCases.filter(\.isFunctionKey).compactMap(\.functionKeyNumber)
        #expect(numbers.sorted() == Array(1...20))
        #expect(NamedKey.escape.functionKeyNumber == nil)
    }

    @Test("a stored function-key shortcut has a menu key")
    func storedFunctionKey_hasSwiftUIKeyEquivalent() {
        let shortcut = StoredShortcut(key: "f13", modifiers: [.control])
        #expect(shortcut.swiftUIKeyEquivalent == NamedKey.f13.keyEquivalent)
        #expect(StoredShortcut(key: "not_a_key", modifiers: []).swiftUIKeyEquivalent == nil)
    }

    /// SwiftUI copies the key's character into `NSMenuItem.keyEquivalent`; this
    /// checks the AppKit half, that a menu item holding our character fires on
    /// the key event a function key sends, which carries the fn flag the
    /// item's mask does not name.
    @Test("a menu item with a function key fires on that key", arguments: [
        (NamedKey.f5, NSEvent.ModifierFlags.control),
        (NamedKey.f13, NSEvent.ModifierFlags.control),
        (NamedKey.f13, NSEvent.ModifierFlags()),
    ])
    func functionKeyMenuItem_firesOnKey(key: NamedKey, modifiers: NSEvent.ModifierFlags) throws {
        let target = MenuTarget()
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Probe",
            action: #selector(MenuTarget.fire(_:)),
            keyEquivalent: String(key.keyEquivalent.character)
        )
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)

        let pressed = try Self.keyDown(key, modifiers: modifiers)
        #expect(menu.performKeyEquivalent(with: pressed))
        #expect(target.fireCount == 1)

        let otherKey: NamedKey = key == .f6 ? .f7 : .f6
        let other = try Self.keyDown(otherKey, modifiers: modifiers)
        #expect(!menu.performKeyEquivalent(with: other))
        #expect(target.fireCount == 1)
    }

    private static func keyDown(_ key: NamedKey, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let text = String(key.keyEquivalent.character)
        return try NSEvent.testKeyDown(keyCode: key.primaryKeyCode, modifiers: modifiers.union(.function), characters: text)
    }
}

/// Counts how often the probe menu item runs its action.
@MainActor
private final class MenuTarget: NSObject {
    private(set) var fireCount = 0

    @objc func fire(_: NSMenuItem) {
        fireCount += 1
    }
}
