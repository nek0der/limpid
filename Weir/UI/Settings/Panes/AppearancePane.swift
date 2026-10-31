// AppearancePane.swift
// Weir — Settings → Appearance. macOS 26 Tahoe System Settings shape:
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
                    SettingsDefaultMark.title(Text("Follow System"), value: ColorSchemePreference.system, of: \.appearance.colorScheme)
                        .tag(ColorSchemePreference.system)
                    SettingsDefaultMark.title(Text("Light"), value: ColorSchemePreference.light, of: \.appearance.colorScheme)
                        .tag(ColorSchemePreference.light)
                    SettingsDefaultMark.title(Text("Dark"), value: ColorSchemePreference.dark, of: \.appearance.colorScheme)
                        .tag(ColorSchemePreference.dark)
                }
                .settingsSearchTarget(SettingsSearchCatalog.theme.id)
                HStack(spacing: 12) {
                    Text("Accent")
                    Spacer(minLength: 12)
                    AccentColorPicker(
                        current: store.settings.appearance.accentColor,
                        onSelect: { choice in
                            store.settings.appearance.accentColor = choice
                        }
                    )
                }
                // The swatches are 30pt. Treated as a 24pt control, the row
                // comes out 44pt, a little taller than its neighbors, as
                // System Settings' accent row is.
                .settingsControlRow()
                .settingsSearchTarget(SettingsSearchCatalog.accentColor.id)
            } header: {
                // A heading over the first group, as the other panes have,
                // puts the first card at the same height under the title.
                // It names the group rather than repeating a row's label.
                Text("Color")
            } footer: {
                SettingsFootnote("Used for focus rings, drop targets, and other highlights.")
            }

            Section {
                SettingsToggle(
                    "Translucent window",
                    isOn: Binding(
                        get: { store.settings.appearance.transparency == .on },
                        set: { store.settings.appearance.transparency = $0 ? .on : .off }
                    )
                )
                .disabled(reduceTransparencyResolver.systemReducesTransparency)
                .settingsSearchTarget(SettingsSearchCatalog.transparency.id)
                // The opacity only acts while the window is translucent, so
                // it sits under the switch as its child and is disabled
                // while the switch is off or the OS forces opacity.
                SliderRow(
                    title: "Background opacity",
                    value: $store.settings.appearance.backgroundOpacity,
                    range: 0.5...1.0,
                    defaultValue: AppearanceSettings().backgroundOpacity
                )
                .padding(.leading, WeirLayout.settingsChildRowIndent)
                .disabled(
                    store.settings.appearance.transparency != .on
                        || reduceTransparencyResolver.systemReducesTransparency
                )
                .settingsSearchTarget(SettingsSearchCatalog.backgroundOpacity.id)
            } footer: {
                // Only when the OS forces opacity: explain why the toggle
                // is disabled. The enabled state is self-explanatory, so
                // we keep the footer to the one non-obvious case.
                if reduceTransparencyResolver.systemReducesTransparency {
                    SettingsFootnote("Disabled when Reduce Transparency is on in System Settings → Accessibility → Display.")
                }
            }

            Section {
                SliderRow(
                    title: "Unfocused pane opacity",
                    value: $store.settings.appearance.unfocusedPaneOpacity,
                    range: 0.15...1.0,
                    defaultValue: AppearanceSettings().unfocusedPaneOpacity
                )
                .settingsSearchTarget(SettingsSearchCatalog.unfocusedPaneOpacity.id)
            } footer: {
                SettingsFootnote("Dims the panes without focus when a tab has more than one pane.")
            }
        }
    }
}
