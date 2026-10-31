// SessionRowNavigation.swift
// Weir — ⌃⌘1…9 and ⌘[ ⌘] over the sidebar's working rows.

import Foundation

/// ⌃⌘n and ⌘[ ⌘]: they walk the window's working rows in the
/// order the sidebar shows them, in the sections it shows them in
/// (`SidebarPresentedSections`), so the third row in sight is the one ⌃⌘3
/// opens, held or not. The rows folded away are not counted; ⌘[ ⌘] go on to
/// the scratch row after the last, which ⌃⌘n does not count.
@MainActor
enum SessionRowNavigation {
    /// The rows ⌘[ ⌘] walk: the working rows, then scratch.
    static func rows(in window: ProjectWindowState, session: WorkspaceSession, sections: SidebarPresentedSections) -> [ContainerID] {
        workingRows(in: window, session: session, sections: sections) + [.loose]
    }

    /// The working rows of the window's project, as the sidebar lists them.
    static func workingRows(in window: ProjectWindowState, session: WorkspaceSession, sections: SidebarPresentedSections) -> [ContainerID] {
        guard let project = session.selections[window.id]?.projectID.flatMap({ session.project($0) }) else { return [] }
        return sections.ordered(project).filter { $0.section == .working }.map(\.row)
    }

    /// ⌃⌘n: the nth working row; nothing past the last.
    static func activate(at index: Int, in window: ProjectWindowState, session: WorkspaceSession, sections: SidebarPresentedSections) {
        let rows = workingRows(in: window, session: session, sections: sections)
        guard rows.indices.contains(index) else { return }
        session.setActiveContainer(rows[index], in: window.id, intent: .person)
    }

    /// Whether ⌃⌘`number` (counted from 1) has a row to open among
    /// `workingRowCount` working rows: the menu item for a number past the
    /// last is off, as the key does nothing there.
    nonisolated static func hasRow(number: Int, workingRowCount: Int) -> Bool {
        number >= 1 && number <= workingRowCount
    }

    /// ⌘] (`forward`) or ⌘[: the next or previous row, around the ends.
    static func cycle(forward: Bool, in window: ProjectWindowState, session: WorkspaceSession, sections: SidebarPresentedSections) {
        let rows = rows(in: window, session: session, sections: sections)
        let current = window.selection.activeContainerID
        guard let next = SessionRowNavigation.step(from: current, in: rows, forward: forward) else { return }
        session.setActiveContainer(next, in: window.id, intent: .person)
    }

    /// The row one step from `current`, wrapping around; the first (or last)
    /// row when `current` is not listed. Pure, so the
    /// order is tested without a window.
    nonisolated static func step(from current: ContainerID, in rows: [ContainerID], forward: Bool) -> ContainerID? {
        guard !rows.isEmpty else { return nil }
        guard let index = rows.firstIndex(of: current) else {
            return forward ? rows.first : rows.last
        }
        let next = (index + (forward ? 1 : -1) + rows.count) % rows.count
        return rows[next]
    }

    /// ↑ and ↓ in the sidebar while it has the keyboard: the next or
    /// previous line, a fold line included, stopping at the ends; from no
    /// line, the first or the last.
    nonisolated static func keyboardStep<Line: Equatable>(from current: Line?, in lines: [Line], forward: Bool) -> Line? {
        guard !lines.isEmpty else { return nil }
        guard let current, let index = lines.firstIndex(of: current) else {
            return forward ? lines.first : lines.last
        }
        return lines[forward ? min(index + 1, lines.count - 1) : max(index - 1, 0)]
    }
}
