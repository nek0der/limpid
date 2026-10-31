// LibghosttyInitFailureView.swift
// Weir — fallback UI rendered when `GhosttyApp.init` throws and
// `AppState.ghosttyApp` ends up nil. The previous shape was a static
// `Text` with no way out: ⌘, didn't render (toolbar lives inside the
// failed layout), no Quit button, no log-revealing affordance. Most
// init failures come from a malformed user-side ghostty config
// (Layer 2 in `GhosttyConfigBridge`), so we give the user three ways
// to escape: open Settings, reveal Console.app filtered by Weir's
// subsystem, and reset `settings.json` to defaults.

import AppKit
import SwiftUI

struct LibghosttyInitFailureView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("Couldn’t Initialize libghostty")
                .font(WeirFont.title)
            Text("libghostty \(GhosttyFFI.version())")
                .font(WeirFont.bodySecondary.monospaced())
                .foregroundStyle(WeirColor.secondaryText)
            // One literal: a `+` made it a runtime String, which Text shows
            // unlocalized.
            Text(
                """
                Most failures come from a malformed ~/.config/ghostty/config. Open Settings and turn off \
                Use Ghostty config file in Integrations, or choose Restore Default Settings.
                """
            )
            .font(WeirFont.body)
            .foregroundStyle(WeirColor.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Open Settings") {
                    openWindow(id: WeirApp.settingsWindowID)
                }
                Button("Show Logs in Console") {
                    revealConsole()
                }
                Button("Restore Default Settings") {
                    SettingsStore.moveSettingsFileAside()
                }
                Button("Quit Weir") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Launch Console.app so the user can filter on the `com.nekoder.weir`
    /// subsystem and copy the init-failure trail.
    private func revealConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }
}
