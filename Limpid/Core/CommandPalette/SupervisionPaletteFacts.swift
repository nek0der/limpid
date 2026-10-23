// SupervisionPaletteFacts.swift
// Limpid — what the palette knows about the supervision window it opens in.

import Foundation

/// The window the palette opened in, as far as its rows' enabled states
/// need it: read by the window's own code, since Core cannot name a
/// window's session rows or its review tab.
struct SupervisionPaletteFacts: Equatable {
    /// The window's project, kept while a scratch tab is selected.
    var projectID: UUID?
    /// How many session rows ⌘[ ⌘] walk.
    var sessionRowCount: Int
    /// Whether the window's strip shows a review tab, which ⇧⌘[ ⇧⌘] step
    /// through with the terminal tabs.
    var hasReviewTab: Bool
    /// The number of the turn "Restore Code to Before This Turn…" restores
    /// to (`RestoreEntryTarget`), `nil` when there is none to offer.
    var restoreTurnNumber: Int?
    /// Every project's rows in the order the window's sidebar lists them,
    /// which the palette lists each project's worktrees in. Empty
    /// leaves them in the projects' own order.
    var rowOrder: [ContainerID] = []
    /// The section each row is listed in, as the window's sidebar shows
    /// it (a row not named is a working one), so a worktree the palette
    /// marks as one of the other worktrees is one the sidebar lists there.
    /// Empty when the window gives none; then the palette goes by what the
    /// row holds alone (`SidebarSectionRule.isUnopened`).
    var rowSections: [ContainerID: SidebarSection] = [:]
    /// Whether the window's review tab is in front, standing where the
    /// terminal was (`ProjectWindowState.arePanesHidden`): the pane
    /// commands are off then (`isOffPaneCommand`).
    var arePanesHidden = false

    /// Whether ⇧⌘[ ⇧⌘] have a tab to step to among `tabCount` terminal
    /// tabs: another one, or the window's review tab (`facts`). The menu
    /// and the palette ask the same question.
    static func canCycleTab(tabCount: Int, facts: Self) -> Bool {
        tabCount > (facts.hasReviewTab ? 0 : 1)
    }

    /// Whether `action` is a pane command (split, equalize, zoom, focus a
    /// neighbor) while the window's panes are hidden, which leaves it off.
    static func isOffPaneCommand(_ action: LimpidShortcutAction, arePanesHidden: Bool) -> Bool {
        arePanesHidden && action.category == .splits
    }
}
