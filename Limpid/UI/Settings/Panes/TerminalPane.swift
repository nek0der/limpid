// TerminalPane.swift
// Limpid — Settings → Terminal. Scrollback, bell, cursor.

import SwiftUI

struct TerminalPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Terminal") {
            Section {
                // Same Picker shape as Bell / Cursor so all three
                // ranged settings read uniformly. If the on-disk
                // value doesn't match a preset (e.g. a hand-edit
                // landed at 5,000), an extra "Custom" row mirrors
                // the current value so the Picker isn't shown blank.
                Picker("Scrollback", selection: $store.settings.terminal.scrollbackLines) {
                    Text("1,000 lines").tag(1000)
                    Text("10,000 lines").tag(10000)
                    Text("100,000 lines").tag(100_000)
                    Text("1,000,000 lines").tag(1_000_000)
                    let current = store.settings.terminal.scrollbackLines
                    if ![1000, 10000, 100_000, 1_000_000].contains(current) {
                        Text("\(current.formatted()) lines (custom)").tag(current)
                    }
                }
            } footer: {
                Text("Applies to new terminals only.")
            }

            Section {
                Picker("Bell", selection: $store.settings.terminal.bellAction) {
                    Text("None").tag(BellAction.none)
                    Text("Visual").tag(BellAction.visual)
                    Text("Audio").tag(BellAction.audio)
                    Text("Visual + Audio").tag(BellAction.both)
                }
            }

            Section {
                Picker("Cursor", selection: $store.settings.terminal.cursorStyle) {
                    Text("Block").tag(CursorStyle.block)
                    Text("I-Beam").tag(CursorStyle.bar)
                    Text("Underline").tag(CursorStyle.underline)
                }
                Toggle("Cursor blink", isOn: Binding(
                    get: { store.settings.terminal.cursorBlink == .on },
                    set: { store.settings.terminal.cursorBlink = $0 ? .on : .off }
                ))
            }

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
            } footer: {
                Text("Splits and divider drags can't push any pane below this floor.")
            }

            Section {
                // Reuses the same control the Group settings sheet uses
                // so the Quick Tabs default reads identically wherever
                // a working-directory mode is configurable.
                WorkingDirectoryField(
                    label: "Default working directory",
                    mode: $store.settings.terminal.quickTabCwdMode,
                    path: $store.settings.terminal.quickTabCwdPath
                )
            } header: {
                Text("Quick Tabs")
            } footer: {
                Text("Where new Quick Tabs open. Containers can override this in their own settings.")
            }
        }
    }
}
