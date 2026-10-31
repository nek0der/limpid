// OpenInNewWindowTests.swift
// Weir — a project opened in a new window on request, and a window that shows nothing until the person chooses.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

/// A new window opens only when the person asks for one:
/// ⌘-click or ⌘Return on another project's row opens the project in a new
/// window, on what it showed last; New Window opens a window that shows
/// nothing until the person chooses a project or the scratch tabs. A
/// project another window shows brings that window forward instead, and
/// a window that shows nothing is saved only when no other window is, on
/// the scratch row.
@MainActor
struct OpenInNewWindowTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - A project in a new window

    @Test func aCommandClick_opensTheProjectInANewWindow_onWhatItShowedLast() throws {
        let fixture = Fixture()
        let (review, _) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.primary.review = review
        fixture.session.setActiveTab(fixture.aOther.id, in: fixture.primary.id, intent: .person)
        fixture.primary.selection.sidebarWidth = 311
        fixture.primary.selection.isChangesPanelPresented = true
        fixture.primary.scrollPlace.changesTurn = TurnID("t1")
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(
            projectOrder: [fixture.c.id, fixture.b.id, fixture.a.id],
            collapsedProjects: [fixture.c.id]
        )
        // The window leaves `a`, which keeps its view, its review tab, and
        // where its list was.
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.primary.selection.sidebarWidth = 250
        #expect(fixture.session.projectViews[fixture.a.id] != nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id] != nil)
        #expect(fixture.registry.scrollMemories[fixture.a.id] != nil)

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.a.id, in: fixture.session, from: fixture.primary))

        #expect(opened !== fixture.primary)
        #expect(fixture.registry.windows.count == 2)
        #expect(fixture.presenter.shown == [opened.id])
        #expect(opened.selection.shownProjectID == fixture.a.id)
        #expect(opened.selection.activeTabID == fixture.aOther.id)
        // The chrome is the window's it was opened from, as it is now, not
        // the one `a` was left with.
        #expect(opened.selection.sidebarWidth == 250)
        #expect(opened.selection.isChangesPanelPresented)
        #expect(!opened.selection.isChoosingProject)
        // What `a` kept now belongs to the new window: it is kept only for a
        // project no window shows.
        #expect(opened.review?.opening == review.opening)
        #expect(opened.scrollRestore?.projectID == fixture.a.id)
        #expect(opened.scrollRestore?.memory.changes?.place.row == TurnID("t1"))
        // The sidebar's order and folds are the window's it was opened from
        // too, `a`'s header opened as the window takes it, and `b`, which
        // the window it came from shows, folded as another window's.
        #expect(opened.selection.sidebarArrangement.projectOrder == [fixture.c.id, fixture.b.id, fixture.a.id])
        #expect(opened.selection.sidebarArrangement.collapsedProjects == [fixture.c.id, fixture.b.id])
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id] == nil)
        #expect(fixture.registry.scrollMemories[fixture.a.id] == nil)
        // The window asked stays on its own project.
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        fixture.expectInvariants()
    }

    @Test func aProjectShownForTheFirstTime_inANewWindow_takesTheChromeOfTheWindowAsked_butNotItsFrame() throws {
        let fixture = Fixture()
        fixture.primary.selection.sidebarWidth = 290
        fixture.primary.selection.sidebarHidden = true
        fixture.primary.selection.isChangesPanelPresented = true
        fixture.primary.selection.changesPanelWidth = 360
        fixture.primary.selection.frame = CGRect(x: 10, y: 20, width: 900, height: 700)
        fixture.primary.selection.isFullScreen = true

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: fixture.primary))

        #expect(opened.selection.activeTabID == fixture.bTab.id)
        #expect(opened.selection.sidebarWidth == 290)
        #expect(opened.selection.sidebarHidden)
        #expect(opened.selection.isChangesPanelPresented)
        #expect(opened.selection.changesPanelWidth == 360)
        // Placed by the presenter on the asking window's screen, and never
        // in full screen of its own.
        #expect(opened.selection.frame == nil)
        #expect(!opened.selection.isFullScreen)
        // Used by the person: it is the most recent project.
        #expect(fixture.session.recentProjectPaths.first?.standardizedFileURL == fixture.b.rootURL.standardizedFileURL)
    }

    @Test func aProjectAnotherWindowShows_bringsThatWindowForward_hiddenOrNot() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        fixture.registry.hide(other.id)

        let shown = fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: fixture.primary)

        #expect(shown === other)
        #expect(!other.isHidden)
        #expect(fixture.presenter.shown == [other.id])
        #expect(fixture.registry.windows.count == 2)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    @Test func theProjectOfTheWindowAsked_doesNothing() {
        let fixture = Fixture()

        let shown = fixture.registry.openInNewWindow(project: fixture.a.id, in: fixture.session, from: fixture.primary)

        #expect(shown === fixture.primary)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
    }

    @Test func aProjectGone_orAWindowClosed_opensNothing() throws {
        let fixture = Fixture()
        let closing = try fixture.window(showing: fixture.c)
        fixture.registry.close(closing.id, in: fixture.session)

        #expect(fixture.registry.openInNewWindow(project: UUID(), in: fixture.session, from: fixture.primary) == nil)
        #expect(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: closing) == nil)
        #expect(fixture.registry.windows.count == 1)
    }

    @Test func theNewWindow_isPlacedFromTheWindowAsked() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: other))
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: other)

        // Cascaded from it, on its screen (`ProjectWindowPresenter`).
        #expect(fixture.presenter.openedFrom[opened.id] == other.id)
        #expect(fixture.presenter.openedFrom[empty.id] == other.id)
    }

    @Test func askedOfAHiddenWindow_itSwitchesInPlace_andComesBack() {
        let fixture = Fixture()
        fixture.registry.hide(fixture.primary.id)

        let shown = fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: fixture.primary)

        // No window beside the hidden one.
        #expect(shown === fixture.primary)
        #expect(fixture.registry.windows.count == 1)
        #expect(!fixture.primary.isHidden)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
    }

    // MARK: - New Window

    @Test func newWindow_showsNothing_andOffersOnlyTheProjectsNoOtherWindowShows() throws {
        let fixture = Fixture()
        _ = try fixture.window(showing: fixture.c)
        fixture.presenter.shown = []

        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        #expect(fixture.registry.windows.count == 3)
        #expect(fixture.presenter.shown == [empty.id])
        #expect(empty.selection.isChoosingProject)
        #expect(empty.selection.shownProjectID == nil)
        #expect(empty.selection.activeTabID == nil)
        let offered = EmptyWindowModel(session: fixture.session, window: empty.selection).rows.map(\.id)
        #expect(offered == [fixture.b.id])
        fixture.expectInvariants()
    }

    @Test func aRemovedProjectsHeir_isTheMostRecentNoWindowShows_whileAnEmptyWindowListsThemInItsSidebarsOrder() throws {
        let fixture = Fixture()
        let d = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("d"), suggestedName: "d")
        fixture.session.recentProjectPaths = [fixture.b.rootURL, fixture.a.rootURL]

        // Those no window shows: the recent ones first, then the session's
        // order (`d` is not in the recent list).
        let free = fixture.session.projectsNoWindowShows(besides: nil).map(\.id)
        #expect(free == [fixture.b.id, fixture.c.id, d.id])
        // The empty window lists them in its sidebar's order instead.
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [d.id, fixture.c.id])
        #expect(EmptyWindowModel(session: fixture.session, window: fixture.primary.selection).rows.map(\.id) == [
            d.id, fixture.c.id, fixture.b.id
        ])

        // A window whose project is removed takes the first of them.
        let other = try fixture.window(showing: fixture.c)
        fixture.session.removeProject(fixture.c.id)
        #expect(other.selection.shownProjectID == fixture.b.id)
    }

    @Test func newWindow_withEveryWindowHidden_bringsTheHiddenOneBack() {
        let fixture = Fixture()
        fixture.registry.close(fixture.primary.id, in: fixture.session)
        #expect(fixture.primary.isHidden)

        let shown = fixture.registry.openEmptyWindow(in: fixture.session, from: nil)

        #expect(shown === fixture.primary)
        #expect(!fixture.primary.isHidden)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
    }

    @Test func aWindowThatShowsNothing_drawsNoScratchTab_untilTheScratchIsChosen() {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        #expect(!fixture.session.showsScratch(in: empty.id))
        #expect(fixture.session.scratchDrawingWindowID == nil)
        #expect(!fixture.session.shownTabIDs.contains(scratch.id))
        #expect(!fixture.session.shownContainerIDs.contains(.loose))
        #expect(fixture.session.windows(showing: scratch.id).isEmpty)

        // The sidebar's scratch row.
        fixture.session.setActiveContainer(.loose, in: empty.id, intent: .person)

        #expect(!empty.selection.isChoosingProject)
        #expect(empty.selection.activeTabID == scratch.id)
        #expect(fixture.session.scratchDrawingWindowID == empty.id)
        #expect(fixture.session.shownTabIDs.contains(scratch.id))
    }

    @Test func choosingAProject_inAWindowThatShowsNothing_showsItThere() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        fixture.presenter.shown = []

        let shown = fixture.registry.show(project: fixture.b.id, in: fixture.session, from: empty, intent: .person)

        #expect(shown === empty)
        #expect(!empty.selection.isChoosingProject)
        #expect(empty.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.windows.count == 2)
        fixture.expectInvariants()
    }

    @Test func aScratchTabOpenedBehind_whileAWindowShowsNothing_isTheOneChoosingTheRowOpens() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        // A window that shows nothing holds no row, so nothing keeps the
        // scratch row on a tab it shows.
        #expect(!fixture.session.holdsSelection(of: .loose))
        let opened = fixture.scratchTab()
        #expect(fixture.session.tabOpened(choosing: .loose) == opened.id)

        // The sidebar's scratch row.
        fixture.session.setActiveContainer(.loose, in: empty.id, intent: .person)

        #expect(empty.selection.activeTabID == opened.id)
        #expect(fixture.session.holdsSelection(of: .loose))
    }

    @Test func aWindowThatShowsNothing_isNotSaved() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        let snapshot = fixture.session.makeSnapshot()

        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.projectID == fixture.a.id)
        #expect(!fixture.session.savedWindowIDs.contains(empty.id))
    }

    /// A session of one project with a tab of its own, which the primary
    /// shows, and the windows connected to it as the app does.
    private struct OneProject {
        let session: WorkspaceSession
        let project: Project
        let projectTab: Tab
        let registry: WindowRegistry
    }

    /// The project is named `name`; `connecting` adds to the session before
    /// the windows are connected.
    private static func oneProject(
        _ name: String,
        before connecting: (WorkspaceSession, Project) -> Void = { _, _ in }
    ) -> OneProject {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL(name), suggestedName: name)
        let projectTab = session.openTab(container: .project(project.id))
        connecting(session, project)
        session.primarySelection.projectID = project.id
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        registry.connectProjectSwitching(of: session)
        return OneProject(session: session, project: project, projectTab: projectTab, registry: registry)
    }

    @Test func aRemovedProjectWithNowhereToGo_leavesItsWindowShowingNothing() {
        let scene = Self.oneProject("only")
        let session = scene.session

        session.removeProject(scene.project.id)
        withExtendedLifetime(scene.registry) {}

        #expect(session.primarySelection.isChoosingProject)
        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.primarySelection.activeTabID == nil)
        #expect(EmptyWindowModel(session: session, window: session.primarySelection).rows.isEmpty)
    }

    // MARK: - Launch

    @Test func aLaunchWithNoTab_makesAScratchTab_asBefore() throws {
        let session = WorkspaceSession()
        session.restore(from: SessionSnapshot(projects: [], tabs: []))

        let made = try #require(session.openLaunchTabIfNone())

        #expect(session.activeTab(in: session.primaryWindowID)?.id == made.id)
        #expect(made.container == .loose)
        #expect(!session.primarySelection.isChoosingProject)
        #expect(session.scratchDrawingWindowID == session.primaryWindowID)
        // Any tab at all, and the launch makes none.
        #expect(session.openLaunchTabIfNone() == nil)
        #expect(session.tabs.count == 1)
    }

    @Test func aPrimaryThatShowedNothing_comesBackOnTheScratchTabs() throws {
        var scratchTab: Tab?
        let scene = Self.oneProject("only") { session, only in
            scratchTab = session.openTab(container: .loose, in: session.primaryWindowID, intent: .person, selects: false)
            session.setActiveContainer(.project(only.id))
        }
        let (session, scratch) = try (scene.session, #require(scratchTab))
        session.removeProject(scene.project.id)
        withExtendedLifetime(scene.registry) {}
        #expect(session.primarySelection.isChoosingProject)

        let restored = WorkspaceSession()
        restored.restore(from: session.makeSnapshot())

        #expect(!restored.primarySelection.isChoosingProject)
        #expect(restored.primarySelection.activeContainerID == .loose)
        #expect(restored.primarySelection.activeTabID == scratch.id)
        #expect(restored.scratchDrawingWindowID == restored.primaryWindowID)
    }

    @Test func onlyAWindowThatShowedNothing_withNoScratchTab_comesBackOnTheEmptyScratchRow() throws {
        let scene = Self.oneProject("kept")
        let session = scene.session
        let registry = scene.registry
        let empty = registry.openEmptyWindow(in: session, from: registry.primary)
        // The window on `kept` closes; the one that shows nothing is left.
        registry.close(registry.primary.id, in: session)
        #expect(registry.windows.map(\.id) == [empty.id])

        let snapshot = session.makeSnapshot()
        let record = try #require(snapshot.windows.first)
        #expect(snapshot.windows.count == 1)
        #expect(record.activeContainerID == .loose)
        #expect(record.activeTabID == nil)

        let restored = WorkspaceSession()
        let issue = restored.restore(from: snapshot)

        // The scratch row, empty, and not another project's tab with a
        // repair to report; the launch makes no tab, as there are some.
        #expect(issue == nil)
        #expect(restored.primarySelection.activeContainerID == .loose)
        #expect(restored.primarySelection.activeTabID == nil)
        #expect(restored.openLaunchTabIfNone() == nil)
        #expect(restored.tabs.map(\.id) == [scene.projectTab.id])
    }

    // MARK: - The palette and the lists

    @Test func thePalettesCommandReturn_opensAnotherProjectsRowInANewWindow() throws {
        let fixture = Fixture()
        func run(_ action: CommandPaletteAction) -> PaletteRowHandling {
            SupervisionWindowActions.runProjectRow(
                action,
                in: fixture.primary,
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil,
                opensInNewWindow: true
            )
        }

        // "#": a project.
        #expect(run(.activateProject(fixture.b.id)) == .handled)
        let forB = try #require(fixture.registry.window(showingProject: fixture.b.id, in: fixture.session))
        #expect(forB !== fixture.primary)
        // "@": a tab of another project, selected in its new window.
        #expect(run(.jumpToTab(fixture.cTab.id)) == .handled)
        let forC = try #require(fixture.registry.window(showingProject: fixture.c.id, in: fixture.session))
        #expect(forC.selection.activeTabID == fixture.cTab.id)
        // This window's own: as without ⌘.
        #expect(run(.activateProject(fixture.a.id)) == .handledReturningKeyboard)
        #expect(run(.jumpToTab(fixture.aOther.id)) == .notHandled)
        #expect(fixture.registry.windows.count == 3)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    @Test func theNeedsAttentionList_opensANewWindowOnlyForACommandClick() throws {
        let fixture = Fixture()
        let store = AttentionQueueStore()
        let navigator = SessionAttentionNavigator(session: fixture.session, registry: fixture.registry)
        store.navigator = navigator
        store.apply(
            .init(runtimes: [
                RuntimeFact.stopped("b", in: fixture.bTab, of: fixture.b),
                RuntimeFact.stopped("c", in: fixture.cTab, of: fixture.c)
            ]),
            announces: false
        )
        let itemB = try #require(store.queue.items.first { $0.subject.projectID == fixture.b.id })
        let itemC = try #require(store.queue.items.first { $0.subject.projectID == fixture.c.id })

        // Return, with ⌘ or without, opens the row as a click does: here.
        store.focus(itemB, from: fixture.primary)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)

        // ⌘-click: a window of its own, on the item.
        store.focus(itemC, from: fixture.primary, opensInNewWindow: true)
        let forC = try #require(fixture.registry.window(showingProject: fixture.c.id, in: fixture.session))
        #expect(forC !== fixture.primary)
        #expect(forC.selection.activeTabID == fixture.cTab.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(forC.cursor.current == itemC.id)
    }

    @Test func aRowSaysItOpensInANewWindow_onlyWhereItWould() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        let store = AttentionQueueStore()
        store.apply(.init(runtimes: [
            RuntimeFact.stopped("a", in: fixture.aTab, of: fixture.a),
            RuntimeFact.stopped("b", in: fixture.bTab, of: fixture.b),
            RuntimeFact.stopped("c", in: fixture.cTab, of: fixture.c)
        ]), announces: false)

        let model = NeedsAttentionListModel(
            queue: store.queue,
            session: fixture.session,
            approvals: ApprovalPresentationStore(),
            projectsInOtherWindows: fixture.registry.projectsShown(besides: fixture.primary.id, in: fixture.session),
            windowProjectID: .some(fixture.primary.selection.shownProjectID),
            locale: Locale(identifier: "en")
        )
        let opens = { (project: Project) in
            model.rows.first { row in store.queue.items.first { $0.id == row.id }?.subject.projectID == project.id }?.opensInNewWindow
        }

        #expect(opens(fixture.a) == false)
        #expect(opens(fixture.b) == true)
        #expect(opens(fixture.c) == false)
        #expect(other.selection.shownProjectID == fixture.c.id)

        // Outside a window (the menu bar), no row opens one.
        let outside = NeedsAttentionListModel(
            queue: store.queue,
            session: fixture.session,
            approvals: ApprovalPresentationStore(),
            windowProjectID: nil,
            locale: Locale(identifier: "en")
        )
        #expect(outside.rows.allSatisfy { !$0.opensInNewWindow })

        // The menu bar, told which projects the windows show, says it of an
        // item of a project none shows.
        let menuBar = NeedsAttentionListModel(
            queue: store.queue,
            session: fixture.session,
            approvals: ApprovalPresentationStore(),
            windowProjectID: nil,
            projectsInWindows: fixture.registry.projectsShown(besides: nil, in: fixture.session),
            locale: Locale(identifier: "en")
        )
        let opensFromMenuBar = { (project: Project) in
            menuBar.rows.first { row in store.queue.items.first { $0.id == row.id }?.subject.projectID == project.id }?.opensInNewWindow
        }
        #expect(opensFromMenuBar(fixture.a) == false)
        #expect(opensFromMenuBar(fixture.b) == true)
        #expect(opensFromMenuBar(fixture.c) == false)
        #expect(menuBar.rows.map(\.placeLead) == outside.rows.map(\.placeLead))
    }

    @Test func onlyACommandClick_orItsVoiceOverAction_opensARowInANewWindow() {
        #expect(!NeedsAttentionListOpening.returnKey.opensInNewWindow)
        #expect(!NeedsAttentionListOpening.click(holdsCommand: false).opensInNewWindow)
        #expect(NeedsAttentionListOpening.click(holdsCommand: true).opensInNewWindow)
        #expect(NeedsAttentionListOpening.newWindowAction.opensInNewWindow)
    }

    @Test func thePalettesCommand_reachesTheWindowWithTheRow() {
        let window = WindowID()
        let state = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window)
        let commands = RecordingWindowCommands()
        let project = UUID()

        CommandPaletteActions.postExecution(of: .activateProject(project), from: state, opensInNewWindow: true, commands: commands)
        CommandPaletteActions.postExecution(of: .activateProject(project), from: state, commands: commands)

        #expect(commands.commands(in: window) == [
            .runPaletteRow(CommandPaletteExecution(action: .activateProject(project), windowID: window, opensInNewWindow: true)),
            .runPaletteRow(CommandPaletteExecution(action: .activateProject(project), windowID: window, opensInNewWindow: false))
        ])
        #expect(commands.performed.count == 2)
    }

}
