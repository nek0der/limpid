// SurfaceKeyboardTranslationTests.swift
// Weir — verifies the modifier boundary between AppKit text translation
// and the raw key event sent to libghostty.

import AppKit
import Carbon.HIToolbox
import GhosttyKit
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Surface keyboard translation")
@MainActor
struct SurfaceKeyboardTranslationTests {
    @Test("An unchanged modifier decision reuses the original event")
    func unchangedModifiers_preserveEventIdentity() throws {
        let event = try NSEvent.testKeyDown(keyCode: 11, modifiers: [.shift, .option], characters: "b", timestamp: 1)
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
        let event = try NSEvent.testKeyDown(
            keyCode: 11,
            modifiers: [.option, .numericPad, deviceRightOption],
            characters: "b",
            timestamp: 1
        )
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

    // MARK: - ⌘⏎

    @Test("Command with the keypad's Enter is the same press as with Return")
    func keypadEnter_isTreatedTheSame() {
        let fromReturn = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command, .capsLock],
            isComposing: false,
            isRepeat: false
        )
        let fromKeypad = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_ANSI_KeypadEnter),
            modifierFlags: [.command, .numericPad, .function],
            isComposing: false,
            isRepeat: false
        )
        #expect(fromReturn == PrimaryKeyPress(isCommandOnly: true, isComposing: false))
        #expect(fromKeypad == fromReturn)
    }

    @Test("A taken key's release is held back once, and a missed release ends the wait")
    func takenKeyRelease_holdsBackOnlyItsOwnRelease() {
        let returnKey = UInt16(kVK_Return)
        var release = TakenKeyRelease()
        release.take(keyCode: returnKey)
        let otherKey = release.takesRelease(keyCode: UInt16(kVK_ANSI_J))
        #expect(!otherKey)
        release.notePress(keyCode: returnKey, isRepeat: true)
        let first = release.takesRelease(keyCode: returnKey)
        let second = release.takesRelease(keyCode: returnKey)
        #expect(first)
        #expect(!second, "only once")

        // ⌘ held to the end: AppKit sends no key-up, so the next plain
        // Return is released as usual.
        release.take(keyCode: returnKey)
        release.notePress(keyCode: returnKey, isRepeat: false)
        let afterMissed = release.takesRelease(keyCode: returnKey)
        #expect(!afterMissed)

        release.take(keyCode: returnKey)
        release.reset()
        let afterReset = release.takesRelease(keyCode: returnKey)
        #expect(!afterReset)
    }

    @Test("A composition, another chord, and other keys are not the bar's")
    func compositionOtherChordsAndOtherKeys_areNotTheBars() {
        let composing = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command],
            isComposing: true,
            isRepeat: true
        )
        #expect(composing == PrimaryKeyPress(isCommandOnly: true, isComposing: true, isRepeat: true))
        let optionCommand = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command, .option],
            isComposing: false,
            isRepeat: false
        )
        #expect(optionCommand?.isCommandOnly == false)
        #expect(SurfaceView
            .primaryKeyPress(keyCode: UInt16(kVK_Return), modifierFlags: [.shift], isComposing: false, isRepeat: false) == nil)
        #expect(SurfaceView
            .primaryKeyPress(keyCode: UInt16(kVK_ANSI_J), modifierFlags: [.command], isComposing: false, isRepeat: false) == nil)
    }
}
