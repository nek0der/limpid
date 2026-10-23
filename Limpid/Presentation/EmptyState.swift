// EmptyState.swift
// Limpid — what each list, panel, and popover says while it has nothing to show: one inventory, one way of saying it.

import Foundation

/// Every empty state the app draws, each with its message and, where it
/// has one, a description. The view (`SupervisionEmptyState`) draws
/// them all the same way: a symbol, the message under it, the description
/// under that. Only the session area with no tab draws its commands alone
/// and speaks its message (`noTabs`). Kept in one place so the words
/// follow one rule, and a test reads every one of them (`EmptyStateTests`).
///
/// The message says outright what is absent or wrong ("No Notifications",
/// 「通知はありません」), never that it is absent "yet": an empty list is
/// no promise that it fills. In English it is in title case, as Apple
/// writes its own empty states; in Japanese it has no full stop. The
/// description, when there is one, is a short sentence that says how the
/// list fills or why it cannot.
enum EmptyState: Equatable, Sendable {
    /// The sidebar and All Projects, with no project: nothing has been
    /// added, so there is no worktree to say is absent or closed. Its
    /// Open Folder… button says how one is added, so it has no
    /// description that would only repeat it.
    case noProjects
    /// The changes panel, while the window's selection is no worktree: a
    /// scratch tab, or a row that is gone. A worktree with no tab open is
    /// still selected, and lists its turns.
    case noWorktreeSelected
    /// All Projects with projects but no card: it shows only the worktrees
    /// with a tab open or something that needs attention, so the person
    /// has worktrees, only none of them open.
    case noOpenWorktrees
    /// All Projects, whose filter matches no worktree.
    case noMatchingWorktrees
    /// The Needs Attention list and the menu bar's.
    case nothingNeedsAttention
    /// Notification history with nothing in it.
    case noNotifications
    /// Notification history, filtered to the agents' notifications.
    case noAgentNotifications
    /// Notification history, filtered to the commands' notifications.
    case noCommandNotifications
    /// Notification history, filtered to what is unread.
    case noUnreadNotifications
    /// The changes panel of a worktree whose agent has run no turn.
    case noTurns
    /// The changes panel of a folder Git does not track.
    case notGitRepository
    /// The changes panel, when Git did not answer about the folder.
    case changesUnavailable
    /// The review, whose scope has no changes.
    case noChangesInScope
    /// The review tab, whose record lost a snapshot.
    case incompleteRecord
    /// The review's prompt preview, with no comment.
    case noComments
    /// The review's file list, whose filter matches no file.
    case noMatchingFiles
    /// The command palette and the project menu, whose search matches
    /// nothing.
    case noResults
    /// The keyboard shortcut panel, whose search matches nothing.
    case noMatchingShortcuts
    /// The Settings window's search, which found nothing for `query`.
    case noSettingsFound(query: String)
    /// Project Settings' test commands, with every row removed.
    case noTestCommands
    /// Project Settings' files to copy, with no row.
    case noFilesToCopy
    /// The session area with no tab open. It draws only its commands
    /// (`EmptySessionHints`), as an empty editor area does, and VoiceOver
    /// says this message as the list's label.
    case noTabs
    /// The pane area, for the moment its tab has no pane to draw, with
    /// what to do: the key New Tab has now, `nil` when it has none.
    case noOpenTab(newTabShortcut: String?)
    /// The pane area of a window whose scratch tabs another window draws.
    case scratchElsewhere

    /// One of each, for the tests that read every empty state's words.
    static let inventory: [EmptyState] = [
        .noProjects, .noWorktreeSelected, .noOpenWorktrees, .noMatchingWorktrees, .nothingNeedsAttention,
        .noNotifications, .noAgentNotifications, .noCommandNotifications, .noUnreadNotifications,
        .noTurns, .notGitRepository, .changesUnavailable,
        .noChangesInScope, .incompleteRecord, .noComments, .noMatchingFiles,
        .noResults, .noMatchingShortcuts, .noSettingsFound(query: "font"),
        .noTestCommands, .noFilesToCopy,
        .noTabs, .noOpenTab(newTabShortcut: "⌘T"), .noOpenTab(newTabShortcut: nil), .scratchElsewhere
    ]

    // MARK: - Words

    /// What is absent, in the surface's own words.
    func message(locale: Locale) -> String {
        messageResource.resolved(in: locale)
    }

