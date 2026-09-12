// SettingsSearchTarget.swift
// Limpid — Search-result routing and transient target emphasis for Settings.

import SwiftUI

struct SettingsRevealRequest: Equatable {
    let sequence: UInt
    let entryID: String
    let section: SettingsSection
}

extension EnvironmentValues {
    @Entry var settingsRevealRequest: SettingsRevealRequest?

    @Entry var settingsHighlightedEntryID: String?
}

private struct SettingsSearchTargetModifier: ViewModifier {
    let id: String
    @Environment(\.settingsHighlightedEntryID) private var highlightedEntryID
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    @Environment(\.limpidAccent) private var accent

    private var isHighlighted: Bool {
        highlightedEntryID == id
    }

    func body(content: Content) -> some View {
        content
            .id(id)
            .listRowBackground(isHighlighted ? accent.opacity(0.10) : Color.clear)
            .animation(shouldReduceMotion ? nil : .easeOut(duration: 0.18), value: isHighlighted)
    }
}

extension View {
    func settingsSearchTarget(_ id: String) -> some View {
        modifier(SettingsSearchTargetModifier(id: id))
    }
}
