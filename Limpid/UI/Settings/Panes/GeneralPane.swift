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

            ConfirmationsSection()

            if let updater {
                UpdatesSection(updater: updater)
            }

            AboutSection()
        }
    }
}

/// Four pickers. The keyboard / mouse split for tab close is
/// intentional — the × button is the most mis-clicked affordance in
/// the app, so users tend to want it stricter than the deliberate
/// ⌘W / ⌘⌥W keystroke. ⌘Q is app-wide. Pane close has no mouse
/// path, so it sits as a single knob.
private struct ConfirmationsSection: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            policyPicker("Quit Limpid", binding: $settings.settings.confirmations.quit)
            policyPicker(
                "Close Tab (Keyboard)",
                binding: $settings.settings.confirmations.closeTabKeyboard
            )
            policyPicker(
                "Close Tab (X Button)",
                binding: $settings.settings.confirmations.closeTabMouse
            )
            policyPicker("Close Pane", binding: $settings.settings.confirmations.closePane)
        } header: {
            Text("Confirmations")
        } footer: {
            Text("\"Only when an agent is active\" prompts only when a tracked agent is live in the affected pane.")
        }
    }

    private func policyPicker(
        _ title: LocalizedStringKey,
        binding: Binding<ConfirmPolicy>
    ) -> some View {
        Picker(title, selection: binding) {
            ForEach(ConfirmPolicy.allCases, id: \.self) { policy in
                Text(policy.localizedTitle).tag(policy)
            }
        }
    }
}

extension ConfirmPolicy {
    var localizedTitle: String {
        switch self {
        case .never: String(localized: "Never")
        case .onlyWhenAgent: String(localized: "Only when an agent is active")
        case .always: String(localized: "Always")
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
    @Environment(UpdateStateModel.self) private var stateModel

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
                    #if DEBUG
                        // Mirror the App-menu "Check for Updates…"
                        // mock routing so design iteration still
                        // reaches both entry points without a real
                        // Sparkle round-trip.
                        MockUpdateAvailability.simulate(into: stateModel)
                    #else
                        updater.checkForUpdates()
                    #endif
                }
                .disabled(stateModel.isBusy)
            }
            // Inline the same state-driven popover content underneath
            // the button so a user who initiated the check from
            // Settings sees the result here, not just on the terminal column toolbar
            // of the main window. The view is hidden while `.idle` so
            // the section collapses back to its resting size when no
            // check is in flight.
            if case .idle = stateModel.state {
                EmptyView()
            } else {
                UpdatePopover(updater: updater, dismiss: {
                    stateModel.state = .idle
                }, width: nil)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.background.tertiary)
                    )
            }
        } header: {
            Text("Software Update")
        }
    }
}
