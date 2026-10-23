// SidebarSection.swift
// Limpid — which of a project's three lists a sidebar row belongs in.

import Foundation

/// The three lists a project's rows fall into. The working rows are
/// listed in full; the other two fold into one line each, since what they
/// hold is not where the person works.
enum SidebarSection: Hashable, Sendable, CaseIterable {
    /// The folder, any other worktree Limpid made or the person opened, and
    /// any row with something open or waiting in it.
    case working
    /// A worktree whose pull request is merged or closed, with nothing open
    /// in it and nothing left uncommitted: done with, and safe to hide.
    case cleanable
    /// A worktree Git reports that nobody has opened, an agent's own as a
    /// rule.
    case other
}

/// Decides a row's section from values alone.
enum SidebarSectionRule {
    /// What the rule reads of one row.
    struct Facts: Equatable, Sendable {
        /// The project's own folder.
        var isMainFolder = false
        /// How the worktree came to be a row; `nil` when not known yet (a
        /// file from before admissions, before its first sync), which is
        /// read as one the person had, as every row was before.
        var admission: WorktreeAdmission?
        /// A tab is open in it.
        var hasTabs = false
        /// The attention list holds an item for it: a wait, a stop, an
        /// unread turn.
        var hasItems = false
        /// The window has it selected.
        var isSelected = false
        /// The state of the pull request on its branch; `nil` for none.
        var prState: PRState?
        /// Files changed and not committed; 0 when not known.
        var uncommittedFiles = 0
        /// Its folder is gone from disk.
        var isMissing = false
    }

    static func section(_ facts: Facts) -> SidebarSection {
        // The folder, a row whose folder went missing (which shows as
        // stopped until the person removes it), and the selected row are
        // always in sight: hiding them would hide what the person is on or
        // has to deal with.
        if facts.isMainFolder || facts.isMissing || facts.isSelected {
            return .working
        }
        // Something open or waiting keeps a row a working one, wherever it
        // came from.
        if facts.hasTabs || facts.hasItems {
            return .working
        }
        if isUnopened(admission: facts.admission, hasTabs: false) {
            return .other
        }
        let isFinished = facts.prState == .merged || facts.prState == .closed
        return isFinished && facts.uncommittedFiles == 0 ? .cleanable : .working
    }

    /// Whether a worktree is one Git only reported that nobody has opened:
    /// what puts it among the other worktrees, and what the places that
    /// cannot see the attention list or the window (the palette, the Git
    /// and forge readers) go by. A tab makes it a working row.
    static func isUnopened(admission: WorktreeAdmission?, hasTabs: Bool) -> Bool {
        admission == .discovered && !hasTabs
    }
}
