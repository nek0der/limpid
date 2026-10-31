// HelpCommands.swift
// Weir — the Help menu. We replace SwiftUI's default group because
// its "Weir Help" item would open a help book we do not ship; the
// shortcut cheat sheet is the one entry that exists today.

import SwiftUI

struct HelpCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .help) {
            // The sheet attaches to the main window, so the item steps
            // aside while the quick terminal has the keyboard.
            MainWindowCommandItems(state.quickTerminal) {
                // Help is for whoever asks, Settings in front included: the
                // sheet opens in the key main window, else the one the
                // person was last in.
                Button {
                    let window = state.windowRegistry.commandTarget ?? state.windowRegistry.backgroundCommandTarget
                    window.commands.send(.toggleKeyboardShortcuts)
                } label: {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                }
                .weirShortcut(.keyboardShortcuts, in: state.settingsStore)
            }
        }
    }
}
