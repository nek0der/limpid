// AttentionNavigating.swift
// Limpid — the port through which the attention list takes the person to an item.

import Foundation

/// What the attention list needs from the app to move the person: which
/// project a window shows, and how to bring an item into view. The app
/// layer implements it, since panes, windows, and the approval card live
/// there.
@MainActor
protocol AttentionNavigating: AnyObject {
    /// The project whose items `window` walks first: the one the window
    /// shows, kept while a scratch tab is selected
    /// (`WindowSelection.shownProjectID`); `nil` for a window that has
    /// shown none.
    func projectID(of window: ProjectWindowState) -> UUID?
    /// Shows `item`: its pane, or the approval card for a request no pane is
    /// known for. `opensTurnReview`: ⌘J arrived, and an unread turn that
    /// changed files opens its review when the setting asks, in
    /// `window`'s review tab: the one `presentWindow(for:from:)` returned,
    /// else the one the list was used in. `nil` when neither names one;
    /// then the window commands act on.
    func go(to item: AttentionItem, opensTurnReview: Bool, in window: ProjectWindowState?)
    /// Shows the pane a runtime runs in now, in `window` (`nil`: the window
    /// commands act on). False when it runs in no pane that is in a tab.
    func go(toRuntime runtimeID: String, in window: ProjectWindowState?) -> Bool
    /// Shows the window that shows `item`'s pane once it is gone to, and
    /// returns it: the one that shows the project it is in, brought forward
    /// and back if hidden, else `window`, the one the person used, switched
    /// to that project in place and brought back if hidden. Its decision
    /// bar is where the item is chosen. `nil` when no window can
    /// show it (`window` closed, the project gone). Not a question: it
    /// raises, shows, and switches windows, so only going to an item asks
    /// it.
    func presentWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState?
    /// As `presentWindow(for:from:)`, for an item ⌘-clicked in the Needs
    /// Attention list: an item of another project opens in a new
    /// window rather than switching `window`, unless a window shows that
    /// project already, which comes forward.
    func presentNewWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState?
}

extension AttentionNavigating {
    /// A navigator with no windows to make goes to the item as it would
    /// without ⌘.
    func presentNewWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState? {
        presentWindow(for: item, from: window)
    }
}
