// LibghosttyInitFailureView.swift
// Limpid — fallback UI rendered when `GhosttyApp.init` throws and
// `AppState.ghosttyApp` ends up nil. The previous shape was a static
// `Text` with no way out: ⌘, didn't render (toolbar lives inside the
// failed layout), no Quit button, no log-revealing affordance. Most
// init failures come from a malformed user-side ghostty config
// (Layer 2 in `GhosttyConfigBridge`), so we give the user three ways
// to escape: open Settings, reveal Console.app filtered by Limpid's
// subsystem, and reset `settings.json` to defaults.

import AppKit
import OSLog
import SwiftUI

private let log = Logger.limpid("init.failure.view")

struct LibghosttyInitFailureView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("libghostty failed to initialize")
                .font(LimpidFont.title)
            Text("libghostty \(GhosttyFFI.version())")
                .font(LimpidFont.bodySecondary.monospaced())
                .foregroundStyle(LimpidColor.secondaryText)
            Text(
                "Most failures are caused by a malformed user-side ghostty config. " +
                    "Open Settings to disable advanced overrides, or reset settings.json to defaults."
            )
            .font(LimpidFont.body)
            .foregroundStyle(LimpidColor.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Open Settings") {
                    openWindow(id: LimpidApp.settingsWindowID)
                }
                Button("Reveal Logs in Console") {
                    revealConsole()
                }
                Button("Reset Settings to Defaults") {
                    resetSettings()
                }
                Button("Quit Limpid") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Launch Console.app so the user can filter on the `dev.limpid`
    /// subsystem and copy the init-failure trail.
    private func revealConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }

    /// Rename the current `settings.json` aside and let the next
    /// SettingsStore read seed defaults. The user has to relaunch
    /// Limpid for the change to take — the in-process `GhosttyApp`
    /// is already half-initialized and we cannot re-run
    /// `ghostty_app_new` on a dead handle.
    private func resetSettings() {
        let url = SettingsStore.defaultSettingsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let bak = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-init-failure-\(ts)")
        do {
            try FileManager.default.moveItem(at: url, to: bak)
            log.notice("renamed settings.json to \(bak.lastPathComponent, privacy: .public)")
        } catch {
            log.error("settings.json reset failed: \(String(describing: error), privacy: .public)")
        }
    }
}
