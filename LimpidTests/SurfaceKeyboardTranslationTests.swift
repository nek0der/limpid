// SurfaceKeyboardTranslationTests.swift
// Limpid — verifies the modifier boundary between AppKit text translation
// and the raw key event sent to libghostty.

import AppKit
import GhosttyKit
import Testing
@testable import Limpid

@Suite("Surface keyboard translation")
@MainActor
struct SurfaceKeyboardTranslationTests {
    @Test("An unchanged modifier decision reuses the original event")
    func unchangedModifiers_preserveEventIdentity() throws {
        let event = try #require(makeEvent(modifiers: [.shift, .option]))
        let translated = SurfaceView.translationEvent(
            from: event,
            using: SurfaceView.translateMods(event.modifierFlags)
        )

        #expect(translated === event)
    }

    @Test("Option can be removed from text translation without changing the raw key")
    func optionAsAlt_separatesTranslationFromRawEvent() throws {
        let deviceRightOption = NSEvent.ModifierFlags(
            rawValue: UInt(NX_DEVICERALTKEYMASK)
        )
        let event = try #require(makeEvent(modifiers: [.option, .numericPad, deviceRightOption]))
        let translated = SurfaceView.translationEvent(
            from: event,
            using: GHOSTTY_MODS_NONE
        )
        let rawKey = SurfaceView.makeKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            consumedMods: SurfaceView.translateMods(translated.modifierFlags)
        )

        #expect(!translated.modifierFlags.contains(.option))
        #expect(translated.modifierFlags.contains(.numericPad))
        #expect(rawKey.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(rawKey.mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue != 0)
        #expect(rawKey.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue == 0)
    }

    @Test("A modifier-only event never enters AppKit character translation")
    func flagsChanged_skipsCharacterTranslation() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let coreEvent = try #require(CGEvent(
            keyboardEventSource: source,
            virtualKey: 58,
            keyDown: true
        ))
        coreEvent.type = .flagsChanged
        coreEvent.flags = .maskAlternate
        let event = try #require(NSEvent(cgEvent: coreEvent))

        let translated = SurfaceView.translationEvent(
            from: event,
            using: GHOSTTY_MODS_NONE
        )
        let key = SurfaceView.makeKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            consumedMods: GHOSTTY_MODS_NONE
        )

        #expect(translated === event)
        #expect(SurfaceView.bindingText(from: event).isEmpty)
        #expect(key.unshifted_codepoint == 0)
    }

    private func makeEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )
    }
}
