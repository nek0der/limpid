// SearchActions.swift
// Limpid — in-pane search verbs (⌘F begin / ⌘G next / ⇧⌘G previous /
// Esc end). First slice carved out of `TabActions` as part of the
// architecture roadmap's namespace split — TabActions had grown to
// 41 methods across Tab / Pane / Search / Container / NavBar /
// CommandPalette concerns and the file no longer fit in one head.
// New slices follow the same `enum XActions { static func … }` shape.

import Foundation
import GhosttyKit

extension Notification.Name {
    /// Posted by `SearchActions.beginSearch` carrying the pane id as
    /// `object`. The search overlay observes this so it re-grabs
    /// keyboard focus when ⌘F is hit a second time while the overlay
    /// is already on screen.
    static let limpidSearchFocus = Notification.Name("dev.limpid.searchFocus")
}

/// User-facing search order follows the screen from top to bottom. libghostty
/// names its directions from the terminal cursor's reverse-history order, so
/// its `previous` action advances visually and its `next` action moves back.
enum PaneSearchDirection {
    case forward
    case backward

    var bindingAction: String {
        switch self {
        case .forward: "navigate_search:previous"
        case .backward: "navigate_search:next"
        }
    }

    /// Convert libghostty's newest-first index into the top-to-bottom position
    /// shown in the search field.
    static func displayPosition(selected: Int, total: Int) -> Int? {
        guard total > 0, selected >= 0, selected < total else { return nil }
        return total - selected
    }
}

@MainActor
enum SearchActions {
    /// ⌘F — show the search overlay on the focused pane. Idempotent:
    /// if a state already exists, focus it (the overlay observes
    /// `paneSearchStates` and re-grabs focus on the next render).
    static func beginSearch(_ session: WindowSession) {
        guard let id = focusedPaneID(session) else { return }
        if session.paneSearchStates[id] == nil {
            session.paneSearchStates[id] = PaneSearchState()
        }
        NotificationCenter.default.post(name: .limpidSearchFocus, object: id)
    }

    /// Drop the search state for a pane AND tell libghostty's
    /// renderer to tear its match highlights down. Used by Esc in the
    /// overlay, the close button, and (via registry) any future
    /// caller that wants to end search without going through the
    /// overlay. Single source of truth for "search lifetime ends".
    static func endSearch(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        paneID: UUID
    ) {
        session.paneSearchStates[paneID] = nil
        guard let surface = registry.view(for: paneID)?.surface else { return }
        let action = "end_search"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// ⌘G — jump to the next match for the focused pane, if any.
    static func searchNext(
        _ session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        guard let id = focusedPaneID(session),
              session.paneSearchStates[id] != nil,
              let view = registry.view(for: id),
              let surface = view.surface
        else { return }
        let action = PaneSearchDirection.forward.bindingAction
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// ⇧⌘G — jump to the previous match.
    static func searchPrevious(
        _ session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        guard let id = focusedPaneID(session),
              session.paneSearchStates[id] != nil,
              let view = registry.view(for: id),
              let surface = view.surface
        else { return }
        let action = PaneSearchDirection.backward.bindingAction
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// Resolve the focused pane id of the active tab so the search
    /// actions know which surface to target. Lives here (not in
    /// `TabActions`) because the search slice is the only consumer;
    /// later slices that need it can promote to a shared helper.
    private static func focusedPaneID(_ session: WindowSession) -> UUID? {
        guard let tab = session.activeTab else { return nil }
        return tab.splitTree.effectiveFocusedLeafID
    }
}
