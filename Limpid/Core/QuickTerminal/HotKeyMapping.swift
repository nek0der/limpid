// HotKeyMapping.swift
// Limpid — maps a `StoredShortcut` to the virtual keyCode and Carbon
// modifier mask `RegisterEventHotKey` expects.

import Carbon.HIToolbox
import Foundation

/// Virtual keyCode plus Carbon modifier mask for one global hotkey.
struct HotKeyCombination: Hashable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
}

enum HotKeyMapping {
    /// Virtual keyCodes the layout scan covers. Hardware keyCodes on every
    /// Mac keyboard fall below 128.
    static let keyCodeRange: ClosedRange<UInt16> = 0...127

    /// Resolve `shortcut` against a keyboard layout. `translate` maps a
    /// virtual keyCode to the character it types with no modifiers held;
    /// production passes `StoredShortcut.currentLayoutTranslator()`.
    /// Returns `nil` when no key on the layout produces the stored key.
    static func combination(
        for shortcut: StoredShortcut,
        translate: (UInt16) -> String?
    ) -> HotKeyCombination? {
        guard let keyCode = keyCode(for: shortcut.key, translate: translate) else { return nil }
        return HotKeyCombination(
            keyCode: UInt32(keyCode),
            carbonModifiers: carbonModifiers(for: shortcut.modifiers)
        )
    }

    /// Named keys (arrows, return, F-keys…) are layout-independent and come
    /// from the capture table. Everything else is stored as the character
    /// the layout types, so we scan the layout for the key that types it.
    ///
    /// Both paths take the lowest keyCode when several match: `return` is
    /// both 36 and the keypad's 76, and digits exist on the top row and
    /// the keypad. The main-block key is the one the user pressed in the
    /// recorder on a keyboard without a keypad, and it has the lower code.
    static func keyCode(for key: String, translate: (UInt16) -> String?) -> UInt16? {
        let named = key == "enter" ? "return" : key
        if let code = StoredShortcut.keyCodeNames
            .filter({ $0.value == named })
            .map(\.key)
            .min()
        {
            return code
        }
        let wanted = key.lowercased()
        return keyCodeRange.first { code in
            // Skip named keys: the keypad's Enter translates to a control
            // character, and a named key never stands for a layout
            // character.
            guard StoredShortcut.keyCodeNames[code] == nil else { return false }
            return translate(code)?.lowercased() == wanted
        }
    }

    /// Carbon's modifier bits for `RegisterEventHotKey`.
    static func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) {
            mask |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            mask |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            mask |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            mask |= UInt32(controlKey)
        }
        return mask
    }
}
