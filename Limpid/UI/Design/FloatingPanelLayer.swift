// FloatingPanelLayer.swift
// Limpid — the scene-root layer that hosts the floating panels over the
// main window, and the one place that reads every floating surface's state
// for `FloatingSurfaceRules`.

import SwiftUI

/// The pane rename field, the prompt cache panel and the container color
/// picker, in the order they stack, over the whole window. One layer rather
/// than an overlay each, so the rules about which surface gives way sit
/// beside the hosts they apply to. Empty regions of every host pass clicks
/// through to the window.
struct FloatingPanelLayer: View {
    @Environment(WindowSession.self) private var session
    @Environment(PaneRenamePresentation.self) private var renamePresentation
    @Environment(PromptCachePanelPresentation.self) private var promptCachePresentation
    @Environment(ContainerColorPresentation.self) private var colorPresentation
    @Environment(ApprovalPresentationStore.self) private var approvalPresentation
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(PRHoverPresentation.self) private var prHoverPresentation
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        ZStack {
            PaneRenamePanelHost()
            PromptCachePanelHost()
            ContainerColorPanelHost()
        }
        .onChange(of: openSurfaces, initial: true) { previous, current in
            let coordinator = coordinator
            coordinator.updateGates(open: current)
            coordinator.makeWay(from: previous, to: current) { openSurfaces }
            // What making way closed changes what may open.
            coordinator.updateGates(open: openSurfaces)
        }
    }

    /// Every floating surface that is up now.
    private var openSurfaces: Set<FloatingSurfaceKind> {
        let states: [(FloatingSurfaceKind, Bool)] = [
            (.commandPalette, session.commandPaletteState != nil),
            (.paneRename, renamePresentation.request != nil),
            (.promptCache, promptCachePresentation.request != nil),
            (.containerColor, colorPresentation.request != nil),
            // A card the user turned to is a working surface; one shown
            // only while the pointer rests on its row is a hover peek.
            (.approvalCard, approvalPresentation.presentedID != nil && approvalPresentation.isPresentedOnRequest),
            (.approvalPreview, approvalPresentation.presentedID != nil && !approvalPresentation.isPresentedOnRequest),
            (.notificationHistory, historyPresentation.isPresented),
            (.prCard, prHoverPresentation.visible != nil),
            (.review, reviewPresentation.isPresented)
        ]
        return Set(states.filter(\.1).map(\.0))
    }

    private var coordinator: FloatingSurfaceCoordinator {
        FloatingSurfaceCoordinator(
            promptCache: promptCachePresentation,
            containerColor: colorPresentation,
            endRename: {
                // As a click elsewhere ends it: the keyboard goes back to
                // the pane's terminal, and the field commits on losing it.
                if let paneID = renamePresentation.request?.paneID {
                    PaneActions.pullKeyboardFocus(to: paneID, registry: registry)
                }
            }
        )
    }
}
