// FontPane.swift
// Limpid — Settings → Font. Monospace families enumerated from
// `NSFontManager`; size + line height via shared `SliderRowInt`.

import AppKit
import SwiftUI

struct FontPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Font") {
            Section {
                FontFamilyPicker(family: $store.settings.font.family)
                SliderRowInt(
                    title: "Size",
                    value: Binding(
                        get: { Int(store.settings.font.size) },
                        set: { store.settings.font.size = Double($0) }
                    ),
                    range: 8...24,
                    suffix: "pt"
                )
            } footer: {
                Text("Size applies live. Family applies on new terminals only.")
            }

            Section {
                Toggle("Ligatures", isOn: $store.settings.font.ligatures)
                SliderRowInt(
                    title: "Line height",
                    value: Binding(
                        get: { Int(store.settings.font.lineHeight) },
                        set: { store.settings.font.lineHeight = Double($0) }
                    ),
                    range: -2...6,
                    suffix: "px"
                )
            }
        }
    }
}

/// Menu Picker over the system's monospaced fonts. Resolved once
/// per appearance — `NSFontManager` is cheap but we don't want it
/// on every body re-eval.
private struct FontFamilyPicker: View {
    @Binding var family: String?
    @State private var monoFamilies: [String] = []

    var body: some View {
        Picker("Family", selection: $family) {
            Text("Default").tag(String?.none)
            if !monoFamilies.isEmpty {
                Divider()
                ForEach(monoFamilies, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
        }
        .task { loadFamilies() }
    }

    private func loadFamilies() {
        guard monoFamilies.isEmpty else { return }
        let fm = NSFontManager.shared
        let mono = fm.availableFontFamilies.filter { family in
            let members = fm.availableMembers(ofFontFamily: family) ?? []
            return members.contains { member in
                guard member.count >= 4,
                      let traits = member[3] as? NSNumber else { return false }
                return NSFontTraitMask(rawValue: traits.uintValue)
                    .contains(.fixedPitchFontMask)
            }
        }
        monoFamilies = mono.sorted()
    }
}
