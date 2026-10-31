// InstantWorktreePlan.swift
// Weir — ⌥⌘N: a worktree made at once with the last choices, or the sheet when they cannot make one.

import Foundation

/// ⌥⌘N makes a worktree with no sheet: the sheet's form as it
/// would open, untouched, created as it is. So it follows every rule the
/// sheet does, the fetch's base among them (`origin/main` with the fetch
/// on), and the next sheet starts from the same choices.
enum InstantWorktreePlan {
    enum Decision: Equatable, Sendable {
        case create
        /// The form as it opens makes nothing (no base, a folder in the
        /// way): the sheet opens instead, saying why, for the person to
        /// change what stops it.
        case openSheet
    }

    static func decision(for model: NewSessionModel) -> Decision {
        model.plan == nil ? .openSheet : .create
    }

    /// What VoiceOver says once the worktree is made: nothing else on
    /// screen says it, as the row is new in a sidebar the keys are not in.
    static func announcement(branch: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "Created \(branch)",
            comment: "VoiceOver, after Option-Command-N made a worktree; the argument is its branch"
        )
    }
}
