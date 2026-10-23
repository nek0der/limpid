// InstantWorktreeKeyText.swift
// Limpid — the note the new worktree sheet shows once, the first time ⌥⌘N is pressed after an update.

import Foundation

/// What the sheet says above its form the one time ⌥⌘N opens it after an
/// update from the release where those keys were the sheet
/// (`KeyboardSettings.noteChangedKeys(since:)`): they make a worktree with
/// no sheet from now on, and the sheet has its own keys.
enum InstantWorktreeKeyText {
    /// The note, with the keys as they are bound now: `now` for Create
    /// Worktree Now, `sheet` for New Worktree…. A key the person took off
    /// is named by its action instead.
    static func note(now: StoredShortcut?, sheet: StoredShortcut?) -> LocalizedStringResource {
        switch (now?.displayString, sheet?.displayString) {
        case let (now?, sheet?):
            LocalizedStringResource(
                "\(now) now creates a worktree without showing this sheet. This sheet now opens with \(sheet).",
                comment: "New worktree sheet, once after an update: the note above it: Create Worktree Now's keys, New Worktree…'s"
            )
        case let (now?, nil):
            LocalizedStringResource(
                "\(now) now creates a worktree without showing this sheet. To open this sheet, choose New Worktree… in the File menu.",
                comment: "New worktree sheet, once after an update, New Worktree… with no keys; the shortcut of Create Worktree Now"
            )
        case (nil, _):
            LocalizedStringResource(
                "Create Worktree Now creates a worktree without showing this sheet. This is the New Worktree… sheet.",
                comment: "New worktree sheet, once after an update: the note above the form when Create Worktree Now has no shortcut"
            )
        }
    }
}
