// ModifierChord.swift
// Limpid — the modifier keys that change what a key or a click means, Caps Lock and the device's own flags aside.

import AppKit
import SwiftUI

/// The keys a shortcut check compares: ⌘, ⌃, ⌥, and ⇧. Caps Lock, the
/// keypad, the function key, and the device's own flags ride along on an
/// event without changing what it means, so a check that compares the
/// whole set fails with Caps Lock on (⌘Return in the palette, project ▾,
/// and the review tab; ⌘-click).
extension EventModifiers {
    var chord: EventModifiers {
        intersection([.command, .control, .option, .shift])
    }
}

extension NSEvent.ModifierFlags {
    var chord: NSEvent.ModifierFlags {
        intersection([.command, .control, .option, .shift])
    }
}
