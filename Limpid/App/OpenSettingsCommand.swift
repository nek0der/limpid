// OpenSettingsCommand.swift
// Limpid — menu command that routes ⌘, to the Settings Window scene.

import SwiftUI

/// Wraps the "Settings…" menu button so we can capture
/// `\.openWindow` (only available inside a `View`, not `App`'s
/// body) and route ⌘, to our `Window(id:)` Settings scene.
struct OpenSettingsCommand: View {
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
