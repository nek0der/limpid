// SelectionIntent.swift
// Limpid — why a selection is written, and where it lands.

import Foundation

/// Why a window's selection is written. Every write names one, so
/// a way into the selection that is not the person's cannot pass for
/// theirs by leaving an argument out. The intent also decides where the
/// write lands (`WorkspaceSession.window(for:askedOf:intent:)`): only the
/// person's choice brings a window forward or takes it to another
/// project, since only they know where their keys should go next.
///
/// The person's choice is the only intent that takes the scratch tabs to a
/// window: they draw in one window at a time, and the window that last
/// chose them keeps them (`WorkspaceSession.scratchOwnerWindowID`). A switch
/// of project may record the window already drawing them as their keeper,
/// so a window that comes onto a scratch tab, back to one it left or moved
/// there because its project was removed, does not take them; that moves
/// no scratch tab anywhere (`WorkspaceSession.keepScratch`).
enum SelectionIntent: Equatable, Sendable {
    /// The person chose it: a click, a key, a menu item, a jump. Lands in
    /// the window asked, switched in place to the project chosen, or in
    /// the window that already shows that project, which is brought
    /// forward (`WorkspaceSession.projectSwitching`).
    case person
    /// What a window showed went away (a tab closed or moved, a worktree
    /// or project removed or hidden), or what it showed is put
    /// back (a restore, the tab made at launch so a window has one to
    /// show). The window is moved on, not chosen for: within the project it
    /// shows, never forward and never to another project. What would take
    /// it to another project lands in that project's view instead
    /// (`SelectionTarget.memory`).
    case repair
    /// Work the person started finished while they may have moved on: a
    /// setup that ends behind them, an action that resumes after a wait
    /// once they no longer show the row they asked from
    /// (`WorkspaceSession.intentAfterWait(from:)`). No shown window's
    /// selection changes: their keys would reach a terminal they did not
    /// choose. The hidden window that shows the project, else the
    /// project's view, takes it instead: an empty row asked for (the new
    /// row of a worktree) is selected there, and a tab only over a row that
    /// shows none, as in a shown window. Otherwise only the row's last tab
    /// moves.
    case behind

    /// Whether a write with this intent moves the scratch tabs to its
    /// window: only the person's choice does.
    var claimsScratch: Bool {
        self == .person
    }
}

/// Where the person was as they asked for something that waits
/// (`WorkspaceSession.waitOrigin(in:)`): the window, the project and row it
/// showed, and whether it was shown, so a window hidden during the wait
/// reads as left and one hidden before it does not
/// (`WorkspaceSession.intentAfterWait(from:)`). The project as well as the
/// row: a scratch tab is a row of no project, which a window keeps across
/// a switch to another project.
struct WaitOrigin: Equatable, Sendable {
    let window: WindowID
    let projectID: UUID?
    let container: ContainerID
    let wasShown: Bool
}

@MainActor
extension WorkspaceSession {
    /// Where the person was as they asked for something that waits (a
    /// worktree made, a folder resolved, an insert sent, a step stopped),
    /// to compare once the wait is over (`intentAfterWait(from:)`).
    /// `nil` for a window the session does not know.
    func waitOrigin(in window: WindowID) -> WaitOrigin? {
        selection(window).map {
            WaitOrigin(
                window: $0.windowID,
                projectID: $0.shownProjectID,
                container: $0.activeContainerID,
                wasShown: !hiddenWindowIDs.contains($0.windowID)
            )
        }
    }

    /// The intent of a write the person asked for before a wait, made once
    /// the wait is over: still theirs while the window is there and on the
    /// row it showed when they asked, in the project it showed; else work
    /// that ends behind them. A person who moved to another row, even of
    /// the same project, is typing somewhere else by then. So is
    /// one whose window switched to another project and came to a scratch
    /// tab there: the row is the same, the project is not.
    ///
    /// Hiding the window during the wait is leaving it. One that was
    /// already hidden as they asked is not left: the menu bar and the File
    /// menu ask of the command target, the primary when every window is
    /// hidden, and the answer is to show it again.
    func intentAfterWait(from origin: WaitOrigin?) -> SelectionIntent {
        guard let origin, let selection = selection(origin.window),
              selection.activeContainerID == origin.container,
              selection.shownProjectID == origin.projectID,
              !origin.wasShown || !hiddenWindowIDs.contains(origin.window)
        else { return .behind }
        return .person
    }
}

/// Where a selection is written (`WorkspaceSession.window(for:askedOf:intent:)`).
@MainActor
enum SelectionTarget {
    /// A window's selection.
    case window(WindowSelection)
    /// The view a project keeps while no window shows it
    /// (`WorkspaceSession.projectViews`). A project with no view gets none
    /// from such a write: only its rows' last tabs move, so the first
    /// window to show it still takes it as a first visit.
    case memory(projectID: UUID)
}
