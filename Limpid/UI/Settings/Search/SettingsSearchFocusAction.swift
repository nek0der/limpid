// SettingsSearchFocusAction.swift
// Limpid — Focused-scene routing for the app-wide Find command.

import SwiftUI

struct SettingsSearchFocusAction {
    let focus: () -> Void

    func callAsFunction() {
        focus()
    }
}

private struct SettingsSearchFocusActionKey: FocusedValueKey {
    typealias Value = SettingsSearchFocusAction
}

extension FocusedValues {
    var settingsSearchFocusAction: SettingsSearchFocusAction? {
        get { self[SettingsSearchFocusActionKey.self] }
        set { self[SettingsSearchFocusActionKey.self] = newValue }
    }
}
