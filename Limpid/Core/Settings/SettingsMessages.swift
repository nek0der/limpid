// SettingsMessages.swift
// Limpid — what Settings says about a choice or a rejected shortcut, kept
// beside the model so the panes only render it.
//
// Every value is a `LocalizedStringResource`, which the pane draws in the
// Settings window's locale, so the text switches with the display language
// while it is on screen. The optional messages wrap a non-optional `switch`:
// the string catalog's extraction reads literals typed as a resource, and
// misses those converted straight to an optional one.

import Foundation

extension ConfirmPolicy {
    /// The confirmation picker's label for this policy.
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .never: "Never"
        case .onlyWhenAgent: "Only when an agent is active"
        case .always: "Always"
        }
    }
}

extension ShortcutValidation {
    /// Why the recorder refused a combination, or `nil` when it took it.
    var message: LocalizedStringResource? {
        self == .ok ? nil : refusal
    }

    private var refusal: LocalizedStringResource {
        switch self {
        case .ok:
            ""
        case let .conflict(other):
            // One template rather than pieces, so translators can reorder
            // (ja wants the noun before the verb). The action's own name is
            // interpolated as a resource, which resolves in the same locale
            // as the sentence around it.
            "Already bound to \(other.localizedTitle)"
        case .reserved:
            "Reserved by Limpid (⌘1–⌘9, ⌘⌃1–⌘⌃9)"
        case .missingModifier:
            "Shortcut must include ⌘, ⌥, ⌃, or ⇧"
        case .quickTerminalConflict:
            "Already used by the Quick Terminal hotkey"
        }
    }
}

extension QuickTerminalHotKeyValidation {
    /// Why the hotkey recorder refused a combination, or `nil` when it
    /// took it.
    var message: LocalizedStringResource? {
        self == .ok ? nil : refusal
    }

    private var refusal: LocalizedStringResource {
        switch self {
        case .ok:
            ""
        case .missingPrimaryModifier:
            "Hotkey must include ⌘ or ⌃."
        case .reserved:
            "Limpid reserves this combination for its own use."
        case .takenBySystem:
            "macOS uses this combination."
        case let .conflictsWithMenu(action):
            "Already bound to \(action.localizedTitle)"
        }
    }
}

extension QuickTerminalHotKeyProblem {
    /// Why the saved hotkey is not active, shown under the recorder.
    var message: LocalizedStringResource {
        switch self {
        case .terminalUnavailable:
            "The terminal failed to start, so the hotkey is off."
        case .keyNotOnLayout:
            "No key on the current keyboard layout types this hotkey."
        case let .registrationFailed(status) where status == Self.alreadyTakenStatus:
            "Another app already uses this hotkey."
        case let .registrationFailed(status):
            "The hotkey could not be registered (error \(Int(status)))."
        case let .conflictsWithMenu(action):
            "The hotkey is off because \(action.localizedTitle) uses the same keys."
        case .takenBySystem:
            "The hotkey is off because macOS uses the same keys."
        }
    }
}

extension QuickTerminalSettings {
    /// The caution shown under a saved hotkey that other apps may also use
    /// for their own commands; see `mayOverlapAppCommands(_:)`.
    static let appCommandOverlapWarning: LocalizedStringResource =
        "Other apps may use this combination for their own commands."
}
