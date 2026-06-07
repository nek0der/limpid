// AdvancedPane.swift
// Limpid — Settings → Advanced. Layer the user's
// `~/.config/ghostty/config` beneath Limpid Settings, plus the
// destructive "Restore All Defaults" escape hatch. The 4-layer
// config model + forced-overrides story lives in `LimpidSettings.swift`;
// the footer below just summarises it.

import AppKit
import SwiftUI

struct AdvancedPane: View {
    @Environment(SettingsStore.self) private var store
    @State private var confirmReset: Bool = false

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Advanced") {
            Section {
                HStack {
                    Button("Reveal settings.json in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.settingsFileURL])
                    }
                    Button("Open in Default Editor") {
                        NSWorkspace.shared.open(store.settingsFileURL)
                    }
                }
            } header: {
                Text("settings.json")
            } footer: {
                Text(
                    """
                    Edit `settings.json` directly. Limpid watches the file and reloads on save. \
                    A typo is recoverable — the malformed copy is renamed to settings.json.bak-decode-failed-<ts> \
                    on the next launch and defaults are loaded.
                    """
                )
            }

            Section {
                Toggle(
                    "Use Ghostty config file",
                    isOn: Binding(
                        get: { store.settings.advanced.ghosttyConfig == .on },
                        set: { store.settings.advanced.ghosttyConfig = $0 ? .on : .off }
                    )
                )
            } header: {
                Text("Ghostty Config")
            } footer: {
                Text(
                    """
                    Layers ~/.config/ghostty/config beneath the values above. \
                    Limpid always overrides window background, opacity, and decoration. Restart required.
                    """
                )
            }

            // Lives at the bottom of the last pane on purpose — this
            // is the kind of switch a user only reaches for when
            // something is wrong, and putting it next to the daily
            // controls would invite mis-clicks.
            Section {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Text("Restore All Defaults")
                }
            } footer: {
                Text(
                    """
                    Resets every Limpid preference to its factory default. \
                    The app language and your settings.json on disk are both rewritten.
                    """
                )
            }
        }
        .alert("Restore all settings to defaults?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) {
                store.settings = .default
                store.appLanguage = .system
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}
