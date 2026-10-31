// WindowProjectSwitchTests.swift
// Weir — a window switching project in place, the window showing it brought forward, a removed project's windows moved on.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A window shows one project at a time and a project is shown in one
/// window at a time. The person's choice of another project's
/// session switches the window in place, keeping what it showed of the
/// project it left for when a window shows that project again, or brings
/// forward the window that shows it. Nothing else switches a window or
/// brings one forward, except a removed project's windows, which move on.
@MainActor
struct WindowProjectSwitchTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - Switching in place

    @Test func choosingAnotherProjectsTab_switchesThisWindow_andOpensNone() {
        let fixture = Fixture()

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.session.windowIDs == [fixture.primary.id])
        #expect(fixture.presenter.shown.isEmpty)
        // What the window showed of `a` is kept for it.
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)

        // Again, from the same window: still the one window.
        fixture.choose(fixture.cTab, in: fixture.primary)
        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        #expect(fixture.registry.windows.count == 1)
        fixture.expectInvariants()
    }

    @Test func aTabOpenedInAnotherProject_switchesThisWindow_howeverItIsAskedFor() {
        let fixture = Fixture()

        // A reopened tab, a new tab in a project's row: opened and chosen
        // in the window asked.
        let opened = fixture.session.openTab(container: .project(fixture.b.id), in: fixture.primary.id, intent: .person, selects: true)

        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == opened.id)
        #expect(fixture.registry.windows.count == 1)
        fixture.expectInvariants()
    }

    /// The palette's project rows, run in turn from the primary: a row of
    /// another project switches this window, and the next row reads the
    /// project it switched to as this window's.
    @Test func thePalettesProjectRows_switchThisWindowOnlyToAnotherProject() throws {
        let fixture = Fixture()
        let worktree = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.c.id,
            label: "feat",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("c-feat"),
            branchName: "feat"
        ))
        let cWorktree = ContainerID.worktree(projectID: fixture.c.id, worktreeID: worktree.id)
        // swiftlint:disable:next large_tuple
        let rows: [(row: CommandPaletteAction, handling: PaletteRowHandling, shown: ContainerID)] = [
            // This window's project, as project ▾ does: nothing changes, and
            // the terminal gets the keyboard back as after any row.
            (.activateProject(fixture.a.id), .handledReturningKeyboard, .project(fixture.a.id)),
            // A tab of this window's project is the shared dispatch's.
            (.jumpToTab(fixture.aTab.id), .notHandled, .project(fixture.a.id)),
            // A project gone: nothing to show, and the keyboard goes back.
            (.activateProject(UUID()), .handledReturningKeyboard, .project(fixture.a.id)),
            (.openSettings, .notHandled, .project(fixture.a.id)),
            // Another project's rows switch this window, whose next terminal
            // takes the keyboard as it is drawn.
            (.jumpToTab(fixture.bTab.id), .handled, .project(fixture.b.id)),
            (.activateWorktree(projectID: fixture.c.id, worktreeID: worktree.id), .handled, cWorktree),
            (.activateProject(fixture.a.id), .handled, .project(fixture.a.id))
        ]

        for (row, handling, shown) in rows {
            let ran = SupervisionWindowActions.runProjectRow(
                row,
                in: fixture.primary,
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            )
            #expect(ran == handling, "\(row)")
            #expect(fixture.primary.selection.activeContainerID == shown, "\(row)")
            #expect(fixture.registry.windows.count == 1, "\(row)")
            if case let .jumpToTab(tab) = row, handling == .handled {
                #expect(fixture.primary.selection.activeTabID == tab)
            }
        }
        fixture.expectInvariants()
    }

    @Test func switchingBack_bringsBackItsSessionTabAndPanelAgent() {
        let fixture = Fixture()
        let selection = fixture.primary.selection
        let agent = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
        fixture.choose(fixture.aOther, in: fixture.primary)
        selection.changesPanelFilter = agent

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(selection.changesPanelFilter == nil)
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        #expect(selection.shownProjectID == fixture.a.id)
        #expect(selection.activeTabID == fixture.aOther.id)
        #expect(selection.changesPanelFilter == agent)
        // `b` keeps its own.
        #expect(fixture.session.projectViews[fixture.b.id]?.activeTabID == fixture.bTab.id)
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        fixture.expectInvariants()
    }

    @Test func switchingProject_keepsTheWindowsSidebarAndChangesPanel() {
        let fixture = Fixture()
        let selection = fixture.primary.selection
        selection.sidebarWidth = 333
        selection.sidebarHidden = true
        selection.isChangesPanelPresented = true
        selection.changesPanelWidth = 444

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(selection.sidebarWidth == 333)
        #expect(selection.sidebarHidden)
        #expect(selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 444)

        // Changed in `b`, and still so back in `a`: the window's, not `b`'s.
        selection.sidebarWidth = 280
        selection.sidebarHidden = false
        selection.isChangesPanelPresented = false
        selection.changesPanelWidth = 360
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        #expect(selection.shownProjectID == fixture.a.id)
        #expect(selection.sidebarWidth == 280)
        #expect(!selection.sidebarHidden)
        #expect(!selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 360)
        fixture.expectInvariants()
    }

    @Test func aProjectSeenForTheFirstTime_keepsThisWindowsSidebarAndChangesPanel() {
        let fixture = Fixture()
        let selection = fixture.primary.selection
        selection.sidebarWidth = 333
        selection.sidebarHidden = true
        selection.frame = CGRect(x: 10, y: 20, width: 900, height: 700)
        selection.isChangesPanelPresented = true
        selection.changesPanelWidth = 444
        selection.changesPanelFilter = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(selection.sidebarWidth == 333)
        #expect(selection.sidebarHidden)
        #expect(selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 444)
        // An agent of the project left is not one of this project's.
        #expect(selection.changesPanelFilter == nil)
        // The window keeps its own state.
        #expect(selection.frame == CGRect(x: 10, y: 20, width: 900, height: 700))
    }

    @Test func aSwitch_isDrawnAsOneChange_withTheAppLayerToldInsideIt() {
        let fixture = Fixture()
        let calls = SwitchCalls()
        fixture.registry.drawsSwitch = { switching in
            calls.isSwitching = true
            switching()
            calls.isSwitching = false
        }
        fixture.registry.onWillSwitchProject = { _, _, _ in calls.told.append("will \(calls.isSwitching)") }
        fixture.registry.onDidSwitchProject = { _ in calls.told.append("did \(calls.isSwitching)") }

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(calls.told == ["will true", "did true"])
    }

    @Test func aBackgroundWriteInAProjectNeverShown_keepsTheFirstShowInheritingTheSidebar() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarWidth = 333
        // Work that ends behind, and a repair, in a project no window has
        // shown: only its rows' last tabs move.
        let behind = fixture.session.openTab(container: .project(fixture.b.id), in: fixture.primary.id, intent: .behind, selects: true)
        fixture.session.closeTab(fixture.bTab.id)
        #expect(fixture.session.projectViews[fixture.b.id] == nil)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)

        fixture.choose(behind, in: fixture.primary)

        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.sidebarWidth == 333)
    }

    // MARK: - The window that shows the project

    @Test func aProjectAnotherShownWindowShows_raisesThatWindow_andLeavesThisOne() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let later = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)

        fixture.choose(later, in: fixture.primary)

        #expect(fixture.presenter.shown == [other.id])
        #expect(other.selection.activeTabID == later.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.registry.windows.count == 2)
        fixture.expectInvariants()
    }

    @Test func withOnlyAHiddenWindow_aPersonsSelectionShowsItAndSwitchesIt() throws {
        let fixture = Fixture()
        fixture.registry.hide(fixture.primary.id)

        // As a notification does: the window commands act on, then the tab.
        let window = try #require(fixture.registry.present(project: fixture.b.id, in: fixture.session, from: nil))
        fixture.choose(fixture.bTab, in: window)

        #expect(window === fixture.primary)
        #expect(!window.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(window.selection.shownProjectID == fixture.b.id)
        #expect(window.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.windows.count == 1)
    }

    @Test func aRepairInAProjectAnotherWindowShows_writesThereWithoutRaisingIt() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let later = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)
        fixture.registry.hide(other.id)
        fixture.presenter.shown = []

        // Asked of the window that shows the project: written there.
        fixture.session.setActiveTab(later.id, in: other.id, intent: .repair)
        // Asked of another window: that one neither switches nor comes
        // forward.
        fixture.session.setActiveTab(fixture.bTab.id, in: fixture.primary.id, intent: .repair)

        #expect(other.selection.activeTabID == later.id)
        #expect(other.isHidden)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        fixture.expectInvariants()
    }

    @Test func aBehindWriteInAProjectAnotherWindowShows_changesNothingThere() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let later = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)

        fixture.session.setActiveTab(later.id, in: fixture.primary.id, intent: .behind)
        fixture.session.setActiveTab(later.id, in: other.id, intent: .behind)

        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.presenter.shown.isEmpty)
        fixture.expectInvariants()
    }

    @Test func closingATabAnotherWindowShows_movesThatWindowToTheNeighbor() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let neighbor = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)

        // Closed from the primary's palette, say.
        fixture.session.closeTab(fixture.bTab.id)

        #expect(other.selection.activeTabID == neighbor.id)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
    }

    @Test func backAcrossProjects_switchesThisWindow() {
        let fixture = Fixture()
        let window = fixture.primary.id
        let before = WorkspaceSession.NavTarget(container: .project(fixture.a.id), tabID: fixture.aTab.id)
        fixture.choose(fixture.bTab, in: fixture.primary)
        // As the app's observer records the move.
        fixture.session.recordNavigation(from: before, in: window)

        fixture.session.navigateBack(in: window, intent: .person)

        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.registry.windows.count == 1)

        fixture.session.navigateForward(in: window, intent: .person)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        fixture.expectInvariants()
    }

    // MARK: - Removing a project

    @Test func removingTheShownProject_movesOnlyThatWindow_toTheMostRecentProjectNoOtherWindowShows() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        // The primary showed `b` once and went back to `a`; the sidebar's
        // width, the window's own, is 333 throughout.
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.primary.selection.sidebarWidth = 333
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)
        #expect(fixture.primary.selection.sidebarWidth == 333)
        var reasons: [ProjectSwitchReason] = []
        fixture.registry.onWillSwitchProject = { _, _, reason in reasons.append(reason) }

        fixture.session.removeProject(fixture.a.id)

        // `c` is the most recent, but another window shows it: `b`, as it
        // was left.
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.primary.selection.sidebarWidth == 333)
        #expect(other.selection.shownProjectID == fixture.c.id)
        #expect(reasons == [.projectRemoved])
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.session.projectViews.isEmpty)
        fixture.expectInvariants()
    }

    @Test func removingTheShownProjectWithAnOpenReview_leavesNoParkedReviewOrView() throws {
        let fixture = Fixture()
        fixture.tidiesAsTheAppDoes()
        let tab = try Fixture.review()
        fixture.primary.review = tab
        fixture.primary.writeComment()

        fixture.session.removeProject(fixture.a.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        // The comment does not keep it: nothing of a removed project stays.
        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.primary.reviewSession == nil)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        fixture.expectInvariants()
    }

    @Test func removingAProjectAHiddenWindowShows_movesThatWindowToo() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.hide(other.id)
        fixture.presenter.shown = []

        fixture.session.removeProject(fixture.c.id)

        #expect(other.selection.shownProjectID == fixture.b.id)
        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(other.isHidden)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    @Test func removingTheProjectAWindowOnScratchKeeps_movesThatWindowOn() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let other = try fixture.window(showing: fixture.c)
        fixture.choose(scratch, in: other)
        #expect(other.selection.shownProjectID == fixture.c.id)
        #expect(fixture.session.scratchOwnerWindowID == other.id)

        fixture.session.removeProject(fixture.c.id)

        // It names no removed project any more: it went on to `b`, and gave
        // up the scratch tabs it left.
        #expect(other.selection.projectID == fixture.b.id)
        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.session.scratchOwnerWindowID == nil)
        // Closing the primary later moves nothing of it.
        fixture.registry.close(fixture.primary.id, in: fixture.session)
        #expect(other.selection.projectID == fixture.b.id)
        fixture.expectInvariants()
    }

    @Test func removingTheShownProjectOnAScratchTab_keepsThatTabAndItsTerminalDrawnAndSeen() throws {
        let fixture = Fixture()
        _ = fixture.scratchTab()
        // The second scratch tab, so that staying on the first one would
        // not pass for staying on the one the window was on.
        let scratch = fixture.scratchTab()
        fixture.choose(scratch, in: fixture.primary)
        _ = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        fixture.registry.didReportDisplay(window: fixture.primary.id, rendered: [pane], attended: [pane])

        // No project is left for the window: it stays on its scratch tab,
        // which its view has no reason to report again.
        fixture.session.removeProject(fixture.a.id)

        #expect(fixture.primary.selection.shownProjectID == nil)
        #expect(fixture.primary.selection.activeContainerID == .loose)
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.registry.visibility.union.contains(pane))
        #expect(fixture.registry.attention.attendedPanes.contains(pane))
    }

    @Test func removingTheLastProjectAWindowCouldTake_leavesItShowingNothing() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let second = try fixture.window(showing: fixture.b)
        let third = try fixture.window(showing: fixture.c)

        fixture.session.removeProject(fixture.c.id)

        // "Open a Project": on the scratch row, drawing none of
        // its tabs until the person chooses them.
        #expect(third.selection.shownProjectID == nil)
        #expect(third.selection.isChoosingProject)
        #expect(third.selection.activeContainerID == .loose)
        #expect(third.selection.activeTabID == nil)
        #expect(!fixture.session.windows(showing: scratch.id).contains(third.id))
        #expect(second.selection.shownProjectID == fixture.b.id)
        fixture.expectInvariants()
    }
}

