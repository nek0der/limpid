// SystemHotKeys.swift
// Limpid — the system-wide shortcuts macOS has enabled right now (System
// Settings → Keyboard → Keyboard Shortcuts), as the same keyCode and
// Carbon modifier pairs we register the quick terminal hotkey with.

import Carbon.HIToolbox
import Foundation

enum SystemHotKeys {
    /// The enabled symbolic hotkeys. We read them at the moment we need
    /// them instead of caching: the user can add, change, or disable one
    /// in System Settings at any time, and Carbon posts no notification.
    /// The header warns the call is O(number of hotkeys), which is why
    /// callers query on a user action or a settings change, never on a
    /// timer.
    static func current() -> Set<HotKeyCombination> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let unmanaged else { return [] }
        // `CopySymbolicHotKeys` follows the Copy rule, so we own the array.
        let entries = unmanaged.takeRetainedValue() as? [[String: Any]] ?? []
        return combinations(from: entries)
    }

    /// Turn `CopySymbolicHotKeys` entries into combinations comparable with
    /// `HotKeyMapping.combination(for:translate:)`.
    ///
    /// `kHISymbolicHotKeyModifiers` is a Carbon modifier mask, the format
    /// `RegisterEventHotKey` takes (`cmdKey` 0x100, `shiftKey` 0x200,
    /// `optionKey` 0x800, `controlKey` 0x1000); the header does not say so,
    /// but on macOS 27 ⌘Space reads as keyCode 49 with 0x100 and ⌘⇧3 as
    /// keyCode 20 with 0x300. Many entries also carry
    /// `kEventKeyModifierFnMask` (0x20000), which our masks never contain,
    /// so we resolve it first:
    /// - On arrows, F-keys, and the navigation block the bit is implicit:
    ///   the hardware reports every press of those keys with it, so ⌃↑
    ///   (Mission Control) is stored as 0x21000. We drop the bit.
    /// - On any other key it means the Globe key is part of the shortcut
    ///   (Globe⌃F fills the window, stored as keyCode 3 with 0x21000).
    ///   Our hotkey never includes Globe, so the entry cannot collide.
    static func combinations(from entries: [[String: Any]]) -> Set<HotKeyCombination> {
        var result: Set<HotKeyCombination> = []
        for entry in entries {
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let rawModifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value,
                  code != unassignedKeyCode
            else { continue }
            let fnMask = UInt32(kEventKeyModifierFnMask)
            if rawModifiers & fnMask != 0, !functionKeyCodes.contains(code) {
                continue
            }
            result.insert(HotKeyCombination(keyCode: code, carbonModifiers: rawModifiers & modifierMask))
        }
        return result
    }

    /// True when `shortcut`, resolved on the layout `translate` describes,
    /// is one of `systemHotKeys`. A key the layout cannot type has no
    /// keyCode to collide with, so it is not taken.
    static func contains(
        _ shortcut: StoredShortcut,
        in systemHotKeys: Set<HotKeyCombination>,
        translate: (UInt16) -> String?
    ) -> Bool {
        guard let combination = HotKeyMapping.combination(for: shortcut, translate: translate) else { return false }
        return systemHotKeys.contains(combination)
    }

    /// The four modifiers `HotKeyMapping.carbonModifiers(for:)` produces.
    /// Anything else in an entry's mask has no counterpart in a stored
    /// shortcut and must not keep an otherwise equal pair from matching.
    static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// Placeholder keyCode of a symbolic hotkey that has no key assigned.
    static let unassignedKeyCode: UInt32 = 0xFFFF

    /// Keys whose presses always carry `kEventKeyModifierFnMask`: the
    /// arrows, F1–F20, Home, End, Page Up, Page Down, Forward Delete, and
    /// Help.
    static let functionKeyCodes: Set<UInt32> = [
        123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
        115, 119, 116, 121, 117, 114
    ]
}
