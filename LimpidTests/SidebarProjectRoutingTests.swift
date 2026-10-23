// SidebarProjectRoutingTests.swift
// Limpid — what the sidebar's headers and other projects' rows do across windows: one window per project, and the work
// goes on where it is shown.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

/// The sidebar lists every project, so its headers and rows reach projects
/// other windows show. A header's ＋ and a row's Answer… on such a project
/// bring that window forward and go on there; any other project's row
/// switches this window in place. No project is ever shown by two windows.
@MainActor
struct SidebarProjectRoutingTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - A header's ＋

    @Test func thePlus_ofAProjectAnotherWindowShows_opensTheSheetThere_andBringsItForward() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)

        SupervisionWindowActions.newWorktree(
            inProject: fixture.b.id,
            from: fixture.primary,
            session: fixture.session,
            registry: fixture.registry
        )

        #expect(other.newSession?.projectID == fixture.b.id)
        #expect(fixture.primary.newSession == nil)
        #expect(fixture.presenter.shown == [other.id])
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    /// Hidden with ⇧⌘W, the window that shows the project still takes its
    /// sheet, shown again.
    @Test func thePlus_ofAProjectAHiddenWindowShows_bringsThatWindowBack() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        fixture.registry.hide(other.id)

        SupervisionWindowActions.newWorktree(
            inProject: fixture.b.id,
            from: fixture.primary,
            session: fixture.session,
            registry: fixture.registry
        )

        #expect(other.newSession?.projectID == fixture.b.id)
        #expect(fixture.presenter.shown == [other.id])
        #expect(!other.isHidden)
        fixture.expectInvariants()
    }

    /// Another project no window shows is worked on here: its sheet opens
    /// in this window, and the worktree it makes then switches this window
    /// to that project.
    @Test func thePlus_ofAProjectNoWindowShows_opensTheSheetHere_forThatProject() {
        let fixture = Fixture()

        SupervisionWindowActions.newWorktree(
            inProject: fixture.c.id,
            from: fixture.primary,
            session: fixture.session,
            registry: fixture.registry
        )

        #expect(fixture.primary.newSession?.projectID == fixture.c.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id, "the sheet switches nothing")
        #expect(fixture.presenter.shown.isEmpty)
    }

    /// A window that shows nothing lists every header, ＋ included: the
    /// sheet opens there, from the window's root, for that project.
    @Test func thePlus_inAWindowThatShowsNothing_opensTheSheetThere() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        #expect(empty.selection.isChoosingProject)

        SupervisionWindowActions.newWorktree(
            inProject: fixture.c.id,
            from: empty,
            session: fixture.session,
            registry: fixture.registry
        )

        #expect(empty.newSession?.projectID == fixture.c.id)
        #expect(empty.selection.isChoosingProject, "the sheet switches nothing")
    }

    /// A ＋ whose sheet never came up (the window could not show it) stands
    /// in the way of no later ＋, and a later one is the sheet shown.
    @Test func aPlusWhoseSheetNeverCameUp_doesNotRefuseTheNext() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        SupervisionWindowActions.newWorktree(inProject: fixture.c.id, from: empty, session: fixture.session, registry: fixture.registry)

        SupervisionWindowActions.newWorktree(inProject: fixture.b.id, from: empty, session: fixture.session, registry: fixture.registry)

        #expect(empty.newSession?.projectID == fixture.b.id)
    }

    /// Asked for under another sheet (project settings, the clipboard
    /// confirmation), the ＋ opens nothing. One asked for just before such
    /// a sheet took the window, and never up, is dropped as that sheet
    /// goes, rather than opening then.
    @Test func aPlusUnderAnotherSheet_opensNothing_thenOrLater() {
        let fixture = Fixture()
        let window = fixture.primary
        window.hasAttachedSheet = true
        SupervisionWindowActions.newWorktree(inProject: fixture.c.id, from: window, session: fixture.session, registry: fixture.registry)
        #expect(window.newSession == nil)

        window.hasAttachedSheet = false
        SupervisionWindowActions.newWorktree(inProject: fixture.c.id, from: window, session: fixture.session, registry: fixture.registry)
        #expect(window.newSession?.projectID == fixture.c.id)
        // Another sheet takes the window before ours comes up, then goes.
        window.hasAttachedSheet = true
        window.hasAttachedSheet = false
        window.newWorktreeSheet.coverEnded()

        #expect(window.newSession == nil)
    }

    // MARK: - Answer…

    @Test func answer_onARowAnotherWindowShows_opensThatWindowsCard_andBringsItForward() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let approvals = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        approvals.receive([request])

        SupervisionWindowActions.answer(
            request,
            inProject: fixture.b.id,
            from: fixture.primary,
            approvals: approvals,
            session: fixture.session,
            registry: fixture.registry
        )

        #expect(other.approvalCard.presentedApproval(in: approvals)?.id == request.id)
        #expect(!fixture.primary.approvalCard.isOpen(in: approvals))
        #expect(fixture.presenter.shown == [other.id])
    }

    @Test func answer_onAnyOtherRow_opensThisWindowsCard() {
        let fixture = Fixture()
        let approvals = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        approvals.receive([request])

        SupervisionWindowActions.answer(
            request,
            inProject: fixture.c.id,
            from: fixture.primary,
            approvals: approvals,
            session: fixture.session,
            registry: fixture.registry
        )

        #expect(fixture.primary.approvalCard.presentedApproval(in: approvals)?.id == request.id)
        #expect(fixture.presenter.shown.isEmpty)
    }

    // MARK: - A row's menu

    /// Open Changes Panel on a row of a project another window shows opens
    /// that window's panel on the row, brought forward, and leaves this
    /// window's as it was.
    @Test func openChangesPanel_onARowAnotherWindowShows_opensThatWindowsPanel() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let row = ContainerID.project(fixture.b.id)

        SupervisionWindowActions.openChangesPanel(row, from: fixture.primary, session: fixture.session, registry: fixture.registry)

        #expect(other.selection.isChangesPanelPresented)
        #expect(other.selection.activeContainerID == row)
        #expect(!fixture.primary.selection.isChangesPanelPresented)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.presenter.shown.contains(other.id))
        fixture.expectInvariants()
    }

    @Test func openChangesPanel_onAnotherProjectsRow_switchesThisWindowAndOpensItsPanel() {
        let fixture = Fixture()
        let row = ContainerID.project(fixture.c.id)

        SupervisionWindowActions.openChangesPanel(row, from: fixture.primary, session: fixture.session, registry: fixture.registry)

        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        #expect(fixture.primary.selection.isChangesPanelPresented)
        fixture.expectInvariants()
    }

    // MARK: - The person's choice unfolds

    /// A row the person chooses has its header opened, in the window that
    /// shows it; a repair opens none.
    @Test func thePersonsChoice_opensItsHeader_butARepairDoesNot() throws {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(
            projectOrder: [fixture.a.id, fixture.b.id, fixture.c.id],
            collapsedProjects: [fixture.a.id]
        )
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .created)
        let row = ContainerID.worktree(projectID: fixture.a.id, worktreeID: worktree.id)

        fixture.session.setActiveContainer(row, in: fixture.primary.id, intent: .repair)
        #expect(fixture.primary.selection.sidebarArrangement.collapsedProjects == [fixture.a.id])

        fixture.session.setActiveContainer(.project(fixture.a.id), in: fixture.primary.id, intent: .person)
        #expect(fixture.primary.selection.sidebarArrangement.collapsedProjects.isEmpty)
    }

    /// Another tab of the row the window is on (⌘1…9, ⌘T) leaves a header
    /// the person folded as it is.
    @Test func anotherTabOfTheSameRow_leavesItsFoldedHeader() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.a.id], collapsedProjects: [fixture.a.id])

        fixture.choose(fixture.aOther, in: fixture.primary)

        #expect(fixture.primary.selection.activeTabID == fixture.aOther.id)
        #expect(fixture.primary.selection.sidebarArrangement.collapsedProjects == [fixture.a.id])
    }

    /// A row of a project another window shows opens that window's header,
    /// and leaves this window's folds as they were.
    @Test func aRowAnotherWindowShows_opensThatWindowsHeader() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let folded = SidebarArrangement(projectOrder: [fixture.a.id, fixture.b.id], collapsedProjects: [fixture.b.id])
        fixture.primary.selection.sidebarArrangement = folded
        other.selection.sidebarArrangement = folded
        _ = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session, admission: .created)
        let worktree = try #require(fixture.session.project(fixture.b.id)?.worktrees.first)

        fixture.session.setActiveContainer(
            .worktree(projectID: fixture.b.id, worktreeID: worktree.id),
            in: fixture.primary.id,
            intent: .person
        )

        #expect(other.selection.sidebarArrangement.collapsedProjects.isEmpty)
        #expect(fixture.primary.selection.sidebarArrangement == folded)
        fixture.expectInvariants()
    }

    // MARK: - Rows of other projects

    /// Another project's row switches this window to it in place; one that
    /// another window shows brings that window forward instead.
    @Test func anotherProjectsRow_switchesThisWindow_orBringsForwardTheOneThatShowsIt() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)

        fixture.session.setActiveContainer(.project(fixture.c.id), in: fixture.primary.id, intent: .person)
        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        #expect(fixture.presenter.shown.isEmpty)

        fixture.session.setActiveContainer(.project(fixture.b.id), in: fixture.primary.id, intent: .person)
        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        #expect(other.selection.activeContainerID == .project(fixture.b.id))
        #expect(fixture.presenter.shown == [other.id])
        fixture.expectInvariants()
    }

    /// A window that shows nothing lists every project; a row shows its
    /// project in that window.
    @Test func aRow_inAWindowThatShowsNothing_showsItsProjectThere() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        #expect(empty.selection.isChoosingProject)

        fixture.session.setActiveContainer(.project(fixture.c.id), in: empty.id, intent: .person)

        #expect(empty.selection.shownProjectID == fixture.c.id)
        #expect(!empty.selection.isChoosingProject)
        fixture.expectInvariants()
    }

    // MARK: - The arrangement through switches

    /// The project switched to is listed open, so what the window shows of
    /// it is in sight; the order stays.
    @Test func aSwitch_opensTheHeaderOfTheProjectSwitchedTo_andKeepsTheOrder() {
        let fixture = Fixture()
        let order = [fixture.c.id, fixture.b.id, fixture.a.id]
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(
            projectOrder: order,
            collapsedProjects: [fixture.b.id, fixture.c.id]
        )

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.selection.sidebarArrangement.collapsedProjects == [fixture.c.id])
        #expect(fixture.primary.selection.sidebarArrangement.projectOrder == order)
    }

    /// One the window has not met is left for the sidebar to meet in its
    /// place, rather than put above the others not met yet.
    @Test func aSwitch_toAProjectNotMetYet_movesNothingUp() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.a.id])

        fixture.choose(fixture.cTab, in: fixture.primary)

        #expect(fixture.primary.selection.sidebarArrangement.projectOrder == [fixture.a.id])
        #expect(fixture.primary.selection.sidebarArrangement.ordered(fixture.session.projects.map(\.id)) == [
            fixture.a.id, fixture.b.id, fixture.c.id
        ])
    }

    @Test func closingAProject_takesItOutOfEveryWindowsArrangement() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let arrangement = SidebarArrangement(
            projectOrder: [fixture.c.id, fixture.a.id, fixture.b.id],
            collapsedProjects: [fixture.c.id],
            openSections: [.init(project: fixture.c.id, section: .other)]
        )
        fixture.primary.selection.sidebarArrangement = arrangement
        other.selection.sidebarArrangement = arrangement

        fixture.session.removeProject(fixture.c.id)

        for window in [fixture.primary, other] {
            #expect(window.selection.sidebarArrangement == SidebarArrangement(projectOrder: [fixture.a.id, fixture.b.id]))
        }
        fixture.expectInvariants()
    }
}
