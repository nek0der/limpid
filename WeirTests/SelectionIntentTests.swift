// SelectionIntentTests.swift
// Weir — why a selection is written decides where it lands: whether it takes the scratch tabs, moves a shown window, or waits in a view.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Each selection names why it is made. Only the person's choice
/// takes the scratch tabs to a window; a window moved because what it
/// showed went away is not choosing them.
@MainActor
struct SelectionIntentTests {
    /// The ways the session moves a window on by itself that land it on
    /// the scratch tabs, where a repair that passed for the person's choice
    /// would show: the scratch tabs would follow it. The other repairs
    /// (leaving a worktree, a restore, following the shown project, the
    /// tab made at launch for a window with none) land on a project, or
    /// are covered below.
    enum RepairPath: CaseIterable, CustomTestStringConvertible {
        case closingItsTab
        case movingItsTabAway
        case removingItsProject

        var testDescription: String {
            switch self {
            case .closingItsTab: "closing its tab"
            case .movingItsTabAway: "moving its tab away"
            case .removingItsProject: "removing its project"
            }
        }
    }

    @Test(arguments: RepairPath.allCases)
    func aRepairLandingOnTheScratchTabs_leavesThemWithTheWindowThatChoseThem(_ path: RepairPath) {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let shown = session.openTab(container: .loose)
        let scratch = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        // The other window chose the scratch tabs last; the primary is put
        // where the path moves it from.
        session.setActiveTab(scratch.id, in: other, intent: .person)
        let primary = session.primaryWindowID
        switch path {
        case .closingItsTab:
            session.setActiveTab(shown.id, in: primary, intent: .repair)
            session.closeTab(shown.id)
        case .movingItsTabAway:
            session.setActiveTab(shown.id, in: primary, intent: .repair)
            session.moveTab(shown.id, to: .project(project.id))
        case .removingItsProject:
            session.openTab(container: .project(project.id), in: primary, intent: .person, selects: true)
            session.removeProject(project.id)
        }

        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.scratchOwnerWindowID == other)
        #expect(session.scratchDrawingWindowID == other)
    }

    @Test func theRepairIntent_doesNotClaimTheScratchTabs() {
        let (session, scratch, _) = WorkspaceSessionFixture.withLooseTab()
        let primary = session.primaryWindowID
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.claimScratch(for: primary)

        session.setActiveTab(scratch.id, in: other, intent: .repair)
        #expect(session.scratchOwnerWindowID == primary)
        session.setActiveContainer(.loose, in: other, intent: .repair)
        #expect(session.scratchOwnerWindowID == primary)
        // Work that ends behind the person is not their choice either.
        session.setActiveTab(scratch.id, in: other, intent: .behind)
        #expect(session.scratchOwnerWindowID == primary)
        #expect(session.showsScratch(in: primary))
        #expect(!session.showsScratch(in: other))

        session.setActiveContainer(.loose, in: other, intent: .person)
        #expect(session.scratchOwnerWindowID == other)
        #expect(SelectionIntent.person.claimsScratch)
        #expect(!SelectionIntent.repair.claimsScratch)
        #expect(!SelectionIntent.behind.claimsScratch)
    }

    @Test func theTabMadeForAWindowWithNone_doesNotClaimTheScratchTabs() throws {
        let session = WorkspaceSession()
        let other = WorkspaceSessionFixture.addWindow(to: session)

        // As the launch makes one when there is no tab to show.
        let tab = try #require(session.openTabInActiveScope(in: session.primaryWindowID, intent: .repair))

        #expect(session.primarySelection.activeTabID == tab.id)
        #expect(session.scratchOwnerWindowID == nil)
        // No one chose them, so the first window with them selected draws them.
        #expect(session.scratchDrawingWindowID == session.primaryWindowID)
        #expect(session.selection(other)?.activeTabID == nil)
    }
}

