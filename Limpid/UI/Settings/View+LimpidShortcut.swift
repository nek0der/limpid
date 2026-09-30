// View+LimpidShortcut.swift
// Limpid — SwiftUI bridge that reads a `LimpidShortcutAction`'s
// effective shortcut from `SettingsStore` and applies it via
// `.keyboardShortcut(...)`. This is the menu-bar half of Pattern A:
// menu items declare an action, the store decides the trigger,
// libghostty (via `GhosttyConfigBridge`) sees the same trigger in
// its keybind table.
//
// When the user rebinds an action in Settings → Keyboard, every
// menu Button using `.limpidShortcut(.thatAction, …)` re-evaluates
// because `SettingsStore` is `@Observable`. Result: the menu shows
// the new key glyph and intercepts the new keystroke without any
// per-menu code change.

import SwiftUI

extension View {

    /// Bind this view's `.keyboardShortcut` to whatever the user has
    /// configured for `action`. Falls through to the action's
    /// built-in default when no override is set. Every named key and
    /// every single character has a `KeyEquivalent`; the shortcut is
    /// dropped only for a stored key that is neither, which only a
    /// hand-edited settings file can produce.
    func limpidShortcut(
        _ action: LimpidShortcutAction,
        in store: SettingsStore
    ) -> some View {
        let resolved = store.settings.keyboard.shortcut(for: action)
        return Group {
            if let resolved, let key = resolved.swiftUIKeyEquivalent {
                self.keyboardShortcut(key, modifiers: resolved.modifiers.swiftUIEventModifiers)
            } else {
                self
            }
        }
    }
}
