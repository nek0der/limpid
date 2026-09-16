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
    /// We share open drafts through the app-owned pool to avoid concurrent writers.
    @Entry var reviewStores = ReviewStorePool(shouldPersist: false)

    /// libghostty surface registry — UUID ↔ SurfaceView lookup.
    /// Typed as the protocol so views (and `TabActions`) don't
    /// see the concrete `SurfaceRegistry`; tests can swap in their
    /// own conformer.
    @Entry var surfaceRegistry: any SurfaceViewProviding = NoopSurfaceRegistry()

    /// tmux control-mode connections and the tabs mirroring through
    /// them. `nil` in Previews / tests, where no pane mirrors.
    @Entry var tmuxConnectionStore: TmuxConnectionStore?

    /// Notification manager for OSC 9 / OSC 777 / COMMAND_FINISHED
    /// emission + Dock badge updates.
    @Entry var notificationManager: LimpidNotificationManager?

    /// Sparkle updater. `nil` in Previews / tests; LimpidApp installs
    /// the live `SPUStandardUpdaterController.updater` on both window
    /// scenes so the Settings → General pane can drive the auto-check
    /// toggle + "Check Now" button without re-creating a controller.
    @Entry var sparkleUpdater: SPUUpdater?

    /// Reduces the agent records into what each pane shows. `TabActions`
    /// and `PaneActions` tell it when a pane closes so the records that
    /// pane held are judged again immediately rather than at the next
    /// sweep. `nil` in Previews / tests is fine — the optional parameter
    /// on the close helpers just skips the step.
    @Entry var agentProjection: AgentProjectionAdapter?

    /// Command palette frecency scoring store. `nil` in Previews /
    /// tests; LimpidApp installs the real instance at the scene root.
    @Entry var frecencyStore: FrecencyStore?

    /// Pull-request status scheduler. Reached from the sidebar row's
    /// context menu for a manual refresh. `nil` in Previews / tests.
    @Entry var prStatusSyncer: PRStatusSyncer?
}