    /// How the surface fills, or what the person can do; `nil` for a state
    /// the message says enough of.
    func description(locale: Locale) -> String? {
        switch self {
        case .noOpenWorktrees:
            LocalizedStringResource(
                "Worktrees with a tab open or something that needs attention appear here.",
                comment: "All Projects, empty: which worktrees fill it"
            ).resolved(in: locale)
        case .noNotifications:
            LocalizedStringResource(
                "Agent responses and completed commands appear here.",
                comment: "Notification history, empty: what fills it"
            ).resolved(in: locale)
        case .notGitRepository:
            LocalizedStringResource(
                "Changes in this folder can’t be tracked.",
                comment: "Changes panel, empty: why a folder Git does not track lists no turns"
            ).resolved(in: locale)
        case .incompleteRecord:
            LocalizedStringResource(
                "A turn’s record is missing a snapshot, so its changes can’t be shown.",
                comment: "Review tab, empty: why a record that lost a snapshot shows no diff"
            ).resolved(in: locale)
        case let .noSettingsFound(query):
            query
        case let .noOpenTab(newTabShortcut):
            WorktreeText.emptyPaneDetail(newTabShortcut: newTabShortcut).resolved(in: locale)
        default:
            nil
        }
    }

    /// What VoiceOver reads of the state, as one element: the message,
    /// then the description, as two sentences.
    func spoken(locale: Locale) -> String {
        let message = message(locale: locale)
        guard let description = description(locale: locale) else { return message }
        return LocalizedStringResource(
            "emptyState.spoken",
            defaultValue: "\(message). \(description)",
            comment: "VoiceOver, an empty list or panel: its message, then its description; arguments: the message, the description"
        ).resolved(in: locale)
    }

    private var messageResource: LocalizedStringResource {
        switch self {
        case .noWorktreeSelected:
            LocalizedStringResource("No Worktree Selected", comment: "Empty state: the changes panel, the window has no worktree selected")
        case .noProjects:
            LocalizedStringResource("No Projects", comment: "Empty state: the sidebar or All Projects, no project has been added")
        case .noOpenWorktrees:
            LocalizedStringResource("No Open Worktrees", comment: "Empty state: All Projects, no worktree has a tab open")
        case .noMatchingWorktrees:
            LocalizedStringResource("No Matching Worktrees", comment: "Empty state: All Projects' filter matches no worktree")
        case .nothingNeedsAttention:
            LocalizedStringResource("Nothing Needs Attention", comment: "Empty state: the Needs Attention list has nothing in it")
        case .noNotifications:
            LocalizedStringResource("No Notifications", comment: "Empty state: notification history has nothing in it")
        case .noAgentNotifications:
            LocalizedStringResource("No Agent Notifications", comment: "Empty state: notification history, Agents matched nothing")
        case .noCommandNotifications:
            LocalizedStringResource("No Command Notifications", comment: "Empty state: notification history, Commands matched nothing")
        case .noUnreadNotifications:
            LocalizedStringResource("No Unread Notifications", comment: "Empty state: notification history, Unread matched nothing")
        case .noTurns:
            LocalizedStringResource("No Turns", comment: "Empty state: the changes panel, the agent has run no turn here")
        case .notGitRepository:
            LocalizedStringResource("Not a Git Repository", comment: "Empty state: the changes panel, the worktree is not a Git repository")
        case .changesUnavailable:
            LocalizedStringResource("Couldn’t Get the Changes", comment: "Empty state: the changes panel, Git did not answer")
        case .noChangesInScope:
            LocalizedStringResource("No Changes in This Scope", comment: "Empty state: the review, the scope read has no changes")
        case .incompleteRecord:
            LocalizedStringResource("Incomplete Record", comment: "Empty state: the review tab, a turn's record lost one of its snapshots")
        case .noComments:
            LocalizedStringResource("No Comments", comment: "Empty state: the review's prompt preview has no comment")
        case .noMatchingFiles:
            LocalizedStringResource("No Matching Files", comment: "Empty state: the review's file list, the filter matches no file")
        case .noResults:
            LocalizedStringResource("No Results", comment: "Empty state: the command palette or the project menu found nothing")
        case .noMatchingShortcuts:
            LocalizedStringResource("No Matching Shortcuts", comment: "Empty state: the keyboard shortcut panel found nothing")
        case .noSettingsFound:
            LocalizedStringResource("No Settings Found", comment: "Empty state: the Settings window's search found nothing")
        case .noTestCommands:
            LocalizedStringResource("No Test Commands", comment: "Empty state: Project Settings, the test command list has no row")
        case .noFilesToCopy:
            LocalizedStringResource("No Files to Copy", comment: "Empty state: Project Settings, no file to copy")
        case .noTabs, .noOpenTab:
            LocalizedStringResource("No Tabs", comment: "Empty state: the session area has no tab open")
        case .scratchElsewhere:
            LocalizedStringResource("Scratch Is Open in Another Window", comment: "Empty state: another window draws the scratch tabs")
        }
    }
}
