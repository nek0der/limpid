// KeyboardSettings+Introductions.swift
// Weir — keys whose meaning changed since the release a person updated from, said once as they are first pressed.

import Foundation

extension KeyboardSettings {
    /// What ⌥⌘N did in the previous release: it opened New Worktree…, the
    /// sheet. Create Worktree Now (`newWorktreeNow`) has those keys now,
    /// and makes a worktree with no sheet.
    static let schema1NewWorktreeDefault = StoredShortcut(key: "n", modifiers: [.command, .option])

    /// Whether `action` is still to say, the first time it is used, what
    /// its keys did before: the person's hands expect the old meaning. Only
    /// while it keeps those keys; bound to others since, the person chose
    /// them knowing what they do.
    func isIntroductionDue(for action: WeirShortcutAction) -> Bool {
        keysToIntroduce.contains(action.rawValue) && shortcut(for: action) == Self.schema1NewWorktreeDefault
    }

    /// `action` said what changed: it acts as itself from now on.
    mutating func markIntroduced(_ action: WeirShortcutAction) {
        keysToIntroduce.removeAll { $0 == action.rawValue }
    }

    /// On the move from schema 1 (the previous release), after the move's
    /// keyboard rules have run: a person whose ⌥⌘N opened the sheet, and
    /// for whom it is Create Worktree Now's now, sees the sheet once more
    /// on their first ⌥⌘N, saying what the keys do from then on. Without
    /// that, the keys their hands know would make a worktree, fetch and
    /// setup included, with nothing asked. `schema1` is the keyboard as
    /// the file had it, before its bindings were moved.
    mutating func noteChangedKeys(since schema1: KeyboardSettings) {
        // Their own binding for New Worktree…, or none, meant ⌥⌘N was not
        // the sheet; a schema 1 file has no other way to say so, and a
        // hand edit's lists are read the same way.
        let raw = WeirShortcutAction.newWorktree.rawValue
        let wasSheetOnOptionCommandN = schema1.overrides[raw] == nil
            && !schema1.unassigned.contains(raw) && !schema1.unbound.contains(raw)
        // Their own binding on ⌥⌘N for anything else keeps it theirs, and
        // Create Worktree Now starts with no keys (`normalize`).
        guard wasSheetOnOptionCommandN,
              shortcut(for: .newWorktreeNow) == Self.schema1NewWorktreeDefault,
              !keysToIntroduce.contains(WeirShortcutAction.newWorktreeNow.rawValue)
        else { return }
        keysToIntroduce.append(WeirShortcutAction.newWorktreeNow.rawValue)
    }
}
