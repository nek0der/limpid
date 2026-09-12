// TerminalPane.swift
// Limpid — Settings for terminal history, bell, and cursor behavior.

import SwiftUI

struct TerminalPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Terminal", section: .terminal) {
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
                .settingsSearchTarget(SettingsSearchCatalog.scrollback.id)
            } header: {
                Text("History")
            } footer: {
                Text("Applies to new terminals only.")
            }

            Section {
                Picker("Alert Style", selection: $store.settings.terminal.bellAction) {
                    Text("None").tag(BellAction.none)
                    Text("Visual").tag(BellAction.visual)
                    Text("Audio").tag(BellAction.audio)
                    Text("Visual + Audio").tag(BellAction.both)
                }
                .settingsSearchTarget(SettingsSearchCatalog.bell.id)
            } header: {
                Text("Bell")
            }

            Section {
                Picker("Style", selection: $store.settings.terminal.cursorStyle) {
                    Text("Block").tag(CursorStyle.block)
                    Text("I-Beam").tag(CursorStyle.bar)
                    Text("Underline").tag(CursorStyle.underline)
                }
                .settingsSearchTarget(SettingsSearchCatalog.cursorStyle.id)
                Toggle("Blink", isOn: Binding(
                    get: { store.settings.terminal.cursorBlink == .on },
                    set: { store.settings.terminal.cursorBlink = $0 ? .on : .off }
                ))
                .settingsSearchTarget(SettingsSearchCatalog.cursorBlink.id)
            } header: {
                Text("Cursor")
            }
        }
    }
}
