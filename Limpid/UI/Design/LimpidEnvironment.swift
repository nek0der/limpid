// LimpidEnvironment.swift
// Limpid — `EnvironmentValues` extensions for types that aren't
// `@Observable` (so we can't use the SwiftUI type-based environment).
// `@Observable` reference types (WindowSession / NotificationHistoryStore
// / NotificationHistoryPresentation / LimpidDragState) flow through
// `.environment(value)` and `@Environment(Type.self)` instead and don't
// need entries here.
//
// Non-Observable references flow through here. Defaults stand in for
// SwiftUI Previews / unit tests; `AppState` always installs the real
// values at the root of the Limpid scene so production never touches
// the fallbacks.

import Sparkle
import SwiftUI

extension EnvironmentValues {
    /// libghostty surface registry — UUID ↔ SurfaceView lookup.
    /// Typed as the protocol so views (and `TabActions`) don't
    /// see the concrete `SurfaceRegistry`; tests can swap in their
    /// own conformer.
    @Entry var surfaceRegistry: any SurfaceViewProviding = NoopSurfaceRegistry()

    /// Notification manager for OSC 9 / OSC 777 / COMMAND_FINISHED
    /// emission + Dock badge updates.
    @Entry var notificationManager: LimpidNotificationManager?

    /// Sparkle updater. `nil` in Previews / tests; LimpidApp installs
    /// the live `SPUStandardUpdaterController.updater` on both window
    /// scenes so the Settings → General pane can drive the auto-check
    /// toggle + "Check Now" button without re-creating a controller.
    @Entry var sparkleUpdater: SPUUpdater?

    /// Tracks per-tab Claude Code session ids written by the shim's
    /// hook. `TabActions.closeTab` calls into it so the on-disk
    /// record is dropped when the user closes a tab. `nil` in Previews
    /// / tests is fine — the optional parameter on the close helpers
    /// just skips the cleanup step.
    @Entry var claudeSessionTracker: ClaudeSessionTracker?

    /// Tracks per-tab Codex CLI session ids written by the codex hook.
    /// Mirror of `claudeSessionTracker` for the Codex integration.
    @Entry var codexSessionTracker: CodexSessionTracker?

    /// Command palette frecency scoring store. `nil` in Previews /
    /// tests; LimpidApp installs the real instance at the scene root.
    @Entry var frecencyStore: FrecencyStore?
}
