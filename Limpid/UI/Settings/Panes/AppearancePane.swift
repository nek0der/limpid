// AppearancePane.swift
// Limpid — Settings → Appearance. macOS 26 Tahoe System Settings
// shape: short Title-Case section headers, footers used sparingly
// (one sentence when there's something non-obvious to convey),
// trailing mono-digit values on Sliders via `SliderRow`.

import SwiftUI

struct AppearancePane: View {
    @Environment(SettingsStore.self) private var store
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Appearance") {
            Section {
                Picker(
                    "Appearance",
                    selection: $store.settings.appearance.colorScheme
                ) {
                    Text("Follow System").tag(ColorSchemePreference.system)
                    Text("Light").tag(ColorSchemePreference.light)
                    Text("Dark").tag(ColorSchemePreference.dark)
                }
            }

            Section {
                Picker(
                    "Window tint",
                    selection: $store.settings.appearance.windowTint
                ) {
                    ForEach(WindowTint.allCases, id: \.self) { tint in
                        Text(tint.displayName).tag(tint)
                    }
                }
            }

            Section {
                SliderRow(
                    title: "Opacity",
                    value: $store.settings.appearance.backgroundOpacity,
                    range: 0.5...1.0
                )
            }

            Section {
                Toggle(
                    "Transparency",
                    isOn: $store.settings.appearance.transparencyEnabled
                )
                .disabled(reduceTransparencyResolver.systemReducesTransparency)
            } footer: {
                // Only when the OS forces opacity: explain why the toggle
                // is disabled. The enabled state is self-explanatory, so
                // we keep the footer to the one non-obvious case.
                if reduceTransparencyResolver.systemReducesTransparency {
                    Text("Disabled when System Settings' Accessibility Reduce Transparency is on.")
                }
            }
        }
    }
}
