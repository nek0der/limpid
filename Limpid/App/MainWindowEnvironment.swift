// MainWindowEnvironment.swift
// Limpid — the environment and window treatment every main window's content gets.

import SwiftUI

extension View {
    /// What every main window's root needs around it. Each window's
    /// controller builds its root with this (`presentSupervisionWindows`),
    /// so a value added here reaches every main window.
    func limpidMainWindowEnvironment(_ state: AppState, updaterStack: UpdaterStack) -> some View {
        LiveLocaleAndAccent(settingsStore: state.settingsStore) {
            limpidMainWindowServices(state, updaterStack: updaterStack)
        }
    }

    private func limpidMainWindowServices(_ state: AppState, updaterStack: UpdaterStack) -> some View {
        // No minimum frame here: the window's minimum is its controller's
        // (`ProjectWindowController.minimumContentSize`), which never lays
        // this out smaller.
        containerBackground(
            .regularMaterial,
            for: .window
        )
        // Tag this window's underlying NSWindow as a Limpid main window so
        // `LimpidUpdateDriver.hasInlineTarget` can distinguish it from the
        // Settings window when deciding whether to surface the inline
        // updater UI vs. fall back to Sparkle's standard alert.
        .background(LimpidWindowRoleMarker(role: .main))
        .environment(state.session)
        .environment(state.attention)
        .environment(state.approvalPresentation)
        .environment(state.attentionQueue)
        .environment(state.windowRegistry)
        .environment(state.tmuxPresence)
        .environment(state.historyStore)
        .environment(state.dragState)
        .environment(state.toastCenter)
        .environment(state.primaryKeyHint)
        .environment(state.worktreeMoveSuggester)
        .environment(state.settingsStore)
        .environment(state.reduceTransparencyResolver)
        .environment(state.prStatusStore)
        .environment(state.gitFacts)
        .environment(state.sessionLaunches)
        .environment(state.stopLedger)
        .environment(state.usageLimitResetSync)
        .environment(\.prStatusSyncer, state.prStatusSyncer)
        .environment(\.surfaceRegistry, state.registry)
        .environment(\.reviewWriters, state.reviewWriters)
        .environment(\.agentProjection, state.agentProjection)
        .environment(\.frecencyStore, state.frecencyStore)
        .environment(\.notificationManager, state.notificationManager)
        .environment(\.sparkleUpdater, updaterStack.updater)
        .environment(updaterStack.stateModel)
    }
}

/// A window's language and accent, read where SwiftUI tracks them. A window
/// controller builds its root view once, outside any view's `body`, so a
/// value read there would stay the one the window opened with: a language
/// or accent changed in Settings would reach only the parts that read the
/// store themselves, and a window would show two languages until relaunch.
/// Read in this `body`, a change reaches every view below that reads them.
struct LiveLocaleAndAccent<Content: View>: View {
    let settingsStore: SettingsStore
    @ViewBuilder let content: Content

    var body: some View {
        content
            .environment(\.locale, settingsStore.appLocale)
            // The accent as both `\.limpidAccent` (Limpid's own marks) and
            // SwiftUI's `\.tint` (its Toggle, Slider, and the like). Sheets
            // and popovers apply it again at their call site
            // (`View.limpidAccentPropagated(_:)`): macOS presents them
            // apart from the window, so these don't reach inside.
            .limpidAccentPropagated(
                LimpidColor.accent(for: settingsStore.settings.appearance.accentColor)
            )
    }
}
