// TabsAndPanesPane.swift
// Limpid — Settings for pane layout and Quick Tab creation defaults.

import SwiftUI

struct TabsAndPanesPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Tabs & Panes", section: .tabsAndPanes) {
            Section {
                HStack(spacing: 12) {
                    Text("Minimum pane size")

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        Text("\(Int(store.settings.terminal.minPaneSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                        Stepper(
                            "Minimum pane size",
                            value: $store.settings.terminal.minPaneSize,
                            in: TerminalSettings.minPaneSizeRange,
                            step: TerminalSettings.minPaneSizeStep
                        )
                        .labelsHidden()
                        .accessibilityLabel(Text("Minimum pane size"))
                        .accessibilityValue(Text("\(Int(store.settings.terminal.minPaneSize)) pt"))
                    }
                }
                .settingsControlRow()
                .settingsSearchTarget(SettingsSearchCatalog.minimumPaneSize.id)
            } header: {
                Text("Pane Layout")
            } footer: {
                Text("Splits and divider drags can't push any pane below this floor.")
            }

            Section {
                SettingsToggle(
                    "Show headers on split panes",
                    isOn: $store.settings.terminal.showsSplitPaneHeaders
                )
                .settingsSearchTarget(SettingsSearchCatalog.splitPaneHeaders.id)
            } header: {
                Text("Pane Headers")
            } footer: {
                Text("Names each pane of a split tab and shows what it is running. Double-click a pane's name to rename it.")
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
