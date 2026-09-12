// TabsAndPanesPane.swift
// Limpid — Settings for pane layout and Quick Tab creation defaults.

import SwiftUI

struct TabsAndPanesPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Tabs & Panes", section: .tabsAndPanes) {
            Section {
                Stepper(
                    value: $store.settings.terminal.minPaneSize,
                    in: 40...300,
                    step: 20
                ) {
                    HStack {
                        Text("Minimum pane size")
                        Spacer()
                        Text("\(Int(store.settings.terminal.minPaneSize)) pt")
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.minimumPaneSize.id)
            } header: {
                Text("Pane Layout")
            } footer: {
                Text("Splits and divider drags can't push any pane below this floor.")
            }

            Section {
                WorkingDirectoryField(
                    label: "Default working directory",
                    mode: $store.settings.terminal.quickTabCwdMode,
                    path: $store.settings.terminal.quickTabCwdPath
                )
                .settingsSearchTarget(SettingsSearchCatalog.defaultWorkingDirectory.id)
            } header: {
                Text("Quick Tabs")
            } footer: {
                Text("Where new Quick Tabs open. Containers can override this in their own settings.")
            }
        }
    }
}
