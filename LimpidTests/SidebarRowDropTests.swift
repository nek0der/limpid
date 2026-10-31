// SidebarRowDropTests.swift
// Limpid — a tab or a ⌥⌘-dragged pane dropped on a sidebar row of any project: where it goes, and when nothing would move.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct SidebarRowDropTests {
    typealias Fixture = ProjectWindowsFixture

    private static func rowDrop(_ fixture: Fixture, dragState: LimpidDragState = LimpidDragState()) -> SidebarRowDrop {
        SidebarRowDrop(session: fixture.session, dragState: dragState, window: fixture.primary.id, locale: Locale(identifier: "en"))
    }

    /// Splits `tab` in two, returning its new pane.
    private static func split(_ tab: Tab, in fixture: Fixture) -> UUID {
        let existing = tab.splitTree.allLeafIDs()
        fixture.session.update(tab.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: existing[0], direction: .horizontal).tree
        }
        let leaves = fixture.session.tab(tab.id)?.splitTree.allLeafIDs() ?? []
        return leaves.first { !existing.contains($0) } ?? existing[0]
    }

    /// A pane beside another leaves in a tab of its own, in the row of
    /// another project, and the tab it left keeps the other pane. The window
    /// stays on its project.
    @Test func aPaneBesideAnother_movesInATabOfItsOwn_andTheWindowStays() throws {
        let fixture = Fixture()
        let pane = Self.split(fixture.aTab, in: fixture)

        Self.rowDrop(fixture).drop(prefix: DragPrefix.pane, pane, on: .project(fixture.b.id))

        let moved = try #require(fixture.session.tab(containing: pane))
        #expect(moved.id != fixture.aTab.id)
        #expect(moved.container == .project(fixture.b.id))
        #expect(fixture.session.tab(fixture.aTab.id)?.splitTree.allLeafIDs().count == 1)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
    }

    /// The window stays on the tab the pane left, not on whichever tab the
    /// source row lists last.
    @Test func aPaneDropped_leavesTheWindowOnTheTabItLeft() {
        let fixture = Fixture()
        fixture.choose(fixture.aTab, in: fixture.primary)
        let pane = Self.split(fixture.aTab, in: fixture)

        Self.rowDrop(fixture).drop(prefix: DragPrefix.pane, pane, on: .project(fixture.b.id))

        #expect(fixture.session.activeTab(in: fixture.primary.id)?.id == fixture.aTab.id)
    }

    /// A window standing on an empty row shows the tab dropped there, rather
    /// than a row that lists a tab its window does not draw.
    @Test func aTabDroppedOnTheEmptyRowAWindowStandsOn_isSelectedThere() {
        let fixture = Fixture()
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        #expect(fixture.session.activeTab(in: fixture.primary.id) == nil)

        Self.rowDrop(fixture).drop(prefix: DragPrefix.tab, fixture.aOther.id, on: .loose)

        #expect(fixture.session.activeTab(in: fixture.primary.id)?.id == fixture.aOther.id)
    }

    /// A pane alone in its tab takes the tab with it, rather than leave an
    /// empty one behind.
    @Test func aPaneAloneInItsTab_takesTheTabWithIt() throws {
        let fixture = Fixture()
        let pane = try #require(fixture.aTab.splitTree.allLeafIDs().first)

        Self.rowDrop(fixture).drop(prefix: DragPrefix.pane, pane, on: .project(fixture.b.id))

        #expect(fixture.session.tab(fixture.aTab.id)?.container == .project(fixture.b.id))
        #expect(fixture.session.tab(containing: pane)?.id == fixture.aTab.id)
    }

    /// A missing worktree's row turns a tab and a pane away: a tab there has
    /// no folder to run in. The pane stays beside the other, not split off
    /// for a move that never happens, and a live worktree's row still takes
    /// both.
    @Test func aMissingWorktreesRow_refusesATabAndAPane_andMovesNothing() throws {
        let fixture = Fixture()
        let gone = WorktreeFixture.make(isMissing: true)
        let live = WorktreeFixture.make()
        let projectIndex = try #require(fixture.session.projects.firstIndex { $0.id == fixture.b.id })
        fixture.session.projects[projectIndex].worktrees += [gone, live]
        let goneRow = ContainerID.worktree(projectID: fixture.b.id, worktreeID: gone.id)
        let liveRow = ContainerID.worktree(projectID: fixture.b.id, worktreeID: live.id)
        let pane = Self.split(fixture.aTab, in: fixture)
        let rowDrop = Self.rowDrop(fixture)

        #expect(rowDrop.refuses(fixture.aOther.id, on: goneRow))
        #expect(!rowDrop.refuses(fixture.aOther.id, on: liveRow))

        rowDrop.drop(prefix: DragPrefix.tab, fixture.aOther.id, on: goneRow)
        rowDrop.drop(prefix: DragPrefix.pane, pane, on: goneRow)
        #expect(fixture.session.tab(fixture.aOther.id)?.container == .project(fixture.a.id))
        #expect(fixture.session.tab(containing: pane)?.id == fixture.aTab.id)

        rowDrop.drop(prefix: DragPrefix.tab, fixture.aOther.id, on: liveRow)
        #expect(fixture.session.tab(fixture.aOther.id)?.container == liveRow)
    }

    /// A pane alone in a tab of its row would stay as it is; one beside
    /// another still has somewhere to go, a tab of its own in that row.
    @Test func aPaneIsRefusedByItsOwnRow_onlyAloneInATab() throws {
        let fixture = Fixture()
        let dragState = LimpidDragState(isMouseButtonDown: { true })
        dragState.begin(.pane, sourceID: UUID().uuidString)
        defer { dragState.end() }
        let rowDrop = Self.rowDrop(fixture, dragState: dragState)
        let alone = try #require(fixture.aTab.splitTree.allLeafIDs().first)

        #expect(rowDrop.refuses(alone, on: .project(fixture.a.id)))
        #expect(!rowDrop.refuses(alone, on: .project(fixture.b.id)))

        let beside = Self.split(fixture.aTab, in: fixture)
        #expect(!rowDrop.refuses(beside, on: .project(fixture.a.id)))
    }

    /// A refused drop lets go of the project the drag held open for it: the
    /// tab never arrived, so the project folds again.
    @Test func aRefusedDrop_letsGoOfTheProjectTheDragHeldOpen() throws {
        let fixture = Fixture()
        let gone = WorktreeFixture.make(isMissing: true)
        let projectIndex = try #require(fixture.session.projects.firstIndex { $0.id == fixture.b.id })
        fixture.session.projects[projectIndex].worktrees.append(gone)
        let dragState = LimpidDragState(isMouseButtonDown: { true })
        let project = SidebarDropProject(window: fixture.primary.id, projectID: fixture.b.id)
        dragState.begin(.tab, sourceID: fixture.aOther.id.uuidString)
        dragState.springOpen(project)
        dragState.keepSpringOpen(for: project)
        dragState.end()
        #expect(dragState.keptOpenProject == project)

        Self.rowDrop(fixture, dragState: dragState).drop(
            prefix: DragPrefix.tab,
            fixture.aOther.id,
            on: .worktree(projectID: fixture.b.id, worktreeID: gone.id)
        )

        #expect(dragState.keptOpenProject == nil)
        #expect(dragState.landing == nil)
    }

    /// A row gone from the session takes nothing, so no tab ends up in a
    /// container no list shows.
    @Test func aRowGoneFromTheSession_refusesTheDrop() {
        let fixture = Fixture()
        let gone = ContainerID.worktree(projectID: fixture.b.id, worktreeID: UUID())

        Self.rowDrop(fixture).drop(prefix: DragPrefix.tab, fixture.aOther.id, on: gone)

        #expect(fixture.session.tab(fixture.aOther.id)?.container == .project(fixture.a.id))
    }

    /// New panes of a tab moved to another project's row start in that row's
    /// folder; a tab moved to the scratch row keeps the one it had.
    @Test func aMovedTab_startsItsPanesInTheRowsFolder() throws {
        let fixture = Fixture()
        let worktree = WorktreeFixture.make()
        let projectIndex = try #require(fixture.session.projects.firstIndex { $0.id == fixture.b.id })
        fixture.session.projects[projectIndex].worktrees.append(worktree)
        let row = ContainerID.worktree(projectID: fixture.b.id, worktreeID: worktree.id)

        fixture.session.moveTab(fixture.aOther.id, to: row)
        #expect(fixture.session.tab(fixture.aOther.id)?.newPaneWorkingDirectory == worktree.workingDirectory.path)

        fixture.session.moveTab(fixture.aOther.id, to: .loose)
        #expect(fixture.session.tab(fixture.aOther.id)?.newPaneWorkingDirectory == worktree.workingDirectory.path)
    }

    /// A window choosing a project stands on the scratch row without showing
    /// it: a tab dropped there from another window selects nothing in it.
    @Test func aTabDroppedOnScratch_leavesAWindowChoosingAProjectAlone() {
        let fixture = Fixture()
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        fixture.primary.selection.isChoosingProject = true

        Self.rowDrop(fixture).drop(prefix: DragPrefix.tab, fixture.aOther.id, on: .loose)

        #expect(fixture.primary.selection.activeTabID == nil)
    }

    /// A pane strip tab: a pane joins it, unless the pane is in it already.
    @Test func aPaneStripTab_takesAPaneFromAnotherTab_notItsOwn() {
        let fixture = Fixture()
        let pane = Self.split(fixture.aTab, in: fixture)
        let own = PaneStripTabDrop(
            tabID: fixture.aTab.id,
            container: .project(fixture.a.id),
            session: fixture.session,
            window: fixture.primary.id
        )
        let other = PaneStripTabDrop(
            tabID: fixture.aOther.id,
            container: .project(fixture.a.id),
            session: fixture.session,
            window: fixture.primary.id
        )

        #expect(own.isNoOp(pane, at: .before))
        #expect(!other.isNoOp(pane, at: .before))

        other.drop(prefix: DragPrefix.pane, pane, at: .before)
        #expect(fixture.session.tab(containing: pane)?.id == fixture.aOther.id)
    }

    /// A tab or pane on a row, and a pane on any target that takes one, wait
    /// for the drop; anything else reorders live.
    @Test func whatWaitsForTheDrop() {
        let row: Set<String> = [DragPrefix.tab, DragPrefix.pane]
        #expect(ReorderDropRule.isAssignedOnDrop(isCarryingToRow: true, isPane: false, assignsOnDrop: true, acceptedPrefixes: row))
        #expect(ReorderDropRule.isAssignedOnDrop(isCarryingToRow: true, isPane: true, assignsOnDrop: false, acceptedPrefixes: row))
        #expect(!ReorderDropRule.isAssignedOnDrop(isCarryingToRow: true, isPane: false, assignsOnDrop: false, acceptedPrefixes: row))
        #expect(!ReorderDropRule.isAssignedOnDrop(
            isCarryingToRow: false,
            isPane: false,
            assignsOnDrop: true,
            acceptedPrefixes: [DragPrefix.worktree]
        ))
    }
}
