// CheckForUpdatesMenuItem.swift
// Limpid — the app menu's Check for Updates item.

import SwiftUI

/// SwiftUI menu item suitable for placement in
/// `CommandGroup(after: .appInfo)`. Both Debug (mock pipeline) and
/// Release (real `checkForUpdates()`) flow through here; the button
/// disables itself whenever `UpdateStateModel.isBusy` is true so
/// concurrent pipelines can't be launched from the menu.
///
/// We don't gate on Sparkle's `canCheckForUpdates` because that flag
/// has been observed to stick at `false` after a failed appcast fetch
/// (404, no network at launch, etc.), leaving the menu item
/// permanently un-clickable.
struct CheckForUpdatesMenuItem: View {
    let updaterStack: UpdaterStack

    var body: some View {
        Button("Check for Updates…") {
            #if DEBUG
                MockUpdateAvailability.simulate(into: updaterStack.stateModel)
            #else
                updaterStack.updater.checkForUpdates()
            #endif
        }
        // The state model isn't injected into the CommandGroup
        // environment, so we observe it directly via Bindable rather
        // than `@Environment`. The closure-style read keeps SwiftUI's
        // dependency tracking honest.
        .disabled(updaterStack.stateModel.isBusy)
    }
}
