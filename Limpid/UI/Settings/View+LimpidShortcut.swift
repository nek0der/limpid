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
        applyingShortcut(store.settings.keyboard.shortcut(for: action))
    }

    /// Show `shortcut` beside an item of a `.contextMenu`, or no key for
    /// `nil`. See `MenuCommand` for which items show one.
    ///
    /// Only inside `.contextMenu`. SwiftUI builds that menu when it opens
    /// and drops it when it closes, so the item answers its key only while
    /// the menu is open and the keystroke otherwise reaches the menu bar.
    /// Inside a `Menu`, SwiftUI keeps the shortcut live in the window after
    /// the first open, ahead of the menu bar; `PopUpMenuButton` is for those.
    func contextMenuShortcut(_ shortcut: StoredShortcut?) -> some View {
        applyingShortcut(shortcut)
    }

    private func applyingShortcut(_ shortcut: StoredShortcut?) -> some View {
        Group {
            if let shortcut, let key = shortcut.swiftUIKeyEquivalent {
                self.keyboardShortcut(key, modifiers: shortcut.modifiers.swiftUIEventModifiers)
            } else {
                self
            }
        }
    }
}
