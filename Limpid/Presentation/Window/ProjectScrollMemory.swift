// ProjectScrollMemory.swift
// Limpid — where a project's lists were scrolled, kept while no window shows it and brought back as a window switches to it.

import Foundation

/// Where a window had a project's changes panel scrolled as it left the
/// project: the turn at the top of its list, with the turn
/// selected in it then. The sidebar is not one of the project's lists: it
/// lists every project, so it stays where it is through a switch, as the
/// window's own (`ProjectWindowState.sidebarVisibleLines`). Kept by the
/// registry for the project (`WindowRegistry.scrollMemories`) while no
/// window shows it, as the project's view is (`WorkspaceSession.projectViews`),
/// and handed to the window that shows it next, once, right after its
/// switch (`ProjectScrollRestore`). Never saved: a position means nothing
/// once the rows are drawn again at launch. The review tab's place in its
/// diff goes with the tab instead (`ParkedReview.Tab.scroll`), as the tab
/// can come back to another window, or wait for a row rather than a project.
///
/// Not held in the views: a window switches projects in place, so the
/// view that drew the project's turns draws another's, and only this brings
/// the place back.
struct ProjectScrollMemory: Equatable {
    /// The changes panel's place: the turn at the top of its list.
    var changes: ChangesPlace?

    /// Whether there is nothing to bring back.
    var isEmpty: Bool {
        changes == nil
    }

    /// A list's place: the row at its top, and the row selected in it as
    /// the window left. A selection the same on return says the person
    /// left the list as it was; one moved meanwhile says where to look.
    struct Place<ID: Hashable>: Equatable {
        let row: ID
        let selected: ID?
    }

    /// The changes panel's place, with the agent whose turns the list
    /// showed: another agent's list is another list.
    struct ChangesPlace: Equatable {
        let conversation: ConversationKey?
        let place: Place<TurnID>
    }

    /// Where a list goes as its project comes back (`target`).
    enum Target<ID: Hashable>: Equatable {
        /// The row remembered, back at the top as it was.
        case remembered(ID)
        /// The selected row, in sight.
        case selected(ID)
    }

    /// Where a list of `rows`, in their order from the top, goes as its
    /// project comes back to a window, `selected` being the row the window
    /// selects in it now.
    ///
    /// The place remembered comes back as it was while the list still has
    /// its row and the selection is the one the window left with: nothing
    /// the person did since is to be shown, so the list is as they left it,
    /// whatever it shows of the selected row. A selection that moved while
    /// the project was away (a row the person was taken to with the switch,
    /// ⌘J or a notification, or one selected behind them) is what the window
    /// now shows of the project, so the list shows it. So does a list whose
    /// remembered row is gone (a session closed, a turn deleted), or one
    /// with nothing remembered: a project shown for the first time. A
    /// selected row the list does not have (the scratch row) leaves the
    /// remembered place. `nil` when there is nothing to go to: the list is
    /// left where it is.
    static func target<ID: Hashable>(remembered place: Place<ID>?, selected: ID?, in rows: [ID]) -> Target<ID>? {
        let isRememberedListed = place.map { rows.contains($0.row) } ?? false
        let isSelectedListed = selected.map(rows.contains) ?? false
        if let place, isRememberedListed, place.selected == selected || !isSelectedListed {
            return .remembered(place.row)
        }
        if let selected, isSelectedListed {
            return .selected(selected)
        }
        return nil
    }

    /// Whether a list going to `target` goes to its very top: the row
    /// remembered is its first, which the list reports as its top while it
    /// stands at its top, inset included. Put back at the top of the
    /// viewport, that row would lose the inset above it on every return.
    static func goesToTop<ID: Hashable>(_ target: Target<ID>?, in rows: [ID]) -> Bool {
        guard case let .remembered(row) = target else { return false }
        return row == rows.first
    }

    /// The turn the changes panel has selected: the first, from the top,
    /// of those the review tab reads (ringed in the list), else the one
    /// the list opens on (`ChangesPanelModel.TurnList.scrollTarget`).
    static func selectedTurn(rows: [TurnID], shownInReview: Set<TurnID>, opensOn: TurnID?) -> TurnID? {
        rows.first { shownInReview.contains($0) } ?? opensOn
    }

    /// Where the changes panel's list of `conversation`'s turns goes as
    /// its project comes back (`target`): a place remembered of another
    /// agent's list is no place in this one.
    static func changesTarget(
        remembered: ChangesPlace?,
        conversation: ConversationKey?,
        rows: [TurnID],
        selected: TurnID?
    ) -> Target<TurnID>? {
        let place = remembered.flatMap { $0.conversation == conversation ? $0.place : nil }
        return target(remembered: place, selected: selected, in: rows)
    }
}

