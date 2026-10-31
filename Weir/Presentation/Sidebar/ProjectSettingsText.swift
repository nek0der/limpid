// ProjectSettingsText.swift
// Weir — the project settings sheet's title and section headings.

import Foundation

/// The words the project settings sheet opens with and divides itself by,
/// beside "General" and "Worktrees", which other places share. The view
/// and the tests read the same resources, so a test pins what the sheet
/// shows. The headings are in title case, as the Settings window's are.
enum ProjectSettingsText {
    /// The sheet's title, which names the project, as the new worktree
    /// sheet's does: the sheet is a window of its own, and nothing else in
    /// it says whose settings these are.
    /// `nil` once the project is closed from elsewhere while the sheet is
    /// up: the title then names no project rather than an empty one.
    static func title(project: String?) -> LocalizedStringResource {
        guard let project else {
            return LocalizedStringResource(
                "Project Settings",
                comment: "Project settings sheet: title while the project is gone from the session"
            )
        }
        return LocalizedStringResource(
            "Project Settings for \(project)",
            comment: "Project settings sheet: title; the argument is the project's name"
        )
    }

    /// Where new worktrees go: 「場所」 in Japanese, as the new
    /// workspace sheet's VoiceOver names it.
    static let placement = LocalizedStringResource(
        "Placement",
        comment: "Project settings sheet: the menu of where new worktrees go"
    )

    /// The agents whose own `git worktree add` this project's placement
    /// and setup apply to.
    static let agentWorktrees = LocalizedStringResource(
        "Agent Worktrees",
        comment: "Project settings sheet: heading of the per-agent toggles that apply this project's rules to their git worktree add"
    )

    /// "Setup" in English and 「セットアップ」 in Japanese wherever these commands
    /// are named: this heading, the new worktree's stage, and its errors.
    static let setupCommands = LocalizedStringResource(
        "Setup Commands",
        comment: "Project settings sheet: section heading of the commands run in every new worktree"
    )

    /// "Test" as the decision bar's ✓ chip says it, not "check":
    /// these are the commands whose result the turn shows as its test.
    static let checkCommands = LocalizedStringResource(
        "Test Commands",
        comment: "Project settings sheet: heading and field label of the commands whose last run shows with the turn"
    )

    /// The files Git ignores that each new worktree gets a copy of.
    static let filesToCopy = LocalizedStringResource(
        "Files to Copy into New Worktrees",
        comment: "Project settings sheet: heading and field label of the files Git ignores copied into each new worktree"
    )

    /// What the section is for, and how a row is written.
    static let filesToCopyFooter = LocalizedStringResource(
        "Files Git ignores, such as .env, copied from the project folder each time Weir creates a worktree. One path or pattern per line.",
        comment: "Project settings sheet: footer of the files to copy into new worktrees"
    )
}
