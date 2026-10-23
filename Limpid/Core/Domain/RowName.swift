// RowName.swift
// Limpid — the one rule that names a sidebar row, wherever the row is named.

import Foundation

/// A row's name, the same in the sidebar, the session header, the
/// palette, the attention list, and a notification's place: a name the
/// person gave first, then the row's first agent conversation, then the
/// branch, then the folder. A folder on a detached HEAD has no branch, so
/// it is named by its folder. The tabs' own titles never name the row:
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

    /// The first of the four that is there; an empty name counts as none,
    /// so clearing a name hands the row back to the next.
    static func make(manual: String?, conversation: String?, branch: String?, folder: String) -> Self {
        if let manual, !manual.isEmpty {
            return Self(text: manual, source: .manual)
        }
        if let conversation, !conversation.isEmpty {
            return Self(text: conversation, source: .conversation)
        }
        if let branch, !branch.isEmpty {
            return Self(text: branch, source: .branch)
        }
        return Self(text: folder, source: .folder)
    }

    /// The folder to show beside this name wherever the row is named as
    /// one to choose (its second line in the sidebar, the worktree ▾, the
    /// Needs Attention list's place, all projects' cards): a name the
    /// person gave no longer says which worktree the row is, as its
    /// branch did. `nil` for any other name, which is the branch or the
    /// folder or says neither, so the row keeps the shape it has; and for
    /// a given name that is the folder, whole or shortened, compared
    /// without case, which would only say it again.
    ///
    /// `repository` is the project's own folder name, which a worktree's
    /// folder starts with when Limpid made it beside the project
    /// (`Project.resolvedWorktreeURL`). Any folder that starts with
    /// "<repository>-" and has more after it is shortened, wherever it is:
    /// the start is what most folders of one
    /// project share, and the tooltip keeps the name whole
    /// (`RowFolder.shortened`).
    func folderBeside(_ folder: String, repository: String? = nil) -> RowFolder? {
        guard source == .manual, !folder.isEmpty else { return nil }
        let shown = RowFolder.shortened(folder, repository: repository)
        let repeatsName = [folder, shown].contains { text.compare($0, options: .caseInsensitive) == .orderedSame }
        return repeatsName ? nil : RowFolder(name: folder, shown: shown)
    }
}

/// The folder a row the person named is shown with (`RowName.folderBeside`).
struct RowFolder: Equatable, Sendable {
    /// The folder's name in full, for the tooltip and VoiceOver, where
    /// nothing is short of room.
    let name: String
    /// What the row's line and the places that offer the row show: the
    /// name less a leading "<project's folder name>-", when something
    /// follows it.
    let shown: String

    /// `folder` less a leading "<repository>-", compared without case, as
    /// Limpid names a worktree it makes beside the project
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