/// The scratch tabs across a switch, and what the window lets go of and
/// keeps as it switches.
extension WindowProjectSwitchTests {

    // MARK: - The scratch tabs

    @Test func aScratchTabChosenInAProject_isRememberedForIt() {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        fixture.choose(scratch, in: fixture.primary)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeContainerID == .loose)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == scratch.id)
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeContainerID == .loose)
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.session.showsScratch(in: fixture.primary.id))
    }

    @Test func switchingBackToAProjectLeftOnScratch_doesNotTakeTheScratchFromAnotherWindow() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let other = try fixture.window(showing: fixture.c)
        // The primary chooses the scratch tab, then goes to `b`, leaving
        // the scratch tabs.
        fixture.choose(scratch, in: fixture.primary)
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.session.scratchOwnerWindowID == nil)
        // The other window comes to the scratch tab without choosing it.
        fixture.session.setActiveTab(scratch.id, in: other.id, intent: .repair)
        #expect(fixture.session.scratchDrawingWindowID == other.id)

        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        // The primary is back on the scratch tab it left, but coming back is
        // not choosing it: the window drawing the scratch tabs is kept as
        // their keeper, so it goes on drawing them, and the primary says
        // they are open there.
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.session.scratchOwnerWindowID == other.id)
        #expect(fixture.session.scratchDrawingWindowID == other.id)
        #expect(!fixture.session.showsScratch(in: fixture.primary.id))
        // "Show Here" still takes them.
        fixture.session.claimScratch(for: fixture.primary.id)
        #expect(fixture.session.scratchDrawingWindowID == fixture.primary.id)
    }

    // MARK: - What the window holds

    @Test func switching_clearsThisWindowsReportedPanesFirst() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        let aPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let cPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        fixture.registry.didReportDisplay(window: fixture.primary.id, rendered: [aPane], attended: [aPane])
        fixture.registry.didReportDisplay(window: other.id, rendered: [cPane], attended: [cPane])
        var reportedAsItLeft: Set<UUID> = []
        fixture.registry.onWillSwitchProject = { _, _, _ in
            reportedAsItLeft = fixture.registry.visibility.union
        }

        fixture.choose(fixture.bTab, in: fixture.primary)

        // Told while the project it leaves was still its own; then its panes
        // stop counting, until it reports what it shows of the next one.
        #expect(reportedAsItLeft.contains(aPane))
        #expect(!fixture.registry.visibility.union.contains(aPane))
        #expect(!fixture.registry.attention.attendedPanes.contains(aPane))
        #expect(fixture.registry.visibility.union.contains(cPane))
        #expect(fixture.registry.attention.attendedPanes.contains(cPane))
    }

    @Test func switching_closesTheRowsCardAndTheFloatingSurfaces_butKeepsTheHistoryAndTheSheet() async throws {
        let fixture = Fixture()
        let approvals = ApprovalPresentationStore()
        fixture.tidiesAsTheAppDoes()
        let window = fixture.primary
        let other = try fixture.window(showing: fixture.c)
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        approvals.receive([request])
        window.approvalCard.updateRowAnchor(CGRect(x: 0, y: 40, width: 200, height: 20), for: request, in: approvals)
        window.approvalCard.present(request, from: approvals)
        // The other window's card stood beside the Needs Attention pill.
        other.approvalCard.present(request, from: approvals, openedFrom: CGRect(x: 0, y: 0, width: 40, height: 20))
        window.titleBarMenu = TitleBarMenuRequest(menu: .project, anchor: .zero)
        window.isAllProjectsPresented = true
        fixture.session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window.id)
        window.paneRename.open(paneID: UUID(), name: "pane", anchor: .zero)
        window.containerColor.open(projectID: fixture.a.id, anchor: .zero)
        window.restoreFocusRequest = UUID()
        window.sidebarFocusRequest = UUID()
        window.reviewOpenRequest = ReviewOpenRequest(containerID: .project(fixture.a.id), tabID: fixture.aTab.id)
        window.isSidebarKeptOverPanel = true
        window.notificationHistory.isPresented = true
        window.keyboardShortcuts.isPresented = true
        window.openNewWorktreeSheet(NewSessionSheetRequest(projectID: fixture.a.id))
        let aPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let cPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let item = AttentionItemID.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))
        window.decisionBarSelection[aPane] = item
        window.decisionBarDone[aPane] = .answeredInTerminal
        window.restoreStrips[aPane] = RestoreStrip(turnID: TurnID("t"))
        window.decisionBarSelection[cPane] = item
        let scratch = fixture.scratchTab()
        let scratchPane = try #require(scratch.splitTree.allLeafIDs().first)
        window.decisionBarSelection[scratchPane] = item
        window.restoreStrips[scratchPane] = RestoreStrip(turnID: TurnID("s"))
        window.promptCachePanel.open(
            target: PromptCacheTarget(runtimeID: "a", paneID: aPane),
            place: .paneHeader(paneID: aPane),
            clock: .init(instance: UUID(), frame: .zero),
            trigger: .pointer
        )
        window.prHover.rowEntered(
            rowID: PRHoverSource(container: .project(fixture.a.id)),
            info: PRInfoFixture.make(),
            anchor: .zero,
            delay: .zero
        )
        await pollUntil { window.prHover.visible != nil }
        #expect(window.prHover.visible != nil)

        fixture.choose(fixture.bTab, in: window)

        #expect(window.approvalCard.presentedApproval(in: approvals) == nil)
        // The sidebar lists every project, so the row is still where it
        // was, and opening its card again stands beside it.
        #expect(window.approvalCard.rowAnchor(for: request) == CGRect(x: 0, y: 40, width: 200, height: 20))
        #expect(approvals.pending.map(\.id) == [request.id])
        #expect(window.titleBarMenu == nil)
        #expect(!window.isAllProjectsPresented)
        #expect(!window.keyboardShortcuts.isPresented, "it holds the keyboard the next project's pane is handed")
        #expect(fixture.session.commandPaletteState == nil)
        #expect(window.paneRename.request == nil)
        #expect(window.containerColor.request == nil)
        #expect(window.restoreFocusRequest == nil)
        #expect(window.sidebarFocusRequest == nil)
        #expect(window.reviewOpenRequest == nil)
        // The sidebar kept over the panel is the window's chrome, as the
        // panel is: it stays.
        #expect(window.isSidebarKeptOverPanel)
        #expect(window.promptCachePanel.request == nil)
        #expect(window.prHover.visible == nil)
        // The bars and strips of `a`'s panes go; another project's stay.
        #expect(window.decisionBarSelection[aPane] == nil)
        #expect(window.decisionBarDone[aPane] == nil)
        #expect(window.restoreStrips[aPane] == nil)
        #expect(window.decisionBarSelection[cPane] == item)
        // A scratch tab's are no project's: the window can still show it.
        #expect(window.decisionBarSelection[scratchPane] == item)
        #expect(window.restoreStrips[scratchPane] == RestoreStrip(turnID: TurnID("s")))
        // The window's own: the history and the new session sheet, which
        // makes its session in `a` still.
        #expect(window.notificationHistory.isPresented)
        #expect(window.newSession?.projectID == fixture.a.id)
        // Another window's card is its own.
        #expect(other.approvalCard.presentedApproval(in: approvals)?.id == request.id)
    }

    @Test func theNewSessionSheetsOfARemovedProject_closeInEveryWindow() throws {
        let fixture = Fixture()
        fixture.tidiesAsTheAppDoes()
        let other = try fixture.window(showing: fixture.c)
        fixture.primary.openNewWorktreeSheet(NewSessionSheetRequest(projectID: fixture.a.id))
        other.openNewWorktreeSheet(NewSessionSheetRequest(projectID: fixture.a.id))
        let kept = NewSessionSheetRequest(projectID: fixture.c.id)

        fixture.session.removeProject(fixture.a.id)
        // As the app does when the projects change.
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.primary.newSession == nil)
        #expect(other.newSession == nil)
        other.openNewWorktreeSheet(kept)
        fixture.registry.forgetProjectsGone(in: fixture.session)
        #expect(other.newSession == kept)
    }

    @Test func aCardOpenedFromTheNeedsAttentionPill_staysThroughTheSwitch() {
        let fixture = Fixture()
        let approvals = ApprovalPresentationStore()
        fixture.tidiesAsTheAppDoes()
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        approvals.receive([request])
        fixture.primary.approvalCard.present(request, from: approvals, openedFrom: CGRect(x: 0, y: 0, width: 40, height: 20))

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.approvalCard.presentedApproval(in: approvals)?.id == request.id)
    }

    @Test func theProjectViewsInvariant_holdsAfterEverySwitch() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        fixture.expectInvariants()
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.expectInvariants()
        let other = try fixture.window(showing: fixture.c)
        fixture.expectInvariants()
        fixture.choose(fixture.aOther, in: fixture.primary)
        fixture.expectInvariants()
        fixture.choose(fixture.bTab, in: other)
        fixture.expectInvariants()
        fixture.choose(scratch, in: other)
        fixture.expectInvariants()
        fixture.choose(fixture.cTab, in: fixture.primary)
        fixture.expectInvariants()
        fixture.registry.close(other.id, in: fixture.session)
        fixture.expectInvariants()
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.expectInvariants()
        fixture.session.removeProject(fixture.b.id)
        fixture.expectInvariants()
        #expect(fixture.primary.selection.shownProjectID != nil)
    }
}

/// What a switch told the app layer, and whether it was inside the switch
/// as drawn (`WindowRegistry.drawsSwitch`).
@MainActor
private final class SwitchCalls {
    var isSwitching = false
    var told: [String] = []
}
