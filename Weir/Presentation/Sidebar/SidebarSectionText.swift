// SidebarSectionText.swift
// Weir — the words the sidebar's fold lines say and VoiceOver reads for them.

import Foundation

/// The names of the lists that fold into a line, read by the sidebar
/// and by the tests, so a test pins the words on screen.
enum SidebarSectionText {
    /// The fold line's name; `nil` for the working rows, which have none.
    static func title(_ section: SidebarSection) -> LocalizedStringResource? {
        switch section {
        case .working:
            nil
        case .missing:
            LocalizedStringResource(
                "Missing Worktrees",
                comment: "Sidebar fold line: the worktrees whose folder is gone from disk, with nothing open in them"
            )
        case .cleanable:
            LocalizedStringResource(
                "Ready to Clean Up",
                comment: "Sidebar fold line: the worktrees whose pull request is merged or closed, with nothing open or uncommitted"
            )
        case .other:
            LocalizedStringResource(
                "Other Worktrees",
                comment: "Sidebar fold line: the worktrees Git reports that nobody has opened in Weir"
            )
        }
    }

    /// What VoiceOver reads for a fold line: its name and how many it holds.
    static func accessibilityLabel(_ section: SidebarSection, count: Int, locale: Locale) -> String {
        let name = title(section)?.resolved(in: locale) ?? ""
        return LocalizedStringResource(
            "\(name), \(count) worktrees",
            comment: "Sidebar fold line, VoiceOver: the list's name, then how many worktrees it holds"
        ).resolved(in: locale)
    }

    /// Whether the fold is open, as VoiceOver reads its value.
    static func state(isOpen: Bool) -> LocalizedStringResource {
        isOpen
            ? LocalizedStringResource("Expanded")
            : LocalizedStringResource("Collapsed")
    }
}
