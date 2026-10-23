// WorktreeDropdownText.swift
// Limpid — the worktree dropdown's words: a checkout's branch and folder, how many agents run there, and what VoiceOver reads.

import Foundation

enum WorktreeDropdownText {
    /// A checkout's second line: its branch, when the name above is not
    /// already the branch (a name the person gave, or a conversation's),
    /// so the dropdown still says which checkout it is; then its
    /// folder; then "Agents 2" when more than one agent runs in it, since
    /// two agents in one folder edit the same files. One agent goes without
    /// saying.
    ///
    /// A checkout the person named starts with the folder its sidebar row
    /// shows beside that name (`shownFolder`, from
    /// `WorkspaceSession.rowFolder(of:)`), then the branch when it is not
    /// that folder, in place of the whole path, which the row's tooltip
    /// holds: the line then says which worktree it is as the sidebar does.
    static func detail(
        name: String,
        branch: String,
        folder: String,
        shownFolder: String? = nil,
        agentCount: Int,
        locale: Locale
    ) -> String {
        var parts: [String] = []
        if let shownFolder {
            parts.append(shownFolder)
            if !branch.isEmpty, branch != name, branch.compare(shownFolder, options: .caseInsensitive) != .orderedSame {
                parts.append(branch)
            }
        } else {
            if !branch.isEmpty, branch != name {
                parts.append(branch)
            }
            parts.append(folder)
        }
        if agentCount > 1 {
            parts.append(LocalizedStringResource(
                "Agents \(agentCount)",
                comment: "Worktree dropdown row: how many agents run in the checkout, when more than one"
            ).resolved(in: locale))
        }
        return AgentStatusText.joined(parts, locale: locale)
    }

    /// What VoiceOver reads for a checkout: its name, the state its glyph
    /// shows, the pull request its mark shows (number, state, and checks),
    /// and its second line.
    static func spokenLabel(name: String, row: SessionSidebarModel.Row?, detail: String, locale: Locale) -> String {
        AgentStatusText.spokenList(
            [
                name,
                row.map { SessionRowFactText.spokenState($0, locale: locale) } ?? "",
                AgentStatusText.spoken(detail, locale: locale)
            ],
            locale: locale
        )
    }
}
