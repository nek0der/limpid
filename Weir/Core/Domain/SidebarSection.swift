// SidebarSection.swift
// Weir — which of a project's lists a sidebar row belongs in.

import Foundation

/// The lists a project's rows fall into. The working rows are listed in
/// full; the others fold into one line each, since what they hold is not
/// where the person works.
package enum SidebarSection: Hashable, Sendable, CaseIterable {
    /// The folder, any other worktree Weir made or the person opened, and
    /// any row with something open or waiting in it.
    case working
    /// A worktree whose folder is gone from disk, with nothing open in it:
    /// nothing can be done in it but remove it, so it waits under its own
    /// line rather than among the rows the person works in.
    case missing
    /// A worktree whose pull request is merged or closed, with nothing open
    /// in it and nothing left uncommitted: done with, and safe to delete,
    /// as its branch is kept.
    case cleanable
    /// A worktree Git reports that nobody has opened, an agent's own as a
    /// rule.
    case other

    /// The sections that fold into a line, in the order the sidebar lists
    /// them under the working rows.
    package static let folded: [SidebarSection] = [.missing, .cleanable, .other]
}

/// Decides a row's section from values alone.
package enum SidebarSectionRule {
    /// What the rule reads of one row.
    package struct Facts: Equatable, Sendable {
        /// The project's own folder.
        package var isMainFolder = false
        /// How the worktree came to be a row; `nil` when not known yet (a
        /// file from before admissions, before its first sync), which is
        /// read as one the person had, as every row was before.
        package var admission: WorktreeAdmission?
        /// A tab is open in it.
        package var hasTabs = false
        /// The attention list holds an item for it: a wait, a stop, an
        /// unread turn.
        package var hasItems = false
        /// The window has it selected.
        package var isSelected = false
        /// The state of the pull request on its branch; `nil` for none.
        package var prState: PRState?
        /// Files changed and not committed; 0 when not known.
        package var uncommittedFiles = 0
        /// Its folder is gone from disk.
        package var isMissing = false

        package init(
            isMainFolder: Bool = false,
            admission: WorktreeAdmission? = nil,
            hasTabs: Bool = false,
            hasItems: Bool = false,
            isSelected: Bool = false,
            prState: PRState? = nil,
            uncommittedFiles: Int = 0,
            isMissing: Bool = false
        ) {
            self.isMainFolder = isMainFolder
            self.admission = admission
            self.hasTabs = hasTabs
            self.hasItems = hasItems
            self.isSelected = isSelected
            self.prState = prState
            self.uncommittedFiles = uncommittedFiles
            self.isMissing = isMissing
        }
    }

    package static func section(_ facts: Facts) -> SidebarSection {
        // The folder and the selected row are always in sight: hiding them
        // would hide what the person is on.
        if facts.isMainFolder || facts.isSelected {
            return .working
        }
        // A missing folder's own stop is an item for it, so it is read
        // before the items. One with a tab stays a working row: the tab is
        // still where the person was.
        if facts.isMissing, !facts.hasTabs {
            return .missing
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
    package static func isUnopened(admission: WorktreeAdmission?, hasTabs: Bool) -> Bool {
        admission == .discovered && !hasTabs
    }
}
