// KeyboardMigrationRows.swift
// Weir — the rows that say what the update did to a person's shortcuts, for Settings → Keyboard.

import Foundation

/// One shortcut of the person's the update changed: a binding kept
/// aside, or a new action left without its default because the person's
/// own keys held it.
struct KeyboardMigrationRow: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Kept aside until discarded; `rawValue` is its stored name.
        case retired(rawValue: String)
        case unassigned(WeirShortcutAction)
    }

    let kind: Kind
    let title: String
    /// What happened to it; `nil` for an unassigned action whose holder
    /// cannot be told.
    let detail: String?

    var id: String {
        switch kind {
        case let .retired(rawValue): "retired." + rawValue
        case let .unassigned(action): "unassigned." + action.rawValue
        }
    }
}

/// The rows of `KeyboardSettings.migrationNotice`, as Settings → Keyboard
/// lists them: kept-aside bindings first, then unassigned actions.
enum KeyboardMigrationRows {
    static func rows(
        _ keyboard: KeyboardSettings,
        quickTerminalHotKey: StoredShortcut?,
        locale: Locale
    ) -> [KeyboardMigrationRow] {
        guard let notice = keyboard.migrationNotice else { return [] }
        let retired = notice.retired.map { retired in
            KeyboardMigrationRow(
                kind: .retired(rawValue: retired.rawValue),
                title: title(of: retired.rawValue, locale: locale),
                detail: LocalizedStringResource(
                    "No longer assigned: \(retired.shortcut.displayString)",
                    comment: "Settings → Keyboard: a shortcut kept aside by the update; argument: its keys"
                ).resolved(in: locale)
            )
        }
        let unassigned = notice.conflicts.map { action in
            KeyboardMigrationRow(
                kind: .unassigned(action),
                title: action.localizedTitle.resolved(in: locale),
                detail: holderDetail(action, keyboard: keyboard, quickTerminalHotKey: quickTerminalHotKey, locale: locale)
            )
        }
        return retired + unassigned
    }

    /// An action's name; for one folded into another, the name of the one
    /// that took it over, which is where the person now finds it; else the
    /// stored name of one this build no longer has.
    static func title(of rawValue: String, locale: Locale) -> String {
        if rawValue == KeyboardSettings.quickTerminalHotKeyID {
            return LocalizedStringResource("Quick Terminal hotkey").resolved(in: locale)
        }
        let action = WeirShortcutAction(rawValue: rawValue) ?? WeirShortcutAction.foldedNames[rawValue]
        return action?.localizedTitle.resolved(in: locale) ?? rawValue
    }

    /// "Default ⌘N is used by …", naming the person's own binding or the
    /// quick terminal's hotkey.
    private static func holderDetail(
        _ action: WeirShortcutAction,
        keyboard: KeyboardSettings,
        quickTerminalHotKey: StoredShortcut?,
        locale: Locale
    ) -> String? {
        guard let fallback = action.defaultShortcut,
              let holder = keyboard.holderOfDefault(for: action, quickTerminalHotKey: quickTerminalHotKey)
        else { return nil }
        let holderName = switch holder {
        case let .action(other): other.localizedTitle.resolved(in: locale)
        case .quickTerminalHotKey: title(of: KeyboardSettings.quickTerminalHotKeyID, locale: locale)
        }
        return LocalizedStringResource(
            "Default \(fallback.displayString) is used by \(holderName)",
            comment: "Settings → Keyboard: a new shortcut left unassigned; arguments: its default keys, the action that holds them"
        ).resolved(in: locale)
    }
}
