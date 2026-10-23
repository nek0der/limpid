// GeneralPane.swift
// Limpid — first Settings pane. Hosts the language picker + Sparkle
// auto-update controls.
//
// Form layout follows the macOS 26 System Settings convention:
// `Form` + `.formStyle(.grouped)` puts each `Section` in a rounded
// card; in-row controls (Picker, Toggle) provide their own label via
// the first argument; secondary copy lives in the Section footer.

import AppKit
import Sparkle
import SwiftUI

struct GeneralPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.sparkleUpdater) private var updater

    var body: some View {
        @Bindable var settings = settings
        SettingsForm(title: "General", section: .general) {
            SavingSuspendedSection()

            Section {
                Picker("Display Language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.localizedTitle).tag(lang)
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.displayLanguage.id)
                // The menu bar only takes a new language at launch, so the
                // change offers the relaunch it waits for.
                if settings.needsRelaunchForLanguage {
                    RelaunchRow(reason: "The menu bar changes language when Limpid relaunches.")
                }
            } header: {
                Text("Language")
            } footer: {
                SettingsFootnote("App content updates immediately. The macOS menu bar updates on next launch.")
            }

            Section {
                SettingsToggle("Show in menu bar", isOn: $settings.settings.general.showMenuBarExtra)
                    .settingsSearchTarget(SettingsSearchCatalog.menuBarExtra.id)
            } header: {
                Text("Menu Bar")
            } footer: {
                SettingsFootnote(
                    """
                    Lists what needs your attention. Short commands can be allowed or denied there; \
                    anything else opens in Limpid.
                    """
                )
            }

            Section {
                SettingsToggle(
                    "Notify when a usage limit resets",
                    isOn: $settings.settings.general.notifyOnUsageLimitReset
                )
                .settingsSearchTarget(SettingsSearchCatalog.usageLimitReset.id)
            } header: {
                Text("Usage Limits")
            } footer: {
                SettingsFootnote("When an agent stops at its plan’s usage limit, a notification arrives at the time the limit resets.")
            }

            ConfirmationsSection()

            FileApplicationSection()

            if let updater {
                UpdatesSection(updater: updater)
            }

            AboutSection()
        }
    }
}

/// Tells, above everything else in the pane, that this launch has stopped
/// saving the sessions or the settings (`SavingSuspendedNotice`), with a
/// way to the files the person has to move. Absent while both are saved.
private struct SavingSuspendedSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.suspendedSessionFile) private var suspendedSessionFile
    @Environment(\.locale) private var locale

    var body: some View {
        if let notice = SavingSuspendedNotice.make(
            suspendedSessionFile: suspendedSessionFile,
            settings: settings.savingSuspension,
            settingsFile: settings.settingsFileURL,
            locale: locale
        ) {
            Section {
                ForEach(notice.sentences, id: \.self) { sentence in
                    Label {
                        Text(verbatim: sentence)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // The sentence carries the meaning; the symbol only
                        // draws the eye to it.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SupervisionTokens.waiting.color)
                            .accessibilityHidden(true)
                    }
                }
                SettingsButtonRow {
                    Button(SavingSuspendedText.showFiles(locale: locale)) {
                        Self.reveal(notice.files)
                    }
                }
            }
        }
    }

    /// Selects the files in Finder, or opens their folder when none of
    /// them is there any more (moved out by hand, as the notice asks).
    private static func reveal(_ files: [URL]) {
        let present = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        let folders = files.prefix(1).map { $0.deletingLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting(present.isEmpty ? folders : present)
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
            policyPicker(
                "Quit Limpid",
                id: SettingsSearchCatalog.confirmationQuit.id,
                binding: $settings.settings.confirmations.quit,
                setting: \.confirmations.quit
            )
            policyPicker(
                "Close Tab (Keyboard)",
                id: SettingsSearchCatalog.confirmationCloseTabKeyboard.id,
                binding: $settings.settings.confirmations.closeTabKeyboard,
                setting: \.confirmations.closeTabKeyboard
            )
            policyPicker(
                "Close Tab (× Button)",
                id: SettingsSearchCatalog.confirmationCloseTabMouse.id,
                binding: $settings.settings.confirmations.closeTabMouse,
                setting: \.confirmations.closeTabMouse
            )
            policyPicker(
                "Close Pane",
                id: SettingsSearchCatalog.confirmationClosePane.id,
                binding: $settings.settings.confirmations.closePane,
                setting: \.confirmations.closePane
            )
        } header: {
            Text("Action Confirmations")
        } footer: {
            SettingsFootnote("“Only while an agent is running” asks only when an agent Limpid tracks is running in that pane.")
        }
    }

    private func policyPicker(
        _ title: LocalizedStringKey,
        id: String,
        binding: Binding<ConfirmPolicy>,
        setting: KeyPath<LimpidSettings, ConfirmPolicy>
    ) -> some View {
        Picker(title, selection: binding) {
            ForEach(ConfirmPolicy.allCases, id: \.self) { policy in
                SettingsDefaultMark.title(Text(policy.localizedTitle), value: policy, of: setting).tag(policy)
            }
        }
        .settingsSearchTarget(id)
    }
}

/// Footer card that mirrors what the standard About panel shows. Lets
/// users grab the version for bug reports without leaving Settings.
private struct AboutSection: View {
    var body: some View {
        Section {
            HStack(spacing: 12) {
                Text("Limpid")
                Spacer(minLength: 12)
                Text(Self.versionString)
                    .foregroundStyle(SettingsFootnote.style.color)
                    .textSelection(.enabled)
                    .monospacedDigit()
            }
            .settingsControlRow(controlHeight: LimpidLayout.settingsTextRowControlHeight)
            .settingsSearchTarget(SettingsSearchCatalog.appVersion.id)
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
            SettingsToggle("Automatically check for updates", isOn: Binding(
                get: { autoCheck },
                set: { newValue in
                    autoCheck = newValue
                    updater.automaticallyChecksForUpdates = newValue
                }
            ))
            .settingsSearchTarget(SettingsSearchCatalog.automaticUpdates.id)
            HStack(spacing: 12) {
                Text("Updates")
                Spacer(minLength: 12)
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
            .settingsControlRow()
            .settingsSearchTarget(SettingsSearchCatalog.checkForUpdates.id)
            // Inline the same state-driven popover content underneath
            // the button so a user who initiated the check from
            // Settings sees the result here, not just on the update control
            // of the main window. The view is hidden while `.idle` so
            // the section collapses back to its resting size when no
            // check is in flight.
            if case .idle = stateModel.state {
                EmptyView()
            } else {
                UpdatePopover(updater: updater, dismiss: {
                    stateModel.state = .idle
                }, width: nil)
                    .environment(\.updatePopoverMetrics, .settingsRow)
            }
        } header: {
            Text("Software Update")
        }
    }
}
