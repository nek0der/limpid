// LimpidEnvironment.swift
// Limpid — `EnvironmentValues` extensions for types that aren't
// `@Observable` (so we can't use the SwiftUI type-based environment).
// `@Observable` reference types (WorkspaceSession / NotificationHistoryStore
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
    @Entry var reviewWriters = ReviewDraftWriterPool(shouldPersist: false)

    /// libghostty surface registry — UUID ↔ SurfaceView lookup.
    /// Typed as the protocol so views (and `TabActions`) don't
    /// see the concrete `SurfaceRegistry`; tests can swap in their
    /// own conformer.
    @Entry var surfaceRegistry: any SurfaceViewProviding = NoopSurfaceRegistry()

    /// Where a pane area reports which panes its window shows. Set by each
    /// main window's root; the default reports nowhere, for Previews and
    /// tests.
    @Entry var paneVisibilityReporter = PaneVisibilityReporter()

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

    /// The identity colors of each session container's conversations
    /// (`ConversationIdentityStore`), which the pane strip and Open Tabs
    /// read for their tabs, as the changes panel reads them for its cards.
    /// `nil` in Previews and tests, where no tab shows a color.
    @Entry var conversationIdentities: ConversationIdentityStore?

    /// Command palette frecency scoring store. `nil` in Previews /
    /// tests; LimpidApp installs the real instance at the scene root.
    @Entry var frecencyStore: FrecencyStore?

    /// Pull-request status scheduler. Reached from the sidebar row's
    /// context menu for a manual refresh. `nil` in Previews / tests.
    @Entry var prStatusSyncer: PRStatusSyncer?

    /// `state.json` while this launch has stopped saving it
    /// (`AppState.suspendedSessionFile`), for the notice Settings → General
    /// shows; `nil` while it is saved. A plain value: the session store is
    /// not `@Observable`, and it decides this once, when it loads.
    @Entry var suspendedSessionFile: URL?

    /// How many turn records the given limits would delete now, for the
    /// confirmation a narrower turn history asks (Advanced), or `nil`
    /// when the count could not be made. Asynchronous, since the sweep that
    /// counts them waits for a pass under way. `nil` in Previews and tests,
    /// where no records are known and nothing is asked.
    @Entry var turnRecordsRemoved: (@MainActor (TurnRetentionLimits) async -> Int?)?

    /// Reads the person's Ghostty config again (Integrations' "Reload").
    /// `nil` in Previews and tests, where there is no terminal to reload.
    @Entry var reloadGhosttyConfig: (@MainActor () -> Void)?
}
