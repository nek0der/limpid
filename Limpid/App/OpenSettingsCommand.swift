// OpenSettingsCommand.swift
// Limpid — menu command that routes ⌘, to the Settings Window scene.

import SwiftUI

/// Wraps the "Settings…" menu button so we can capture
/// `\.openWindow` (only available inside a `View`, not `App`'s
/// body) and route ⌘, to our `Window(id:)` Settings scene.
struct OpenSettingsCommand: View {
    /// The key, as the menu draws it: fixed, since macOS keeps ⌘, for
    /// Settings in every app, so it is not among the keys a person rebinds.
    /// The rail's Settings icon names it in its tooltip.
    static let shortcutDisplay = "⌘,"

    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button {
            openWindow(id: LimpidApp.settingsWindowID)
        } label: {
            Label("Settings…", systemImage: "gear")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
