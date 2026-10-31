// ProjectView.swift
// Weir — what a project showed when a window last left it, put back when a window shows it again.

import Foundation

/// What a project showed when a window last left it: its selected
/// container and tab, and the conversation the changes panel's filter
/// narrowed to. Put back
/// when a window shows the project again, whichever window that is, and
/// then forgotten: while a window shows the project, that window's
/// selection is the view (`WorkspaceSession.projectViews`).
///
/// The window's own state is not put back from here: its frame, full
/// screen, history, and its chrome, the sidebar's width and whether it is
/// shown, and the changes panel's width and whether it is open. Those stay
/// with the window as it shows another project, as a Finder window's
/// sidebar stays as it shows another folder: taken from the project, they
/// moved on every switch, and the terminal beside them redrew at another
/// width each time. A pane's focus is not here either; the tab keeps it.
///
/// Decoded field by field with defaults, as `WindowRecord` is, so a view a
/// later build wrote with fields this one lacks, or one written before a
/// field was added, still reads.
struct ProjectView: Codable, Equatable, Sendable {
    let projectID: UUID
    /// `.loose` when the window was on a scratch tab: the project stays
    /// shown in the sidebar there, and coming back returns to that tab.
    /// Also what a view that names no container reads as.
    var activeContainerID: ContainerID
    /// The tab the view was on; `nil` on a row with no tab (the scratch
    /// row of an empty project), and the project then opens on its last session.
    var activeTabID: UUID?
    /// The chrome of the window that left the project: written, and not
    /// laid out again as a window switches (`WindowSelection.apply(_:)`).
    /// The build before kept the chrome with the project and lays a
    /// switching window out from these, so they are written for that one
    /// build: going back to it does not open every project at the
    /// defaults (`docs/data-migration.md`). Read only for a window that has
    /// no record of its own at launch (`WorkspaceSession.restore(from:)`).
    var sidebarWidth = Double(SessionLayoutDefaults.sidebarWidth)
    var sidebarHidden = false
    var isChangesPanelPresented = false
    /// `nil` for the panel's default width.
    var changesPanelWidth: Double?
    /// The conversation the changes panel's filter narrows the timeline
    /// to, `nil` for all. Kept while the app runs, so a window coming back
    /// to the project finds the panel narrowed as it was left, and never
    /// written: a launch opens every panel on "All". A filter left on
    /// across a relaunch would hide the other conversations' turns that
    /// ended while the app was closed. An earlier build wrote the agent its
    /// switcher showed under `changesPanelAgent`; that was a choice of what
    /// to list, not a narrowing, and is not read.
    var changesPanelFilter: ConversationKey?

    private enum CodingKeys: String, CodingKey {
        case projectID, activeContainerID, activeTabID
        case sidebarWidth, sidebarHidden
        case isChangesPanelPresented, changesPanelWidth
    }
}

extension ProjectView {
    /// Kept in an extension so the memberwise initializer stays.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The one field a view means nothing without: one missing it does
        // not read, and is dropped on its own (`SessionSnapshot`).
        projectID = try c.decode(UUID.self, forKey: .projectID)
        // With no container named, the view's tab decides, and with no tab
        // either the project opens on its last session, as a window record
        // with none does: `.project` would pick the project's root row
        // even when it is empty and the sessions are in worktrees.
        // A group, which an earlier build could still leave a view on, reads
        // as the scratch tabs, where its tabs come back (`ContainerID`).
        activeContainerID = try c.decodeIfPresent(ContainerID.self, forKey: .activeContainerID) ?? .loose
        activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            ?? Double(SessionLayoutDefaults.sidebarWidth)
        sidebarHidden = try c.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
        isChangesPanelPresented = try c.decodeIfPresent(Bool.self, forKey: .isChangesPanelPresented) ?? false
        changesPanelWidth = try c.decodeIfPresent(Double.self, forKey: .changesPanelWidth)
    }
}

extension WindowSelection {
    /// What this window shows of `projectID`, to keep for the project when
    /// the window leaves it, with the window's chrome for the build before
    /// (`ProjectView.sidebarWidth`).
    func projectView(for projectID: UUID) -> ProjectView {
        ProjectView(
            projectID: projectID,
            activeContainerID: activeContainerID,
            activeTabID: activeTabID,
            sidebarWidth: Double(sidebarWidth),
            sidebarHidden: sidebarHidden,
            isChangesPanelPresented: isChangesPanelPresented,
            changesPanelWidth: changesPanelWidth.map(Double.init),
            changesPanelFilter: changesPanelFilter
        )
    }

    /// Takes what `view` kept of its project beside what it showed: the
    /// conversation the changes panel's filter narrowed to. The window's chrome stays as it is
    /// (`ProjectView`). What the view showed is put back by
    /// `WorkspaceSession`, which checks it against the session first: the
    /// tab may have closed or moved since.
    func apply(_ view: ProjectView) {
        changesPanelFilter = view.changesPanelFilter
    }

    /// Lays this window's chrome out as `view`'s window had it, for a
    /// window with no record of its own to take it from
    /// (`WorkspaceSession.restore(from:)`).
    func applyChrome(of view: ProjectView) {
        sidebarWidth = CGFloat(view.sidebarWidth)
        sidebarHidden = view.sidebarHidden
        isChangesPanelPresented = view.isChangesPanelPresented
        changesPanelWidth = view.changesPanelWidth.map { CGFloat($0) }
    }
}
