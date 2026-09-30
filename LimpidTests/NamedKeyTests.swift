// NamedKeyTests.swift
// Limpid — coverage for the named-key table: key codes in both directions,
// the stored names, and a function key captured by the shortcut recorder.

import AppKit
import Testing
@testable import Limpid

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
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: f13,
            charactersIgnoringModifiers: f13,
            isARepeat: false,
            keyCode: 105
        ))

        #expect(StoredShortcut.capture(from: event)?.key == "f13")
        #expect(HotKeyMapping.keyCode(for: "f13", translate: { _ in nil }) == 105)
    }

    @Test("a function key shows its name in menus and has no SwiftUI constant")
    func functionKey_menuAffordance() {
        #expect(NamedKey.f13.glyph == "F13")
        #expect(NamedKey.f13.keyEquivalent == nil)
        #expect(NamedKey.escape.keyEquivalent == .escape)
    }
}
