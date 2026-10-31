// NewWorktreeSheetSlot.swift
// Weir — one window's new worktree sheet: what it was asked for, and whether it has come up.

import Foundation

/// The new worktree sheet of one window, from the ask to its close.
///
/// A request is only what was asked for; the sheet is up once its view has
/// appeared. We keep the two apart because SwiftUI holds a request it
/// cannot show and shows it whenever it next can: a request left waiting
/// would refuse every later ⌘N and ＋ as "a sheet is up", then open
/// minutes later, unasked. So a request that has not come up never stands
/// in the way of a new one, and one asked for while the window has another
/// sheet over it is not kept at all.
struct NewWorktreeSheetSlot: Equatable {
    /// How an ask ended.
    enum Outcome: Equatable {
        case opened
        /// The sheet is up already: a second would replace what the
        /// person typed, or a Git failure being shown.
        case refusedSheetUp
        /// Another sheet or an alert is over the window: ours could not
        /// come up now, and kept, would come up as that one goes.
        case refusedWindowCovered
    }

    /// What the sheet is for: the request shown, or asked for and on its
    /// way up. `nil` with no sheet.
    private(set) var request: NewSessionSheetRequest?
    /// Whether the sheet's view has appeared for `request`.
    private(set) var isShown = false
    /// Whether the sheet opened for ⌥⌘N's first use after an update, and
    /// says above its form that those keys make a worktree with no sheet
    /// now (`KeyboardSettings.noteChangedKeys(since:)`).
    private(set) var introducesInstantKey = false

    /// Asks for the sheet on `request`. `isWindowCovered` is whether a
    /// system sheet is attached to the window now, which ours is too once
    /// it has begun; it only counts before ours is up.
    mutating func open(
        _ request: NewSessionSheetRequest,
        isWindowCovered: Bool,
        introducesInstantKey: Bool = false
    ) -> Outcome {
        if isShown {
            return .refusedSheetUp
        }
        if isWindowCovered {
            // Ours on its way up covers the window too, and is left to come
            // up; anything else's is dropped as it ends (`coverEnded`).
            return .refusedWindowCovered
        }
        // A request that never came up is replaced, not waited for.
        self.request = request
        self.introducesInstantKey = introducesInstantKey
        return .opened
    }

    /// The sheet's view appeared for the request with `id`; one for a
    /// request since replaced says nothing. Whether it came up saying what
    /// ⌥⌘N does now, which is then said and not to be said again.
    @discardableResult
    mutating func appeared(_ id: UUID) -> Bool {
        guard request?.id == id, !isShown else { return false }
        isShown = true
        return introducesInstantKey
    }

    /// The sheet closed (created, canceled, or its project removed).
    mutating func close() {
        request = nil
        isShown = false
        introducesInstantKey = false
    }

    /// The window's system sheets have all ended. A request still not up
    /// lost its moment to another sheet, and is dropped rather than shown
    /// later unasked.
    mutating func coverEnded() {
        if !isShown {
            request = nil
            introducesInstantKey = false
        }
    }
}