/// Where each intent lands: a repair in the places that held what
/// went away, never forward and never into another project; work behind in
/// no shown window, only in a project's view or its rows' last tabs; and
/// the person's after a wait only while they still show the row they asked
/// from.
extension SelectionIntentTests {
    /// The view a window that left `projectID` on `container` and `tabID`
    /// would have kept.
    private static func view(of projectID: UUID, on container: ContainerID, tabID: UUID?) -> ProjectView {
        ProjectView(
            projectID: projectID,
            activeContainerID: container,
            activeTabID: tabID,
            sidebarWidth: 280,
            sidebarHidden: false,
            isChangesPanelPresented: false
        )
    }

    /// A worktree row of `projectID`, made without git.
    static func worktreeRow(of projectID: UUID, in session: WorkspaceSession, label: String) throws -> ContainerID {
        let worktree = try #require(session.attachGitWorktree(
            projectID: projectID,
            label: label,
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("weir-\(label)-\(UUID().uuidString)"),
            branchName: label
        ))
        return .worktree(projectID: projectID, worktreeID: worktree.id)
    }

    // MARK: - Repair

    @Test func aRepair_writesEveryPlaceThatSelectsTheTab_andRaisesNone() {
        let (session, shown) = WorkspaceSessionFixture.withProject(name: "shown")
        let kept = session.addOrActivateProject(rootURL: URL(fileURLWithPath: "/weir-kept"), suggestedName: "kept")
        let closing = session.openTab(container: .loose)
        let neighbor = session.openTab(container: .loose)
        let primary = session.primaryWindowID
        let hidden = WorkspaceSessionFixture.addWindow(to: session)
        // The primary draws the scratch tab, a hidden window has it
        // selected, and a project no window shows was left on it.
        session.setActiveTab(closing.id, in: primary, intent: .person)
        session.selection(primary)?.projectID = shown.id
        session.setActiveTab(closing.id, in: hidden, intent: .repair)
        session.setWindow(hidden, isHidden: true)
        session.projectViews[kept.id] = Self.view(of: kept.id, on: .loose, tabID: closing.id)
        let calls = ProjectSwitchRecorder.connect(to: session)

        session.closeTab(closing.id)

        #expect(session.selection(primary)?.activeTabID == neighbor.id)
        #expect(session.selection(hidden)?.activeTabID == neighbor.id)
        #expect(session.projectViews[kept.id]?.activeTabID == neighbor.id)
        #expect(session.projectViews[kept.id]?.activeContainerID == .loose)
        #expect(calls.isUntouched)
        #expect(session.hiddenWindowIDs == [hidden])
    }

    @Test func aRepairOfAProjectNoWindowShows_movesItsViewToTheNeighbor() throws {
        let (session, left) = WorkspaceSessionFixture.withProject(name: "left")
        let row = ContainerID.project(left.id)
        let first = session.openTab(container: row)
        let second = session.openTab(container: row)
        let elsewhere = try Self.worktreeRow(of: left.id, in: session, label: "elsewhere")
        // The person works in a scratch tab; the project was left on its
        // first tab.
        let scratch = session.openTab(container: .loose)
        session.projectViews[left.id] = Self.view(of: left.id, on: row, tabID: first.id)

        session.closeTab(first.id)
        #expect(session.projectViews[left.id]?.activeTabID == second.id)
        #expect(session.projectViews[left.id]?.activeContainerID == row)

        // A tab dragged out of the row leaves the view on the row, emptied.
        session.moveTab(second.id, to: elsewhere)
        #expect(session.projectViews[left.id]?.activeTabID == nil)
        #expect(session.projectViews[left.id]?.activeContainerID == row)
        #expect(session.primarySelection.activeTabID == scratch.id)
    }

    @Test func removingAWorktree_movesAViewThatSelectedIt() throws {
        let (session, left) = WorkspaceSessionFixture.withProject(name: "left")
        let folderTab = session.openTab(container: .project(left.id))
        let removed = try Self.worktreeRow(of: left.id, in: session, label: "removed")
        let removedTab = session.openTab(container: removed)
        let hidden = try Self.worktreeRow(of: left.id, in: session, label: "hidden")
        session.setActiveContainer(.loose)
        session.projectViews[left.id] = Self.view(of: left.id, on: removed, tabID: removedTab.id)

        try session.removeWorktree(projectID: left.id, worktreeID: #require(removed.worktreeID))
        #expect(session.projectViews[left.id]?.activeContainerID == .project(left.id))
        #expect(session.projectViews[left.id]?.activeTabID == folderTab.id)

        // Hidden from the sidebar alike.
        session.projectViews[left.id] = Self.view(of: left.id, on: hidden, tabID: nil)
        try session.hideWorktree(projectID: left.id, worktreeID: #require(hidden.worktreeID))
        #expect(session.projectViews[left.id]?.activeContainerID == .project(left.id))
        #expect(session.primarySelection.activeContainerID == .loose)
    }

    // MARK: - Behind

    @Test func aBehindWrite_changesNoShownWindowsSelection() throws {
        let (session, shown) = WorkspaceSessionFixture.withProject(name: "shown")
        let row = ContainerID.project(shown.id)
        let inFront = session.openTab(container: row)
        let other = try Self.worktreeRow(of: shown.id, in: session, label: "other")
        let otherTab = session.openTab(container: other)
        session.setActiveTab(inFront.id)
        let second = WorkspaceSessionFixture.addWindow(to: session)
        let primary = session.primaryWindowID
        let calls = ProjectSwitchRecorder.connect(to: session)
        let before = try #require(session.currentNavTarget(in: session.primaryWindowID))

        session.setActiveTab(otherTab.id, in: primary, intent: .behind)
        session.setActiveContainer(other, in: primary, intent: .behind)
        session.activateProject(shown.id, in: second, intent: .behind)
        session.openTab(container: other, in: primary, intent: .behind, selects: true)
        // Clearing a window's tab is that window's own, not work behind.
        session.setActiveTab(nil, in: primary, intent: .behind)

        #expect(session.currentNavTarget(in: session.primaryWindowID) == before)
        #expect(session.selection(second)?.activeContainerID == .loose)
        #expect(session.selection(second)?.activeTabID == nil)
        #expect(calls.isUntouched)
    }

    @Test func aBehindWrite_toAProjectWithAView_setsItLikeStaysBehind() throws {
        let (session, left) = WorkspaceSessionFixture.withProject(name: "left")
        let row = try Self.worktreeRow(of: left.id, in: session, label: "row")
        let primary = session.primaryWindowID

        // The view shows the row with no tab: the tab comes to front there,
        // as it would in a window.
        session.projectViews[left.id] = Self.view(of: left.id, on: row, tabID: nil)
        let first = session.openTab(container: row, in: primary, intent: .behind, selects: true)
        #expect(session.projectViews[left.id]?.activeTabID == first.id)
        #expect(session.lastActiveTabID(for: row) == first.id)

        // The view shows a tab of the row: it stays in front, and stays the
        // row's last tab.
        let second = session.openTab(container: row, in: primary, intent: .behind, selects: true)
        #expect(session.projectViews[left.id]?.activeTabID == first.id)
        #expect(session.lastActiveTabID(for: row) == first.id)
        #expect(second.container == row)

        // The view shows another row: it stays there, and the tab becomes
        // its row's last.
        let other = try Self.worktreeRow(of: left.id, in: session, label: "other")
        let otherTab = session.openTab(container: other, in: primary, intent: .behind, selects: true)
        #expect(session.projectViews[left.id]?.activeContainerID == row)
        #expect(session.projectViews[left.id]?.activeTabID == first.id)
        #expect(session.lastActiveTabID(for: other) == otherTab.id)

        // A new, empty row asked for behind is selected in the view:
        // the project opens on it, and its first tab comes to front there.
        let new = try Self.worktreeRow(of: left.id, in: session, label: "new")
        session.setActiveContainer(new, in: primary, intent: .behind)
        #expect(session.projectViews[left.id]?.activeContainerID == new)
        #expect(session.projectViews[left.id]?.activeTabID == nil)
        let newTab = session.openTab(container: new, in: primary, intent: .behind, selects: true)
        #expect(session.projectViews[left.id]?.activeTabID == newTab.id)
        // A row with tabs is left to its tab: the view stays.
        session.setActiveContainer(other, in: primary, intent: .behind)
        #expect(session.projectViews[left.id]?.activeContainerID == new)
        #expect(session.currentNavTarget(in: session.primaryWindowID)?.container == .loose)
    }

    @Test func aBehindWrite_toAProjectNeverShown_touchesOnlyLastActiveTab_andMakesNoView() throws {
        let (session, left) = WorkspaceSessionFixture.withProject(name: "left")
        let before = try #require(session.currentNavTarget(in: session.primaryWindowID))

        let tab = session.openTab(container: .project(left.id), in: session.primaryWindowID, intent: .behind, selects: true)

        #expect(session.projectViews.isEmpty)
        #expect(session.project(left.id)?.lastActiveTabID == tab.id)
        #expect(session.currentNavTarget(in: session.primaryWindowID) == before)
    }

    // MARK: - After a wait

    /// A git that lets the person act while it makes the worktree.
    private struct WaitingGit: GitRunning {
        let git = FakeGit()
        let meanwhile: @MainActor @Sendable () -> Void

        func createWorktree(repoRoot: URL, path: URL, baseBranch: String, newBranchName: String?) async throws -> GitResult {
            await meanwhile()
            return try await git.createWorktree(repoRoot: repoRoot, path: path, baseBranch: baseBranch, newBranchName: newBranchName)
        }

        func removeWorktree(repoRoot: URL, path: URL, force: Bool) async throws -> GitResult {
            try await git.removeWorktree(repoRoot: repoRoot, path: path, force: force)
        }

        func createBranch(repoRoot: URL, name: String, startPoint: String) async throws -> GitResult {
            try await git.createBranch(repoRoot: repoRoot, name: name, startPoint: startPoint)
        }

        func pruneWorktrees(repoRoot: URL) async throws -> GitResult {
            try await git.pruneWorktrees(repoRoot: repoRoot)
        }

        func fetch(repoRoot: URL, remote: String, branch: String) async throws -> GitResult {
            try await git.fetch(repoRoot: repoRoot, remote: remote, branch: branch)
        }

        func fetchRef(repoRoot: URL, remote: String, ref: String) async throws -> FetchedRef {
            try await git.fetchRef(repoRoot: repoRoot, remote: remote, ref: ref)
        }

        func listIgnored(repoRoot: URL) async throws -> [String] {
            try await git.listIgnored(repoRoot: repoRoot)
        }

        func commitsBehind(repoRoot: URL, local: String, upstream: String) async -> Int? {
            await git.commitsBehind(repoRoot: repoRoot, local: local, upstream: upstream)
        }
    }

    /// Makes a worktree and its tab, asked for in `window` (the primary
    /// when `nil`) as the person, who does `meanwhile` during the wait.
    /// Returns the new row.
    private static func createAwaited(
        in session: WorkspaceSession,
        project: Project,
        window: WindowID? = nil,
        meanwhile: @escaping @MainActor @Sendable () -> Void
    ) async throws -> ContainerID {
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: FileManager.default.temporaryDirectory.appendingPathComponent("weir-awaited-\(UUID().uuidString)"),
            baseBranch: "main",
            newBranchName: nil,
            openTab: true,
            in: window ?? session.primaryWindowID,
            intent: .person,
            git: WaitingGit(meanwhile: meanwhile)
        )
        return .worktree(projectID: project.id, worktreeID: worktree.id)
    }

    @Test func anAwaitedCreate_fromAWindowThatClosed_selectsTheNewRowInItsView() async throws {
        let (session, asked) = WorkspaceSessionFixture.withProject(name: "asked")
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let folderTab = session.openTab(container: .project(asked.id), in: other)
        let before = try #require(session.currentNavTarget(in: session.primaryWindowID))

        let row = try await Self.createAwaited(in: session, project: asked, window: other) {
            // The window closes, and the project keeps its view, on the
            // folder's tab.
            session.removeWindowsPastPrimary()
            session.projectViews[asked.id] = Self.view(of: asked.id, on: .project(asked.id), tabID: folderTab.id)
        }

        // The project opens on the new row, its tab in front.
        let tab = try #require(session.tabs(in: row).first)
        #expect(session.projectViews[asked.id]?.activeContainerID == row)
        #expect(session.projectViews[asked.id]?.activeTabID == tab.id)
        #expect(session.currentNavTarget(in: session.primaryWindowID) == before)
    }

    /// A session and its registry, the registry telling the session which
    /// windows it hides and shows and switching its windows between
    /// projects, as the app wires them.
    static func registered() -> (session: WorkspaceSession, registry: WindowRegistry) {
        let session = WorkspaceSession()
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.onVisibilityChange = { window, isHidden in
            session.setWindow(window, isHidden: isHidden)
        }
        registry.connectProjectSwitching(of: session)
        return (session, registry)
    }

    @Test func anOpenedFolder_whoseWindowClosedDuringTheWait_switchesNothing() async throws {
        let (session, registry) = Self.registered()
        let window = registry.primary
        let folder = URL(fileURLWithPath: "/weir-opened-\(UUID().uuidString)")

        // Asked while the window is shown, which is recorded before the
        // wait: the window closes (hides) while the folder is resolved.
        await SupervisionWindowActions.openProject(at: folder, from: window, session: session, registry: registry, frecency: nil) { url in
            registry.hide(window.id)
            return url
        }

        let project = try #require(session.projects.first)
        #expect(registry.window(showingProject: project.id, in: session) == nil)
        #expect(window.isHidden)
        #expect(session.windowIDs == [window.id])
    }

    @Test func anOpenedFolder_withThePersonStillThere_switchesTheirWindowToIt() async throws {
        let (session, registry) = Self.registered()
        let folder = URL(fileURLWithPath: "/weir-opened-\(UUID().uuidString)")

        await SupervisionWindowActions
            .openProject(at: folder, from: registry.primary, session: session, registry: registry, frecency: nil) { $0 }

        let project = try #require(session.projects.first)
        #expect(registry.window(showingProject: project.id, in: session) === registry.primary)
        #expect(registry.windows.count == 1)
    }

    @Test func anAwaitedCreate_whoseWindowWasHiddenDuringTheWait_selectsTheNewRowThere() async throws {
        let (session, asked) = WorkspaceSessionFixture.withProject(name: "asked")
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let folderTab = session.openTab(container: .project(asked.id), in: other)
        let before = try #require(session.currentNavTarget(in: session.primaryWindowID))

        let row = try await Self.createAwaited(in: session, project: asked, window: other) {
            session.setWindow(other, isHidden: true)
        }

        // Hidden, it still shows the project, and opens again on the new
        // row with its tab in front; no view is made.
        let tab = try #require(session.tabs(in: row).first)
        #expect(session.selection(other)?.activeContainerID == row)
        #expect(session.selection(other)?.activeTabID == tab.id)
        #expect(session.projectViews.isEmpty)
        #expect(session.currentNavTarget(in: session.primaryWindowID) == before)
        #expect(session.lastActiveTabID(for: .project(asked.id)) == folderTab.id)
    }

    @Test func anAwaitedCreate_afterThePersonMovedToAnotherProject_isBehind() async throws {
        let (session, asked) = WorkspaceSessionFixture.withProject(name: "asked")
        let other = session.addOrActivateProject(rootURL: URL(fileURLWithPath: "/weir-other"), suggestedName: "other")
        let elsewhere = session.openTab(container: .project(other.id))
        session.setActiveContainer(.project(asked.id))

        let row = try await Self.createAwaited(in: session, project: asked) {
            session.setActiveTab(elsewhere.id)
        }

        #expect(session.primarySelection.activeTabID == elsewhere.id)
        let tab = try #require(session.tabs(in: row).first)
        #expect(session.lastActiveTabID(for: row) == tab.id)
    }

    @Test func anAwaitedCreate_afterThePersonMovedToAnotherRowOfTheSameProject_isBehind() async throws {
        let (session, asked) = WorkspaceSessionFixture.withProject(name: "asked")
        let otherRow = try Self.worktreeRow(of: asked.id, in: session, label: "other")
        let typing = session.openTab(container: otherRow)
        session.setActiveContainer(.project(asked.id))

        let row = try await Self.createAwaited(in: session, project: asked) {
            session.setActiveTab(typing.id)
        }

        #expect(session.primarySelection.activeContainerID == otherRow)
        #expect(session.primarySelection.activeTabID == typing.id)
        // Chosen later, the new row opens on its tab.
        let tab = try #require(session.tabs(in: row).first)
        session.setActiveContainer(row)
        #expect(session.primarySelection.activeTabID == tab.id)
    }

    @Test func anAwaitedCreate_withThePersonStillOnTheRow_selectsTheNewRow() async throws {
        let (session, asked) = WorkspaceSessionFixture.withProject(name: "asked")
        session.setActiveContainer(.project(asked.id))

        let row = try await Self.createAwaited(in: session, project: asked) {}

        #expect(session.primarySelection.activeContainerID == row)
        #expect(session.primarySelection.activeTabID == session.tabs(in: row).first?.id)
    }

    @Test func anAwaitedOpen_fromAWindowThatWentAway_isBehind() async throws {
        let session = WorkspaceSession()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let before = try #require(session.currentNavTarget(in: session.primaryWindowID))
        let folder = URL(fileURLWithPath: "/weir-opened-\(UUID().uuidString)")

        let project = await session.openProject(at: folder, in: other, intent: .person) { url in
            // The window is closed while the folder is resolved.
            session.removeWindowsPastPrimary()
            return url
        }

        #expect(session.selection(other) == nil)
        #expect(session.currentNavTarget(in: session.primaryWindowID) == before)
        let tab = try #require(session.tabs(in: .project(project.id)).first)
        #expect(session.project(project.id)?.lastActiveTabID == tab.id)
        #expect(session.projectViews.isEmpty)
    }

    @Test func theIntentAfterAWait_isThePersonsOnlyOnTheRowTheyAskedFrom_inAWindowTheyDidNotLeave() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let primary = session.primaryWindowID
        let row = ContainerID.project(project.id)
        session.setActiveContainer(row)
        let asked = session.waitOrigin(in: primary)

        #expect(session.intentAfterWait(from: asked) == .person)
        #expect(session.intentAfterWait(from: nil) == .behind)
        #expect(session.waitOrigin(in: WindowID()) == nil)
        // Moved to another row meanwhile.
        session.setActiveContainer(.loose)
        #expect(session.intentAfterWait(from: asked) == .behind)
        // On a scratch tab, the same row in another project is somewhere
        // else: the window switched while the person waited.
        session.primarySelection.projectID = project.id
        let onScratch = session.waitOrigin(in: primary)
        #expect(session.intentAfterWait(from: onScratch) == .person)
        session.primarySelection.projectID = UUID()
        #expect(session.intentAfterWait(from: onScratch) == .behind)
        session.primarySelection.projectID = project.id
        session.setActiveContainer(row)
        // Hidden during the wait: left.
        session.setWindow(primary, isHidden: true)
        #expect(session.intentAfterWait(from: asked) == .behind)
        // Hidden already as they asked (from the menu bar, with every window
        // closed): not left, and still theirs, shown again or not.
        let askedHidden = session.waitOrigin(in: primary)
        #expect(askedHidden?.wasShown == false)
        #expect(session.intentAfterWait(from: askedHidden) == .person)
        session.setWindow(primary, isHidden: false)
        #expect(session.intentAfterWait(from: askedHidden) == .person)
    }

    // MARK: - A suggested move

    /// A scratch tab drawn in the primary and selected, undrawn, in a
    /// second window, whose agent moved into a worktree of another project.
    private struct SuggestedMove {
        let session: WorkspaceSession
        let undrawn: WindowID
        let tab: Tab
        let neighbor: Tab
        let target: Project
        let suggester: WorktreeMoveSuggester
    }

    private static func suggestedMove() throws -> SuggestedMove {
        let (session, target) = WorkspaceSessionFixture.withProject(name: "target")
        let row = try worktreeRow(of: target.id, in: session, label: "moved")
        let neighbor = session.openTab(container: .loose)
        let tab = session.openTab(container: .loose)
        let undrawn = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tab.id, in: undrawn, intent: .repair)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let suggester = WorktreeMoveSuggester()
        suggester.bind(session: session)
        suggester.current = try WorktreeMoveSuggestion(
            paneID: pane,
            newCwd: FileManager.default.temporaryDirectory,
            kind: .reparentToRegistered(projectID: target.id, worktreeID: #require(row.worktreeID), label: "moved")
        )
        return SuggestedMove(session: session, undrawn: undrawn, tab: tab, neighbor: neighbor, target: target, suggester: suggester)
    }

    @Test func movingASuggestedTab_isThePersonsInTheDrawingWindow_andARepairElsewhere() throws {
        let move = try Self.suggestedMove()
        let session = move.session
        let projectWindow = WorkspaceSessionFixture.addWindow(to: session)
        session.selection(projectWindow)?.projectID = move.target.id
        let calls = ProjectSwitchRecorder.connect(to: session)

        move.suggester.accept()

        // The window the person said OK in sends the tab to the window that
        // shows its project, brought forward; the one that did not draw it
        // is only moved on. Neither switches.
        #expect(calls.raised == [projectWindow])
        #expect(calls.switches.isEmpty)
        #expect(session.selection(projectWindow)?.activeTabID == move.tab.id)
        #expect(session.selection(move.undrawn)?.activeTabID == move.neighbor.id)
        #expect(session.selection(move.undrawn)?.activeContainerID == .loose)
    }

    @Test func aRepairToAnotherProjectsTab_neverMakesASecondWindowShowIt() throws {
        let move = try Self.suggestedMove()
        let session = move.session

        move.suggester.accept()

        // The primary window, with no app layer switching it, follows the
        // tab; the undrawn one stays out of the project.
        #expect(session.primarySelection.activeTabID == move.tab.id)
        #expect(session.selection(move.undrawn)?.shownProjectID == nil)
        let showing = session.windowIDs.filter { session.selection($0)?.shownProjectID == move.target.id }
        #expect(showing == [session.primaryWindowID])
    }

    // MARK: - A hidden window

    // A hidden window is treated as its project's view: keys don't reach
    // it, so work behind lands there by the view's rule.

    /// A window beside the primary, put on `container` as the person
    /// would, then closed (hidden).
    private static func hiddenWindow(on container: ContainerID, in session: WorkspaceSession) -> WindowID {
        let window = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(container, in: window)
        session.setWindow(window, isHidden: true)
        return window
    }

    @Test func aBehindWrite_leavesAHiddenWindowOnAnotherRow() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "project")
        let shownRow = ContainerID.project(project.id)
        let shownTab = session.openTab(container: shownRow)
        let other = try Self.worktreeRow(of: project.id, in: session, label: "other")
        let otherTab = session.openTab(container: other)
        // The primary shows no project, so the window to hide can show it.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)
        let hidden = Self.hiddenWindow(on: shownRow, in: session)
        let primary = session.primaryWindowID

        session.setActiveTab(otherTab.id, in: primary, intent: .behind)
        let opened = session.openTab(container: other, in: primary, intent: .behind, selects: true)

        #expect(session.selection(hidden)?.activeContainerID == shownRow)
        #expect(session.selection(hidden)?.activeTabID == shownTab.id)
        // Nothing holds the other row, so it opens on the new tab later.
        #expect(session.lastActiveTabID(for: other) == opened.id)
        #expect(session.projectViews.isEmpty)
        #expect(session.primarySelection.activeContainerID == .loose)
    }

    @Test func aBehindWrite_leavesAHiddenWindowOverATabOfTheRow_andTheRowsLastTab() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "project")
        let row = try Self.worktreeRow(of: project.id, in: session, label: "row")
        let inFront = session.openTab(container: row)
        // The primary shows no project, so the window to hide can show it.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)
        let hidden = Self.hiddenWindow(on: row, in: session)
        let primary = session.primaryWindowID

        let opened = session.openTab(container: row, in: primary, intent: .behind, selects: true)
        session.setActiveTab(opened.id, in: primary, intent: .behind)

        #expect(session.selection(hidden)?.activeTabID == inFront.id)
        #expect(session.selection(hidden)?.activeContainerID == row)
        // The hidden window holds the row: its last tab stays the one shown.
        #expect(session.lastActiveTabID(for: row) == inFront.id)
        #expect(session.projectViews.isEmpty)
    }

    @Test func aBehindWrite_landsOnlyInTheHiddenWindowOfItsProject() throws {
        let (session, mine) = WorkspaceSessionFixture.withProject(name: "mine")
        let theirs = session.addOrActivateProject(rootURL: URL(fileURLWithPath: "/weir-theirs"), suggestedName: "theirs")
        let theirTab = session.openTab(container: .project(theirs.id))
        let row = try Self.worktreeRow(of: mine.id, in: session, label: "row")
        // The primary shows no project, so the window to hide can show it.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)
        let mineWindow = Self.hiddenWindow(on: row, in: session)
        let theirWindow = Self.hiddenWindow(on: .project(theirs.id), in: session)

        let tab = session.openTab(container: row, in: session.primaryWindowID, intent: .behind, selects: true)

        // Over its empty row, the window of the tab's project takes it.
        #expect(session.selection(mineWindow)?.activeTabID == tab.id)
        #expect(session.selection(theirWindow)?.activeContainerID == .project(theirs.id))
        #expect(session.selection(theirWindow)?.activeTabID == theirTab.id)
        #expect(session.projectViews.isEmpty)
        #expect(session.primarySelection.activeContainerID == .loose)
    }

    @Test func aBehindWriteOfANewRow_movesAHiddenWindowOffTheTabItShowed() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "project")
        let folder = ContainerID.project(project.id)
        let folderTab = session.openTab(container: folder)
        // The primary shows no project, so the window to hide can show it.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)
        let hidden = Self.hiddenWindow(on: folder, in: session)
        #expect(session.selection(hidden)?.activeTabID == folderTab.id)

        // A worktree made behind: its row is new and empty.
        let row = try Self.worktreeRow(of: project.id, in: session, label: "new")
        session.setActiveContainer(row, in: session.primaryWindowID, intent: .behind)

        #expect(session.selection(hidden)?.activeContainerID == row)
        #expect(session.selection(hidden)?.activeTabID == nil)
        let tab = session.openTab(container: row, in: session.primaryWindowID, intent: .behind, selects: true)
        #expect(session.selection(hidden)?.activeTabID == tab.id)
        #expect(session.primarySelection.activeContainerID == .loose)
    }
}
