// StoredShortcut+AppKitMenu.swift
// Limpid — the one conversion from a stored shortcut to what an AppKit
// menu item needs to show it, and to the key event it stands for.

import AppKit
import SwiftUI

extension StoredShortcut {
    /// The `keyEquivalent` and modifier mask that make an `NSMenuItem` show
    /// this shortcut. A letter goes in lowercase with Shift in the mask:
    /// AppKit reads an uppercase key equivalent as implying Shift, and we
    /// want the mask alone to say which modifiers the key takes. Named keys
    /// use the characters `NamedKey.keyEquivalent` already hands the menu
    /// bar, the AppKit function-key characters among them. Returns `nil`
    /// for a stored key that is neither, which only a hand-edited settings
    /// file can produce.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        if let named = NamedKey(storedName: self.key) {
            key = String(named.keyEquivalent.character)
        } else if self.key.count == 1 {
            key = self.key.lowercased()
        } else {
            return nil
        }
        return (key, modifiers.appKitModifierFlags)
    }

    /// Whether `event` is this shortcut pressed, matched the way the menu
    /// item showing it would match it: the same key and exactly these
    /// modifiers. For a view that answers the key itself, so the key it
    /// answers and the key its menu shows come from one value.
    func isPressed(in event: NSEvent) -> Bool {
        guard event.type == .keyDown, let equivalent = menuKeyEquivalent else { return false }
        let pressed = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return pressed == equivalent.modifiers
            && event.charactersIgnoringModifiers?.lowercased() == equivalent.key
    }
}

extension ShortcutModifiers {
    var appKitModifierFlags: NSEvent.ModifierFlags {
        var out: NSEvent.ModifierFlags = []
        if contains(.command) {
            out.insert(.command)
        }
        if contains(.shift) {
            out.insert(.shift)
        }
        if contains(.option) {
            out.insert(.option)
        }
        if contains(.control) {
            out.insert(.control)
        }
        return out
    }
}

@MainActor
extension NSMenuItem {
    /// Show `shortcut` beside the item's title, or no key for `nil`. See
    /// `MenuCommand` for which items show one.
    func showShortcut(_ shortcut: StoredShortcut?) {
        guard let equivalent = shortcut?.menuKeyEquivalent else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
            return
        }
        keyEquivalent = equivalent.key
        keyEquivalentModifierMask = equivalent.modifiers
    }
}
