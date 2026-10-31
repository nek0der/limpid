// ReviewTabHandler.swift
// Weir — the review tab's way to its window's actions, handed to the views that draw it.

import SwiftUI
import WeirDomain

/// What the review tab's views do through their window: the dropdown, "Add
/// to Scope", the band's "Mark as Viewed" and destination, and ⌘⏎. Built once per window
/// (`ReviewTabActions.handler`), so the views need no app state. Equal by
/// window, so a redraw of the window does not tell every view it changed.
struct ReviewTabHandler: Equatable {
    let windowID: WindowID
    /// The tab's conversation, turns, and viewed line, as of now.
    let context: @MainActor (ReviewTabState) -> ReviewTabModel.Context
    /// A choice in "Review Scope", with the conversation it is listed under
    /// (`ReviewScopeMenu.Choice`), `nil` for one no conversation owns.
    let select: @MainActor (ReviewScopeOption, ConversationKey?) -> Void
    /// Every conversation of the tab's worktree, named: the names the
    /// destination menu and the band give a conversation's pane.
    let conversations: @MainActor (ReviewTabState) -> [ConversationChoice]
    /// Reads the files each turn of the tab's range changed, for the file
    /// headers' tags.
    let loadFileTagPaths: @MainActor (ReviewTabState) async -> Void
    /// The file headers' tags, by path, as far as their files have been read.
    let fileTags: @MainActor (ReviewTabState) -> ReviewFileTagSet
    let addFollowingTurns: @MainActor () -> Void
    let markViewed: @MainActor () -> Void
    /// Whether the review has read what the tab names, which "Mark as
    /// Viewed" and "Add to Scope" wait for.
    let isShowingItsScope: @MainActor (ReviewTabState) -> Bool
    /// ⌘⏎ in the diff, through the band's gate.
    let primaryKey: @MainActor () -> Void
    /// The band's button as drawn now, for the gate's wait, by the band of
    /// the tab opened as the `UUID` given.
    let noteBandShown: @MainActor (ReviewBandGate.Shown?, UUID) -> Void
    /// Counts again the paths of the tab's worktree changed outside every
    /// turn (`WorktreeChanges`).
    let refreshPathsOutsideTurns: @MainActor () async -> Void
    /// The paths of the tab's worktree changed outside every turn.
    let pathsOutsideTurns: @MainActor (ReviewTabState) -> Set<String>
    /// The tab's ×, the band's Close, and the review's own Close; refused
    /// while a comment is being written.
    let close: @MainActor () -> Void
    /// The panes the band's destination menu offers, named after the
    /// worktree's conversations it is given (`conversations`), which the
    /// band reads once for both its menu and its status.
    let destinations: @MainActor (ReviewTabState, [ConversationChoice]) -> [ReviewTabModel.DestinationChoice]
    /// The same panes, by id alone, for what reads them without naming
    /// them (the poll of what runs in each).
    let destinationPanes: @MainActor (ReviewTabState) -> [UUID]
    /// Whether the pane the tab writes to is still open.
    let isDestinationOpen: @MainActor (ReviewTabState) -> Bool
    /// The destination menu's choice.
    let chooseDestination: @MainActor (UUID) -> Void
    /// Starts the terminal of a destination that has none yet, for the
    /// insert (`ReviewInsertion.Target.startPane`).
    let startPane: @MainActor (UUID) async -> Bool
    /// Every comment went into the pane given: the tab closes to it, if it
    /// is still the one the insert started in; what it did decides whether
    /// the review says it on a toast.
    let closeAfterInsert: @MainActor (ReviewTabInserted) -> ReviewTabInsertClose
    /// What each hunk header of the files on screen offers, by file
    /// id and then by its `@@` line; a header with no entry offers nothing.
    let hunkActions: @MainActor (ReviewHunkDiscardActions.TabHunks, Locale) -> [String: [String: ReviewHunkAction]]
    /// What names the paths changed after the tab's range, which
    /// `prepareHunkDiscards` reads when it changes.
    let hunkDiscardKey: @MainActor (ReviewTabState) -> ReviewLaterPathsKey?
    let prepareHunkDiscards: @MainActor (ReviewTabState) async -> Void
    /// "Discard" on a hunk.
    let discardHunk: @MainActor (ReviewTabState, ReviewFile, String, Locale) -> Void
    /// "Undo Discard" on a discarded hunk.
    let undoDiscard: @MainActor (ReviewTabState, ReviewFile, String, Locale) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

extension EnvironmentValues {
    /// Nil outside a supervision window, which has no review tab.
    @Entry var reviewTabHandler: ReviewTabHandler?
}
