// GeneralPane.swift
// Limpid — first Settings pane. Hosts the language picker + Sparkle
// auto-update controls.
//
// Form layout follows the macOS 26 System Settings convention:
// `Form` + `.formStyle(.grouped)` puts each `Section` in a rounded
// card; in-row controls (Picker, Toggle) provide their own label via
// the first argument; secondary copy lives in the Section footer.

import Sparkle
import SwiftUI

struct GeneralPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.sparkleUpdater) private var updater

    var body: some View {
        @Bindable var settings = settings
        SettingsForm(title: "General") {
            Section {
                Picker("Display Language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.localizedTitle).tag(lang)
                    }
                }
            } footer: {
                Text("App content updates immediately. The macOS menu bar updates on next launch.")
            }

            if let updater {
                UpdatesSection(updater: updater)
            }

            AboutSection()
        }
    }
}

/// Footer card that mirrors what the standard About panel shows. Lets
/// users grab the version for bug reports without leaving Settings.
private struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Limpid") {
                Text(Self.versionString)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .monospacedDigit()
            }
        }
    }

    private static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? short : "\(short) (\(build))"
    }()
}

/// Sparkle auto-update controls. Lives in its own struct because the
/// auto-check toggle binds through Sparkle's own KVO-backed setter
/// (not the `LimpidSettings` JSON path), and the "Check Now" button
/// needs a `@State`-tracked `canCheckForUpdates` flag from a small
/// `@Observable` adapter.
private struct UpdatesSection: View {
    let updater: SPUUpdater
    @State private var autoCheck: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        self._autoCheck = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Section {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { autoCheck },
                set: { newValue in
                    autoCheck = newValue
                    updater.automaticallyChecksForUpdates = newValue
                }
            ))
            HStack {
                Text("Updates")
                Spacer()
                // We intentionally don't gate this on Sparkle's
                // `canCheckForUpdates`. After a failed appcast fetch
                // (404, no network at launch, etc.) the flag has
                // been observed to stay `false` and the button
                // becomes permanently un-clickable — Sparkle itself
                // is the bug we're routing around. Sparkle ignores
                // re-entrant `checkForUpdates()` calls internally,
                // so an always-enabled button is safe.
                Button("Check Now…") {
                    updater.checkForUpdates()
                }
            }
        } header: {
            Text("Software Update")
        }
    }
}
