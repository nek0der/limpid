// TabsAndPanesPane.swift
// Weir — Settings for pane layout and the scratch tabs' creation defaults.

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
                        RestoreDefaultSlot(
                            title: "Minimum pane size",
                            isShown: RestoreDefaultSlot.isShown(
                                value: store.settings.terminal.minPaneSize,
                                defaultValue: TerminalSettings.defaultMinPaneSize
                            )
                        ) {
                            store.settings.terminal.minPaneSize = TerminalSettings.defaultMinPaneSize
                        }
                        Text("\(Int(store.settings.terminal.minPaneSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(SettingsFootnote.style.color)
                            .frame(width: WeirLayout.settingsSliderValueWidth, alignment: .trailing)
                        Stepper(
                            "Minimum pane size",
                            value: $store.settings.terminal.minPaneSize,
                            in: TerminalSettings.minPaneSizeRange,
                            step: TerminalSettings.minPaneSizeStep
                        )
                        .labelsHidden()
                        .accessibilityLabel(Text("Minimum pane size"))
                        // "pt" in words: VoiceOver spells the unit out, and
                        // would leave it English in Japanese.
                        .accessibilityValue(Text(
                            "\(Int(store.settings.terminal.minPaneSize)) points",
                            comment: "Settings, Tabs & Panes, VoiceOver: the minimum pane size in points"
                        ))
                    }
                    // A container, so the ↺ is read after the stepper
                    // (`RestoreDefaultSlot`).
                    .accessibilityElement(children: .contain)
                }
                .settingsStepperRow()
                .settingsSearchTarget(SettingsSearchCatalog.minimumPaneSize.id)
            } header: {
                Text("Pane Layout")
            } footer: {
                SettingsFootnote("Splits and divider drags can’t make a pane smaller than this.")
            }

            Section {
                WorkingDirectoryField(
                    label: "Working folder",
                    mode: $store.settings.terminal.quickTabCwdMode,
                    path: $store.settings.terminal.quickTabCwdPath
                )
                .settingsSearchTarget(SettingsSearchCatalog.defaultWorkingDirectory.id)
            } header: {
                Text("Scratch")
            } footer: {
                SettingsFootnote("Where new Scratch tabs open.")
            }
        }
    }
}
