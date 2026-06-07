// AppState+SettingsConfigSync.swift
// Limpid — bridge `SettingsStore.settings` into libghostty's live
// reload path. Lives outside `LimpidApp.swift` so the host file stays
// under the SwiftLint file-length warning band; the call site is
// `AppState.init`'s `startSettingsConfigSync()`.

import Foundation

extension AppState {
    /// Bridge `SettingsStore.settings` → libghostty live reload.
    /// Observation tracking re-runs on every settings mutation; we
    /// diff against `lastAppliedSettings` so dragging a slider that
    /// settles back to the original value doesn't churn libghostty.
    func startSettingsConfigSync() {
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = self.settingsStore.settings
        } onChange: { [weak self] in
            guard let self else { return }
            let current = self.settingsStore.settings
            guard current != self.lastAppliedSettings else { return }
            // Apply UI-only updates (transparency resolver, color
            // scheme) immediately — they're cheap and the Liquid Glass
            // slab should track the user's intent without the debounce
            // window. Defer the libghostty reload through the debounce
            // so a slider drag collapses into one apply.
            self.reduceTransparencyResolver.apply(
                userEnabled: current.appearance.transparency.isOn
            )
            Self.applyColorScheme(current.appearance.colorScheme)
            self.scheduleSettingsReload()
        }
    }

    /// Re-arm a debounced libghostty reload that fires after a short
    /// idle window. Reads the latest settings value at fire time so a
    /// slider drag collapses into one apply.
    func scheduleSettingsReload() {
        settingsReloadDebounceTask?.cancel()
        settingsReloadDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: PersistenceTiming.interactive)
            guard !Task.isCancelled, let self,
                  let ghosttyApp = self.ghosttyApp else { return }
            let latest = self.settingsStore.settings
            guard latest != self.lastAppliedSettings else { return }
            self.lastAppliedSettings = latest
            GhosttyConfigBridge.reloadConfig(
                app: ghosttyApp, settings: latest,
                resourcesDir: GhosttyApp.resolveResourcesDir(),
                includeUserConfig: latest.advanced.ghosttyConfig.isOn,
                appearance: GhosttyApp.currentAppearance(preference: latest.appearance.colorScheme),
                surfaces: self.registry.allViews
            )
        }
    }
}
