// AppearancePane.swift
// Limpid — Settings → Appearance. macOS 26 Tahoe System Settings shape:
// short Title-Case section headers, footers used sparingly (one
// sentence when there's something non-obvious to convey), trailing
// mono-digit slider values via `SliderRow`.
//
// The Accent row mirrors System Settings → Appearance: solid swatches
// aligned with a centered leading label, with the leading dot painting
// a Multicolor (rainbow) gradient to mean "follow the OS accent". See
// `AccentColorPicker`.

import SwiftUI

struct AppearancePane: View {
    @Environment(SettingsStore.self) private var store
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Appearance", section: .appearance) {
            Section {
                Picker(
                    "Theme",
                    selection: $store.settings.appearance.colorScheme
                ) {
                    Text("Follow System").tag(ColorSchemePreference.system)
                    Text("Light").tag(ColorSchemePreference.light)
                    Text("Dark").tag(ColorSchemePreference.dark)
                }
                .settingsSearchTarget(SettingsSearchCatalog.theme.id)
            }

            Section {
                HStack(alignment: .center) {
                    Text("Accent")
                    Spacer(minLength: 12)
                    AccentColorPicker(
                        current: store.settings.appearance.accentColor,
                        onSelect: { choice in
                            store.settings.appearance.accentColor = choice
                        }
                    )
                }
                .settingsSearchTarget(SettingsSearchCatalog.accentColor.id)
            } footer: {
                Text("Painted on focus rings, drop targets, and other highlights.")
            }

            Section {
                Toggle(
                    "Transparency",
                    isOn: Binding(
                        get: { store.settings.appearance.transparency == .on },
                        set: { store.settings.appearance.transparency = $0 ? .on : .off }
                    )
                )
                .disabled(reduceTransparencyResolver.systemReducesTransparency)
                .settingsSearchTarget(SettingsSearchCatalog.transparency.id)
                SliderRow(
                    title: "Opacity",
                    value: $store.settings.appearance.backgroundOpacity,
                    range: 0.5...1.0
                )
                .settingsSearchTarget(SettingsSearchCatalog.backgroundOpacity.id)
            } footer: {
                // Only when the OS forces opacity: explain why the toggle
                // is disabled. The enabled state is self-explanatory, so
                // we keep the footer to the one non-obvious case.
                if reduceTransparencyResolver.systemReducesTransparency {
                    Text("Disabled when System Settings' Accessibility Reduce Transparency is on.")
                }
            }

            Section {
                SliderRow(
                    title: "Unfocused pane opacity",
                    value: $store.settings.appearance.unfocusedPaneOpacity,
                    range: 0.15...1.0
                )
                .settingsSearchTarget(SettingsSearchCatalog.unfocusedPaneOpacity.id)
            } footer: {
                Text("Dims the unfocused leaves when a tab carries more than one pane.")
            }
        }
    }
}
