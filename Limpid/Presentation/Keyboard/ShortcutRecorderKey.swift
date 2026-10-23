// ShortcutRecorderKey.swift
// Limpid — what a key does while a shortcut recorder is armed, the same in Keyboard and Quick Terminal.

import Foundation

/// The meaning of the next key a recorder takes. ⌫ restores the
/// default in both panes, so one key never means two things: for an action
/// that is its built-in shortcut, for the quick terminal's hotkey it is
/// none. Unassigning is the row's menu item, not a key.
enum ShortcutRecorderKey: Equatable {
    case cancel
    case restoreDefault
    case record

    static func meaning(of key: NamedKey?) -> Self {
        switch key {
        case .escape: .cancel
        case .backspace: .restoreDefault
        default: .record
        }
    }
}
