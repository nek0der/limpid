// KeyboardSettings+Restore.swift
// Weir — unassigning a shortcut from Settings and bringing back its default.

import Foundation

extension KeyboardSettings {
    /// Whether ↺ and "Restore Default" can do something for `action`: it
    /// has an override, or the person unassigned it. A default given up to
    /// another binding or the hotkey (`unbound`) has none: restoring it
    /// would leave it given up, and it comes back on its own once its keys
    /// are free.
    func canRestoreDefault(_ action: WeirShortcutAction) -> Bool {
        overrides[action.rawValue] != nil || unassigned.contains(action.rawValue)
    }

    /// The action back on its default: no override, and not unassigned.
    /// A default whose keys another binding or the quick terminal's hotkey
    /// holds stays given up (`normalize`), so no two share keys.
    mutating func restoreDefault(for action: WeirShortcutAction) {
        resetOverride(for: action)
        unassigned.removeAll { $0 == action.rawValue }
    }

    /// The action left with no keys, the person's choice (Keyboard's
    /// "Unassign"): its override goes, and a default it has stays off in
    /// `unassigned` until the person restores it.
    mutating func unassign(_ action: WeirShortcutAction) {
        resetOverride(for: action)
        if action.defaultShortcut != nil, !unassigned.contains(action.rawValue) {
            unassigned.append(action.rawValue)
        }
    }
}
