// ReviewPresentationCommand.swift
// Limpid — Find routed to the review or the terminal, and the review's menu items.

import SwiftUI

/// What the menus do around the review: Find goes to the review while it is
/// in front, and the panes it put to sleep wake before the layout swaps.
@MainActor
enum ReviewPresentationCommand {
    /// We keep Find in the menu so a focused terminal can route its ignored
    /// key binding to the reader instead of competing with a hidden button.
    /// Acts in `window`: its review, or its focused pane.
    static func find( // swiftlint:disable:this function_parameter_count
        _ action: LimpidShortcutAction,
        session: WorkspaceSession,
        isReviewShown: Bool,
        registry: any SurfaceViewProviding,
        commands: any WindowCommandPerforming,
        window: WindowID
    ) {
        if isReviewShown {
            commands.perform(.reviewFind(action), in: window)
            return
        }
        switch action {
        case .find: SearchActions.beginSearch(session, in: window)
        case .findNext: SearchActions.searchNext(session, registry: registry, in: window)
        case .findPrevious: SearchActions.searchPrevious(session, registry: registry, in: window)
        default: break
        }
    }

    /// Bring the panes review had put to sleep back before the layout swaps.
    ///
    /// While the review tab is in front, every pane of the tab behind it is
    /// occluded, which stops its renderer. Closing mounts them all again in the same pass, and
    /// the occlusion pass that wakes them runs after that — so they appeared
    /// for a frame holding whatever their layer last had. Waking them first is
    /// what removes the flash.
    static func reveal(session: WorkspaceSession, window: WindowID, paneVisibility: PaneVisibilityReporter) {
        guard let tab = session.activeTab(in: window) else { return }
        paneVisibility.wake(Set(tab.splitTree.allLeafIDs()))
    }
}

/// The View-menu entry. A bindable shortcut whose `ghosttyAction` is nil
/// reaches nothing without a menu item to receive the keystroke, so this is
/// what makes `⌘⌥R` work at all.
struct ReviewChangesMenuItem: View {
    let state: AppState
    /// The window the item acts in; `nil` while no main window is key,
    /// where the item is off.
    let window: WindowID?

    var body: some View {
        Button {
            guard let window else { return }
            state.windowRegistry.perform(.review, in: window)
        } label: {
            // The menu's name for ⌥⌘R; the buttons that open
            // the same tab on the unviewed turns say "Review Unviewed".
            Label("Review", systemImage: ReviewPresentation.symbol)
        }
        .limpidShortcut(.review, in: state.settingsStore)
        // The review tab opens from any tab, and says why when there is
        // nothing to read.
        .disabled(window.flatMap { state.session.activeTab(in: $0) } == nil)
    }
}

struct ReviewLatestTurnMenuItem: View {
    let state: AppState
    /// The window the item acts in; `nil` while no main window is key,
    /// where the item is off.
    let window: WindowID?

    var body: some View {
        Button {
            guard let window else { return }
            state.windowRegistry.perform(.reviewLatestTurn, in: window)
        } label: {
            Label(title, systemImage: ReviewPresentation.symbol)
        }
        .accessibilityLabel(Text(title))
        .limpidShortcut(.reviewLatestTurn, in: state.settingsStore)
        .disabled(isDisabled)
    }

    /// The pane's latest turn, which the review tab reads from its record.
    private var title: LocalizedStringKey {
        "Review Latest Turn"
    }

    /// With a tab in front, the review tab always answers, with the turn or
    /// with why there is none to read.
    private var isDisabled: Bool {
        window.flatMap { state.session.activeTab(in: $0) } == nil
    }
}