/// What the changes panel reports of where it stands, as it scrolls
/// (`ProjectWindowState.scrollPlace`): the turn at its top, and its
/// selected turn, which only the panel can work out.
struct ProjectScrollReport: Equatable {
    var changesConversation: ConversationKey?
    var changesTurn: TurnID?
    var changesSelected: TurnID?
}

/// Which list of a window a restore is for: the changes panel's, the one
/// list a project keeps.
enum ProjectScrollList: Hashable {
    case changes
}

/// What a window brings back of a project's lists right after it switched
/// to the project in place (`WindowRegistry.windowDidSwitchProject`): each
/// list on screen as the window lands takes its part once, as it is drawn
/// for the project (`ProjectWindowState.pendingScrollLists`), and none
/// later. A list not on screen as the window lands (the panel closed)
/// takes none: shown later, it is a list opened, not one
/// coming back, and its part goes on being kept for the project
/// (`ProjectScrollMemories.remember`).
struct ProjectScrollRestore: Equatable {
    /// Tells this switch's restore from the one before, when both bring
    /// back the same positions.
    let id = UUID()
    /// The project switched to.
    let projectID: UUID
    /// What the project kept, empty for one shown for the first time.
    let memory: ProjectScrollMemory
}

/// The positions each project kept as windows left it, by project, until a
/// window shows the project again (`WindowRegistry.scrollMemories`).
@MainActor
struct ProjectScrollMemories {
    /// Like the project's view (`WorkspaceSession.projectViews`), a key is a
    /// project no window shows: the window that shows it holds its
    /// positions in its lists.
    private(set) var byProject: [UUID: ProjectScrollMemory] = [:]

    /// Keeps where `window` had the lists of `projectID` scrolled, as it
    /// leaves the project or closes, with the turn selected in
    /// it then (`ProjectScrollMemory.Place`): the changes panel's top turn
    /// while the panel is open. A list that reported nothing in this visit (hidden, closed,
    /// never drawn: the window went on before drawing it) passes on what the
    /// project kept of it, rather than drop a place it never had the chance
    /// to show. What the window's lists report from now on is the next
    /// project's, so the window starts with nothing, and a restore still
    /// pending for the project left goes. A project `session` no longer has
    /// keeps nothing.
    mutating func remember(_ window: ProjectWindowState, leaving projectID: UUID?, in session: WorkspaceSession) {
        let report = window.scrollPlace
        let carried = window.scrollRestore.flatMap { $0.projectID == projectID ? $0.memory : nil }
        window.scrollPlace = ProjectScrollReport()
        window.pendingScrollLists = []
        if window.scrollRestore != nil {
            window.scrollRestore = nil
        }
        guard let projectID, session.project(projectID) != nil else { return }
        let selection = window.selection
        var memory = ProjectScrollMemory()
        if selection.isChangesPanelPresented {
            if let turn = report.changesTurn {
                memory.changes = ProjectScrollMemory.ChangesPlace(
                    conversation: report.changesConversation,
                    place: ProjectScrollMemory.Place(row: turn, selected: report.changesSelected)
                )
            } else {
                memory.changes = carried?.changes
            }
        }
        byProject[projectID] = memory.isEmpty ? nil : memory
    }

    /// Hands `window`, which has just switched to `projectID` in place, what
    /// the project kept of where its lists were (`remember`), once: each
    /// list on screen as the window lands takes its part as it draws the
    /// project's rows (`ProjectWindowState.takeScrollRestore`). The memory
    /// is the window's from now on, in its lists. A project shown for the
    /// first time brings back nothing, and its lists go to their selected
    /// rows. Called once the window is laid out for the project.
    mutating func bringBack(_ projectID: UUID?, to window: ProjectWindowState) {
        guard let projectID else { return }
        window.pendingScrollLists = window.selection.isChangesPanelPresented ? [.changes] : []
        window.scrollRestore = ProjectScrollRestore(
            projectID: projectID,
            memory: byProject.removeValue(forKey: projectID) ?? ProjectScrollMemory()
        )
    }

    /// Lets go of the positions of the projects `isGone` names: a removed
    /// project's go with its view.
    mutating func forget(_ isGone: (UUID) -> Bool) {
        byProject = byProject.filter { !isGone($0.key) }
    }
}
