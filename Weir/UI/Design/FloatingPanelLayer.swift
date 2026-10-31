// FloatingPanelLayer.swift
// Weir — the scene-root layer that hosts the floating panels over the
// main window, and the one place that reads every floating surface's state
// for `FloatingSurfaceRules`.

import SwiftUI

/// The pane rename field, the prompt cache panel and the container color
/// picker, in the order they stack, over the whole window. One layer rather
/// than an overlay each, so the rules about which surface gives way sit
/// beside the hosts they apply to. Empty regions of every host pass clicks
/// through to the window.
struct FloatingPanelLayer: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(PaneRenamePresentation.self) private var renamePresentation
    @Environment(PromptCachePanelPresentation.self) private var promptCachePresentation
    @Environment(ContainerColorPresentation.self) private var colorPresentation
    @Environment(ApprovalPresentationStore.self) private var approvalPresentation
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(PRHoverPresentation.self) private var prHoverPresentation
    @Environment(ProjectWindowState.self) private var window
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

    /// This window's approval card.
    private var card: WindowApprovalCard {
        window.approvalCard
    }

    /// Every floating surface that is up now in this window.
    private var openSurfaces: Set<FloatingSurfaceKind> {
        let states: [(FloatingSurfaceKind, Bool)] = [
            (.commandPalette, session.commandPaletteState?.windowID == window.id),
            (.paneRename, renamePresentation.request != nil),
            (.promptCache, promptCachePresentation.request != nil),
            (.containerColor, colorPresentation.request != nil),
            // A card is a working surface while it has the keyboard. A card
            // the person left for the terminal is not counted at all, so it
            // holds nothing back, the prompt cache panel's own opening
            // included.
            (.approvalCard, card.isOpen(in: approvalPresentation) && card.isFocused),
            (.notificationHistory, historyPresentation.isPresented),
            (.planUsage, window.planUsage.isPresented),
            (.prCard, prHoverPresentation.visible != nil),
            // The review tab while it is in front: behind a terminal tab it
            // holds no surface back.
            (.review, window.review?.isShown == true),
            (.titleBarMenu, window.titleBarMenu != nil)
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
            },
            closeTitleBarMenu: { [window] in window.titleBarMenu = nil }
        )
    }
}
