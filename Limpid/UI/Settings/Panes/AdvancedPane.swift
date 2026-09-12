// AdvancedPane.swift
// Limpid — Direct settings-file access and the global reset escape hatch.

import AppKit
import SwiftUI

struct AdvancedPane: View {
    @Environment(SettingsStore.self) private var store
    @State private var isResetConfirmationPresented = false

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Advanced", section: .advanced) {
            Section {
                HStack {
                    Button("Reveal settings.json in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.settingsFileURL])
                    }
                    .accessibilityLabel(Text("Reveal settings.json in Finder"))
                    Button("Open in Default Editor") {
                        NSWorkspace.shared.open(store.settingsFileURL)
                    }
                    .accessibilityLabel(Text("Open settings.json in Default Editor"))
                }
                .settingsSearchTarget(SettingsSearchCatalog.settingsFile.id)
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
                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    Text("Restore All Defaults")
                }
                .accessibilityLabel(Text("Restore All Settings to Defaults"))
                .settingsSearchTarget(SettingsSearchCatalog.restoreAllDefaults.id)
            } header: {
                Text("Reset")
            } footer: {
                Text(
                    """
                    Resets every Limpid preference to its factory default. \
                    The app language and your settings.json on disk are both rewritten.
                    """
                )
            }
        }
        .alert("Restore all settings to defaults?", isPresented: $isResetConfirmationPresented) {
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
