// RowName.swift
// Weir — the one rule that names a sidebar row, wherever the row is named.

import Foundation

/// A row's name, the same in the sidebar, the session header, the
/// palette, the attention list, and a notification's place: a name the
/// person gave first, then the branch, then the row's first agent
/// conversation, then the folder. The branch comes before the
/// conversation because a row stands for a worktree: the branch stays put
/// and tells the project's worktrees apart, while a conversation's name is
/// often its first prompt, long and cut short, and the pane strip below
/// the header already names each conversation. A folder on a detached
/// HEAD has no branch, so its first conversation names it, and its folder
/// when no agent has run there. The tabs' own titles never name the row:
/// OSC 2 changes them with whatever the agent or the shell is doing.
struct RowName: Equatable, Sendable {
    /// Which of the four the name came from: a branch is cut in its middle
    /// where it does not fit, any other name at its end.
    enum Source: Equatable, Sendable {
        case manual
        case conversation
        case branch
        case folder
    }

    let text: String
    let source: Source

    /// The label the person gave, which the row's rename field starts
    /// from; `nil` for a row that goes by its branch, conversation, or
    /// folder, whose field starts empty, so that name is never mistaken
    /// for what the field edits.
    var label: String? {
        source == .manual ? text : nil
    }

    /// The first of the four that is there; an empty name counts as none,
    /// so clearing a name hands the row back to the next.
    static func make(manual: String?, conversation: String?, branch: String?, folder: String) -> Self {
        if let manual, !manual.isEmpty {
            return Self(text: manual, source: .manual)
        }
        if let branch, !branch.isEmpty {
            return Self(text: branch, source: .branch)
        }
        if let conversation, !conversation.isEmpty {
            return Self(text: conversation, source: .conversation)
        }
        return Self(text: folder, source: .folder)
    }

    /// The checkout to show beside this name wherever the row is named as
    /// one to choose (its second line in the sidebar, the worktree ▾, the
    /// Needs Attention list's place, all projects' cards): a name the
    /// person gave is a label on the row, not its branch, so the row still
    /// says which worktree it is. The branch says it, as it does on every
    /// row without a label; a checkout with no branch known says it by its
    /// folder, when there is one to show. `nil` for any other name, which
    /// is already the branch, the conversation, or the folder, so the row
    /// keeps the shape it has; and for a label that repeats what would be
    /// shown, compared without case.
    ///
    /// `repository` is the project's own folder name, which a worktree's
    /// folder starts with when Weir made it beside the project
    /// (`Project.resolvedWorktreeURL`). Any folder that starts with
    /// "<repository>-" and has more after it is shortened, wherever it is:
    /// the start is what most folders of one
    /// project share, and the tooltip keeps the name whole
    /// (`RowCheckout.shortened`).
    func checkoutBeside(branch: String?, folder: String?, repository: String? = nil) -> RowCheckout? {
        guard source == .manual else { return nil }
        let checkout: RowCheckout
        if let branch, !branch.isEmpty {
            checkout = RowCheckout(name: branch, shown: branch, isBranch: true)
        } else if let folder, !folder.isEmpty {
            checkout = RowCheckout(name: folder, shown: RowCheckout.shortened(folder, repository: repository), isBranch: false)
        } else {
            return nil
        }
        let repeatsName = [checkout.name, checkout.shown].contains { text.compare($0, options: .caseInsensitive) == .orderedSame }
        return repeatsName ? nil : checkout
    }
}

/// The branch, or the folder, a row the person labeled is shown with
/// (`RowName.checkoutBeside`).
struct RowCheckout: Equatable, Sendable {
    /// The branch, or the folder's name in full, for the tooltip and
    /// VoiceOver, where nothing is short of room.
    let name: String
    /// What the row's line and the places that offer the row show: the
    /// branch, or the folder less a leading "<project's folder name>-",
    /// when something follows it.
    let shown: String
    /// Whether this is the branch rather than the folder, for what
    /// VoiceOver calls it and whether the worktree ▾ still adds the
    /// branch.
    let isBranch: Bool

    /// `folder` less a leading "<repository>-", compared without case, as
    /// Weir names a worktree it makes beside the project
    /// ("duesmith-fix-tax-rounding" in duesmith is "fix-tax-rounding"):
    /// that start is the same on the project's every worktree, so it tells
    /// none apart, and it pushes the row's fact off its line. Whole when it
    /// has no such start, or when nothing would be left after it.
    static func shortened(_ folder: String, repository: String?) -> String {
        guard let repository, !repository.isEmpty,
              let prefix = folder.range(of: repository + "-", options: [.anchored, .caseInsensitive]),
              prefix.upperBound < folder.endIndex
        else { return folder }
        return String(folder[prefix.upperBound...])
    }
}
