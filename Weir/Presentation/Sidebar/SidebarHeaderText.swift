// SidebarHeaderText.swift
// Weir — what a project's header in the sidebar says, and what VoiceOver reads for it.

import Foundation

/// The words of a project's header, read by the header and by the tests,
/// so a test pins the words on screen.
enum SidebarHeaderText {
    /// The count after the rule, on a folded header only: every row it
    /// hides, its folded sections' too. An open header shows none, since
    /// its rows are in view and each folded section's own heading counts
    /// what it holds. Counting them again in the header ("3 · 55 more")
    /// repeated those numbers, and "more" did not say more of what.
    static func count(_ header: SidebarProjectHeader, locale: Locale) -> String? {
        guard header.isCollapsed else { return nil }
        return (header.workingCount + header.moreCount).formatted(.number.locale(locale))
    }

    /// What VoiceOver reads for the header: the project, and how many
    /// rows it lists, or that another window shows it.
    static func accessibilityLabel(_ header: SidebarProjectHeader, locale: Locale) -> String {
        if header.isInOtherWindow {
            return LocalizedStringResource(
                "\(header.name), project, shown in another window",
                comment: "Sidebar project header, VoiceOver: a project another window shows"
            ).resolved(in: locale)
        }
        // Both counts whether the header is open or folded: on screen an
        // open header leaves them to its rows and a folded one sums them,
        // and VoiceOver has neither the rows nor a sum to go by.
        guard header.moreCount > 0 else {
            return LocalizedStringResource(
                "\(header.name), project, \(header.workingCount) worktrees",
                comment: "Sidebar project header, VoiceOver: the project's name and its working rows"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "\(header.name), project, \(header.workingCount) worktrees, \(header.moreCount) more",
            comment: "Sidebar project header, VoiceOver: the project's name, its working rows, and the rows of its folded sections"
        ).resolved(in: locale)
    }

    /// What VoiceOver and the tooltip say of a folded header's marks: what
    /// waits or runs inside, in words, since the marks are glyphs. `names`
    /// are the marks' state names, as the glyphs read them
    /// (`StateGlyph.Kind.name`). `nil` with none.
    static func contents(_ names: [String], locale: Locale) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.formatted(.list(type: .and).locale(locale))
        return LocalizedStringResource(
            "Contains: \(list)",
            comment: "Sidebar folded project header, VoiceOver and tooltip: the states waiting or running inside it"
        ).resolved(in: locale)
    }

    /// The header's ＋: a new worktree in this project, whichever project
    /// the window shows.
    static func newWorktree(in name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "New Worktree in \(name)…",
            comment: "Sidebar project header's + button and menu item: the new worktree sheet for this project"
        )
    }

    /// The tooltip of the "Other Window" mark, which brings that window
    /// forward.
    static func otherWindowHelp(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "Brings forward the window that shows \(name)",
            comment: "Sidebar project header, tooltip of the Other Window mark"
        )
    }
}
