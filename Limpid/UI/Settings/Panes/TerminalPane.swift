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
                    SettingsDefaultMark.title(Text("1,000 lines"), value: 1000, of: \.terminal.scrollbackLines).tag(1000)
                    SettingsDefaultMark.title(Text("10,000 lines"), value: 10000, of: \.terminal.scrollbackLines).tag(10000)
                    SettingsDefaultMark.title(Text("100,000 lines"), value: 100_000, of: \.terminal.scrollbackLines).tag(100_000)
                    SettingsDefaultMark.title(Text("1,000,000 lines"), value: 1_000_000, of: \.terminal.scrollbackLines).tag(1_000_000)
                    let current = store.settings.terminal.scrollbackLines
                    if ![1000, 10000, 100_000, 1_000_000].contains(current) {
                        Text("\(current, format: .number) lines (custom)").tag(current)
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.scrollback.id)
            } header: {
                Text("History")
            } footer: {
                SettingsFootnote("Applies to new terminals only.")
            }

            Section {
                // Two parts that each turn on or off, so two checkboxes
                // rather than four combinations to read through (`BellAction`).
                let bell = store.settings.terminal.bellAction
                Toggle("Flash the screen", isOn: Binding(
                    get: { bell.flashes },
                    set: { store.settings.terminal.bellAction = BellAction(flashes: $0, sounds: bell.sounds) }
                ))
                .toggleStyle(.checkbox)
                .settingsSearchTarget(SettingsSearchCatalog.bell.id)
                Toggle("Play a sound", isOn: Binding(
                    get: { bell.sounds },
                    set: { store.settings.terminal.bellAction = BellAction(flashes: bell.flashes, sounds: $0) }
                ))
                .toggleStyle(.checkbox)
            } header: {
                Text("Bell")
            }

            Section {
                Picker("Style", selection: $store.settings.terminal.cursorStyle) {
                    SettingsDefaultMark.title(Text("Block"), value: CursorStyle.block, of: \.terminal.cursorStyle).tag(CursorStyle.block)
                    SettingsDefaultMark.title(Text("I-Beam"), value: CursorStyle.bar, of: \.terminal.cursorStyle).tag(CursorStyle.bar)
                    SettingsDefaultMark.title(Text("Underline"), value: CursorStyle.underline, of: \.terminal.cursorStyle)
                        .tag(CursorStyle.underline)
                }
                .settingsSearchTarget(SettingsSearchCatalog.cursorStyle.id)
                SettingsToggle("Blink", isOn: Binding(
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
