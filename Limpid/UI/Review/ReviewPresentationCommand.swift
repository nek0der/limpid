// ReviewPresentationCommand.swift
// Limpid — the one entry point every Review Changes affordance goes through.

import SwiftUI

/// The toolbar button, the View menu, the command palette and the container
/// actions menu all mean the same thing by "Review Changes": show the surface,
/// or put it away. Routing them through one place is what keeps the button
/// able to close what it opened.
@MainActor
enum ReviewPresentationCommand {
    static func toggle(
        session: WindowSession,
        presentation: ReviewPresentation,
        registry: (any SurfaceViewProviding)? = nil
    ) {
        if presentation.isPresented {
            reveal(session: session, registry: registry)
        }
        guard let directory = ReviewAgents.directory(session: session) else {
            // The active container has nothing to review, but review may still
            // be open over it; closing is the only reading left.
            presentation.close()
            return
        }
        presentation.toggle(
            directory,
            originPaneID: session.activeTab?.splitTree.effectiveFocusedLeafID
        )
    }

    /// We keep Find in the menu so a focused terminal can route its ignored
    /// key binding to the reader instead of competing with a hidden button.
    static func find(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        presentation: ReviewPresentation,
        registry: any SurfaceViewProviding
    ) {
        if presentation.isPresented {
            NotificationCenter.default.post(name: .limpidReviewFind, object: session, userInfo: ["action": action])
            return
        }
        switch action {
        case .find: SearchActions.beginSearch(session)
        case .findNext: SearchActions.searchNext(session, registry: registry)
        case .findPrevious: SearchActions.searchPrevious(session, registry: registry)
        default: break
        }
    }

    /// Bring the panes review had put to sleep back before the layout swaps.
    ///
    /// While review is up, every pane but the docked one is occluded, which
    /// stops its renderer. Closing mounts them all again in the same pass, and
    /// the occlusion pass that wakes them runs after that — so they appeared
    /// for a frame holding whatever their layer last had. Waking them first is
    /// what removes the flash.
    static func reveal(session: WindowSession, registry: (any SurfaceViewProviding)?) {
        guard let registry, let tab = session.activeTab else { return }
        registry.updateOcclusion(visibleIDs: Set(tab.splitTree.allLeafIDs()))
    }
}

/// The View-menu entry. A bindable shortcut whose `ghosttyAction` is nil
/// reaches nothing without a menu item to receive the keystroke, so this is
/// what makes `⌘⌥R` work at all.
struct ReviewChangesMenuItem: View {
    let state: AppState

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .limpidReviewChanges, object: state.session)
        } label: {
            Label("Review Changes", systemImage: ReviewPresentation.symbol)
        }
        .limpidShortcut(.reviewChanges, in: state.settingsStore)
        .disabled(!ReviewAgents.canReview(
            session: state.session,
            presentation: state.reviewPresentation
        ))
    }
}
