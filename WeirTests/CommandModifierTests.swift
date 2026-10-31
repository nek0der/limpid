// CommandModifierTests.swift
// Weir — when a click or a Return counts as made with ⌘: a click AppKit is handling, and Caps Lock aside.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// ⌘-click and ⌘Return open a project in a new window. A click is
/// read from the event AppKit is handling only when that event is the
/// click, so a press from the keyboard or VoiceOver, or an event kept from
/// earlier, never opens one; and ⌘Return holds with Caps Lock on.
@MainActor
struct CommandModifierTests {
    @Test func aCommandClick_isAClickWithCommandAlone_neverAKeptOrKeyEvent() {
        let click = { (type: NSEvent.EventType, flags: NSEvent.ModifierFlags) in
            NewWindowModifier.isCommandClick(type: type, modifierFlags: flags)
        }
        #expect(click(.leftMouseUp, .command))
        #expect(click(.leftMouseDown, .command))
        // Caps Lock and the device's own flags aside.
        #expect(click(.leftMouseUp, [.command, .capsLock, .numericPad]))
        #expect(!click(.leftMouseUp, []))
        #expect(!click(.leftMouseUp, [.command, .shift]))
        // A press from the keyboard (Full Keyboard Access, VoiceOver's
        // keys) or any other event is never a click.
        #expect(!click(.keyDown, .command))
        #expect(!click(.keyUp, .command))
        #expect(!click(.flagsChanged, .command))
        #expect(!click(.rightMouseUp, .command))
    }

    /// SwiftUI's ⌘ tap also takes ⇧⌘ and ⌥⌘ (`View.onClick`); the keys held
    /// as it ends decide, by the rule a `Button` row reads, so every row
    /// opens a ⇧⌘- or ⌥⌘-click where it is.
    @Test func aClickWithCommandAndAnotherKey_isNoCommandClick_atAnyRow() {
        #expect(NewWindowModifier.isCommandOnly(.command))
        #expect(NewWindowModifier.isCommandOnly([.command, .capsLock]))
        #expect(!NewWindowModifier.isCommandOnly([.command, .shift]))
        #expect(!NewWindowModifier.isCommandOnly([.command, .option]))
        #expect(!NewWindowModifier.isCommandOnly([.command, .control]))
        #expect(!NewWindowModifier.isCommandOnly([]))
        #expect(NSEvent.ModifierFlags([.command, .capsLock, .numericPad, .function]).chord == .command)
    }

    @Test func aCommandReturn_holdsWithCapsLockOn() {
        #expect(EventModifiers([.command, .capsLock]).chord == .command)
        #expect(EventModifiers([.command, .numericPad]).chord == .command)
        #expect(EventModifiers([.command, .shift]).chord != .command)
    }
}
