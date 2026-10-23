// FontPane.swift
// Limpid — Settings → Font: the monospace family, size, and line spacing.
//
// The families are enumerated from `NSFontManager`; size and line spacing
// are numbers (`SettingsNumberRow`).

import AppKit
import SwiftUI

struct FontPane: View {
    @Environment(SettingsStore.self) private var store
    /// The typeface "Default" draws with (`GhosttyUserConfig`).
    @State private var defaultFamily = GhosttyUserConfig.builtInFontFamily

    /// The sizes a terminal draws legibly, in the half points the field
    /// and stepper move by. `font.size` is a `Double`, so a half point in
    /// settings.json is kept.
    static let sizeRange: ClosedRange<Double> = 6...72
    /// Pixels added to or taken from a cell's height (`adjust-cell-height`).
    static let lineSpacingRange: ClosedRange<Double> = -4...10

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Font", section: .font) {
            Section {
                FontFamilyPicker(family: $store.settings.font.family, defaultFamily: defaultFamily)
                    .settingsSearchTarget(SettingsSearchCatalog.fontFamily.id)
                    // Read once, and again when the Ghostty config is
                    // turned on or off, rather than on every redraw.
                    .task(id: store.settings.advanced.ghosttyConfig.isOn) {
                        defaultFamily = GhosttyUserConfig.defaultFontFamily(
                            readsGhosttyConfig: store.settings.advanced.ghosttyConfig.isOn
                        ) {
                            GhosttyUserConfig.existingFiles().compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                        }
                    }
                SettingsNumberRow(
                    title: "Size",
                    value: $store.settings.font.size,
                    range: Self.sizeRange,
                    step: 0.5,
                    unit: "pt",
                    defaultValue: FontSettings().size
                )
                .settingsSearchTarget(SettingsSearchCatalog.fontSize.id)
            } header: {
                // A heading over the first group, as in Appearance. The
                // pane is already titled Font, so the group is named for
                // what its rows pick.
                Text("Typeface")
            } footer: {
                SettingsFootnote("Size applies live. Family applies on new terminals only.")
            }

            Section {
                SettingsToggle("Ligatures", isOn: $store.settings.font.ligatures)
                    .settingsSearchTarget(SettingsSearchCatalog.ligatures.id)
                SettingsNumberRow(
                    title: "Line spacing",
                    value: $store.settings.font.lineHeight,
                    range: Self.lineSpacingRange,
                    unit: "px",
                    zeroMeaning: "Default",
                    defaultValue: FontSettings().lineHeight
                )
                .settingsSearchTarget(SettingsSearchCatalog.lineHeight.id)
            } header: {
                Text("Typography")
            }
        }
    }
}

/// Menu Picker over the system's monospaced fonts. Resolved once
/// per appearance — `NSFontManager` is cheap but we don't want it
/// on every body re-eval.
private struct FontFamilyPicker: View {
    @Binding var family: String?
    /// What "Default" draws with now, named in its item so the choice says
    /// which typeface it is.
    let defaultFamily: String
    @State private var monoFamilies: [String] = []

    var body: some View {
        Picker("Family", selection: $family) {
            Text("Default (\(defaultFamily))").tag(String?.none)
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
