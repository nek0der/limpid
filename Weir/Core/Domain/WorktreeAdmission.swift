// WorktreeAdmission.swift
// Weir — whether Weir made a worktree, the person opened it, or Git only reported it.

import Foundation

/// How a worktree came to be one of the project's rows. Only one that
/// Weir made or the person opened is a working row on its own: a
/// worktree an agent made for itself, which Git only reports, waits among
/// the other worktrees until the person opens it. Stored as its raw value
/// in `state.json` (`Worktree.admission`).
package enum WorktreeAdmission: String, Equatable, Sendable {
    /// Weir made it: New Worktree…, or a tab moved into a worktree the
    /// move suggestion added.
    case created
    /// The person opened it: chose its row, or opened a tab in it. So is a
    /// worktree that a file from before admissions were kept shows in use
    /// (`WorktreeAdmissionRule`).
    case opened
    /// Git reported it and nobody has opened it yet.
    case discovered
}

/// What Move to Other Worktrees took from a row, for its Undo: the admission
/// it had, `nil` for one not admitted yet.
package struct WorktreeRelease: Equatable, Sendable {
    package let previous: WorktreeAdmission?

    package init(
        previous: WorktreeAdmission?
    ) {
        self.previous = previous
    }
}

/// Admits a worktree that a `state.json` from before `admission` holds with
/// no admission. Use comes first: a worktree with a tab, a last tab,
/// or a window's selection is the person's, wherever an agent put it. Only
/// a worktree with none of them is placed by its path, as an agent's when
/// it sits where agents put theirs.
package enum WorktreeAdmissionRule {
    /// What the rule reads of one worktree, all of it values.
    package struct Facts: Equatable, Sendable {
        /// A tab is open in it.
        package var hasTabs = false
        /// It remembers a tab to restore (`Worktree.lastActiveTabID`): the
        /// person had one open there.
        package var hasLastActiveTab = false
        /// A window, or the view of a project no window shows, has it
        /// selected.
        package var isSelected = false
        /// The worktree's folder.
        package var path: String
        /// Its HEAD is detached: Git names no branch for it.
        package var isDetached = false
        /// The person's home folder, under which Codex keeps its worktrees.
        package var homePath: String

        package init(
            hasTabs: Bool = false,
            hasLastActiveTab: Bool = false,
            isSelected: Bool = false,
            path: String,
            isDetached: Bool = false,
            homePath: String
        ) {
            self.hasTabs = hasTabs
            self.hasLastActiveTab = hasLastActiveTab
            self.isSelected = isSelected
            self.path = path
            self.isDetached = isDetached
            self.homePath = homePath
        }
    }

    /// The admission of a worktree that has none recorded.
    package static func classify(_ facts: Facts) -> WorktreeAdmission {
        if facts.hasTabs || facts.hasLastActiveTab || facts.isSelected {
            return .opened
        }
        return isAgentPlaced(facts) ? .discovered : .opened
    }

    /// Whether the worktree sits where an agent puts the worktrees it makes
    /// for itself: under Claude's `.claude/worktrees/`, under Codex's
    /// `~/.codex/worktrees/<id>/`, in a folder named `agent-…`, or on a
    /// detached HEAD, which is how both leave one they made without a
    /// branch. A worktree Weir's own hook routed to the project's
    /// placement is not told apart here: it sits where Weir puts its own.
    static func isAgentPlaced(_ facts: Facts) -> Bool {
        let path = RepositoryPath.standardized(facts.path)
        if path.contains("/.claude/worktrees/") {
            return true
        }
        let codexRoot = RepositoryPath.standardized(facts.homePath) + "/.codex/worktrees"
        if RepositoryPath.contains(codexRoot, path), path != codexRoot {
            return true
        }
        let folder = (path as NSString).lastPathComponent
        return folder.hasPrefix("agent-") || facts.isDetached
    }
}
