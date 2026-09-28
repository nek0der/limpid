// HelpCommands.swift
// Limpid — the Help menu. We replace SwiftUI's default group because
// its "Limpid Help" item would open a help book we do not ship; the
// shortcut cheat sheet is the one entry that exists today.

import SwiftUI

struct HelpCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .help) {
            // The sheet attaches to the main window, so the item steps
            // aside while the quick terminal has the keyboard.
            MainWindowCommandItems(state.quickTerminal) {
                Button {
                    NotificationCenter.default.post(
                        name: .limpidToggleKeyboardShortcuts,
                        object: state.session
                    )
                } label: {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                }
                .limpidShortcut(.keyboardShortcuts, in: state.settingsStore)
            }
        }
    }
}
