// WindowRegistryTests.swift
// Weir — a project in one window at a time: switched to in place or
// brought forward, never a second; and the window a request, news, or a
// command is taken in.

import Combine
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct WindowRegistryTests {
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let registry: WindowRegistry
        let presenter = RecordingWindowPresenter()
        let first: Project
        let second: Project

        init() {
            let (session, first) = WorkspaceSessionFixture.withProject(name: "first")
            session.openTab(container: .project(first.id))
            second = session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("second"),
                suggestedName: "second"
            )
            self.session = session
            self.first = first
            registry = WindowRegistry(primary: session.primarySelection)
            registry.presenter = presenter
            registry.show(registry.primary.id)
        }
    }

    /// Switching in place itself is `choosingAnotherProjectFromTheMenu_switchesThisWindow_andOpensNone`,
    /// on a project with a session. This one has none: it opens with nothing
    /// open, not a tab made for it.
    @Test func aProjectWithNoSessionYet_opensOnItsFolder_withNoTabMadeForIt() {
        let fixture = Fixture()
        fixture.registry.connectProjectSwitching(of: fixture.session)

        fixture.registry.show(project: fixture.second.id, in: fixture.session, from: fixture.registry.primary, intent: .person)

        let selection = fixture.session.primarySelection
        #expect(selection.shownProjectID == fixture.second.id)
        #expect(selection.activeContainerID == .project(fixture.second.id))
        #expect(selection.activeTabID == nil)
        // The project left keeps what the window showed of it.
        #expect(fixture.session.projectViews[fixture.first.id] != nil)
    }

    @Test func withEveryWindowHidden_theWindowAskedSwitchesInPlace_andComesBack() {
        let fixture = Fixture()
        fixture.registry.connectProjectSwitching(of: fixture.session)
        fixture.registry.hide(fixture.registry.primary.id)
        fixture.presenter.shown = []

        // The File menu's ⌘O asks of the window commands act on.
        let window = fixture.registry.show(project: fixture.second.id, in: fixture.session, from: nil, intent: .person)

        #expect(window === fixture.registry.primary)
        #expect(!fixture.registry.primary.isHidden)
        #expect(fixture.presenter.shown == [fixture.registry.primary.id])
        #expect(fixture.session.primarySelection.shownProjectID == fixture.second.id)
        #expect(fixture.registry.windows.count == 1)
    }

    /// The window is where the person asked from, so there is nothing to
    /// bring forward (`bringOnScreen`), and nothing switches.
    @Test func theProjectOfTheWindowAskedFrom_leavesThatWindowAsItIs() {
        let fixture = Fixture()
        fixture.registry.connectProjectSwitching(of: fixture.session)
        fixture.presenter.shown = []

        let window = fixture.registry.show(project: fixture.first.id, in: fixture.session, from: fixture.registry.primary, intent: .person)

        #expect(window === fixture.registry.primary)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.session.projectViews.isEmpty)
    }

    @Test func aProjectShownForTheFirstTime_opensOnTheSessionLastUsed() {
        let fixture = Fixture()
        fixture.registry.connectProjectSwitching(of: fixture.session)
        let tab = fixture.session.openTab(
            container: .project(fixture.second.id),
            in: fixture.registry.primary.id,
            intent: .person,
            selects: false
        )
        fixture.session.openTab(container: .project(fixture.first.id))

        fixture.registry.show(project: fixture.second.id, in: fixture.session, from: fixture.registry.primary, intent: .person)

        #expect(fixture.session.primarySelection.activeTabID == tab.id)
    }

    @Test func aWindowShowingNoProjectYet_takesTheFirstProjectOpened() {
        let session = WorkspaceSession()
        session.openTab(container: .loose)
        let registry = WindowRegistry(primary: session.primarySelection)
        let presenter = RecordingWindowPresenter()
        registry.presenter = presenter
        registry.connectProjectSwitching(of: session)
        let project = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("first")
        )

        let window = registry.show(project: project.id, in: session, from: registry.primary, intent: .person)

        // No second window: the first window, which showed no project,
        // switches to it.
        #expect(window === registry.primary)
        #expect(registry.windows.count == 1)
        #expect(session.primarySelection.shownProjectID == project.id)
    }

    @Test func aProjectTheSessionDoesNotHave_showsNothing() {
        let fixture = Fixture()
        fixture.registry.connectProjectSwitching(of: fixture.session)
        fixture.registry.hide(fixture.registry.primary.id)

        let window = fixture.registry.show(project: UUID(), in: fixture.session, from: nil, intent: .person)

        #expect(window == nil)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.registry.primary.isHidden)
        #expect(fixture.session.primarySelection.shownProjectID == fixture.first.id)
    }

    @Test func workBehindThePerson_orAWindowThatClosed_showsNothing() throws {
        let fixture = Fixture()
        fixture.registry.connectProjectSwitching(of: fixture.session)
        let closing = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        let third = fixture.session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("third")
        )
        fixture.registry.close(closing.id, in: fixture.session)
        fixture.presenter.shown = []

        let behind = fixture.registry.show(project: third.id, in: fixture.session, from: fixture.registry.primary, intent: .behind)
        let fromClosed = fixture.registry.show(project: third.id, in: fixture.session, from: closing, intent: .person)

        #expect(behind == nil)
        #expect(fromClosed == nil)
        #expect(fixture.session.primarySelection.shownProjectID == fixture.first.id)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.presenter.shown.isEmpty)
    }

    @Test func whatBelongsToNoProject_isShownInTheWindowAskedFrom_broughtBack() {
        let fixture = Fixture()
        fixture.registry.hide(fixture.registry.primary.id)

        let window = fixture.registry.bringBack(fixture.registry.primary)

        #expect(window === fixture.registry.primary)
        #expect(!window.isHidden)
        // It stays on the project it showed.
        #expect(fixture.session.primarySelection.shownProjectID == fixture.first.id)
        #expect(fixture.registry.windows.count == 1)
    }

    @Test func registry_startsWithOnlyThePrimary() {
        let primaryID = WindowID()
        let registry = WindowRegistry(primaryID: primaryID)

        #expect(registry.windows.map(\.id) == [primaryID])
        #expect(registry.window(primaryID) === registry.primary)
        #expect(registry.window(WindowID()) == nil)
        #expect(!registry.primary.isHidden)
    }
}

/// Where a request or app-wide news is told: never in a hidden window
/// while another is shown.
@MainActor
extension WindowRegistryTests {
    @Test func aPanesRequest_isAskedInTheWindowDrawingIt() throws {
        let fixture = Fixture()
        let tab = try #require(fixture.session.activeTab(in: fixture.session.primaryWindowID))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let second = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        fixture.registry.windowBecameKey(second.id)

        #expect(fixture.registry.requestWindow(forPane: pane, in: fixture.session) === fixture.registry.primary)
    }

    @Test func aRequestFromAPaneNoShownWindowDraws_isAskedInTheWindowUsedLast() throws {
        let fixture = Fixture()
        let tab = try #require(fixture.session.activeTab(in: fixture.session.primaryWindowID))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let background = fixture.session.openTab(container: .project(fixture.first.id))
        fixture.session.setActiveTab(tab.id)
        let backgroundPane = try #require(background.splitTree.allLeafIDs().first)
        let second = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        fixture.registry.windowBecameKey(fixture.registry.primary.id)
        fixture.registry.windowBecameKey(second.id)

        // A tab behind another: the window used last asks.
        #expect(fixture.registry.requestWindow(forPane: backgroundPane, in: fixture.session) === second)

        // The pane's own window hidden: a shown one asks instead.
        fixture.registry.hide(fixture.registry.primary.id)
        fixture.session.setWindow(fixture.registry.primary.id, isHidden: true)
        #expect(fixture.registry.requestWindow(forPane: pane, in: fixture.session) === second)
        #expect(fixture.registry.noticeWindow === second)
    }

    /// Which window app-wide news goes to, with the primary, a second
    /// window, and a third (0, 1, 2) used in `keyOrder`: the one used most
    /// recently that is shown, beside a window closing or not, and the
    /// primary when every window is hidden.
    struct NewsCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let keyOrder: [Int]
        let hidden: [Int]
        /// The window closing, which the news is told beside; nil asks for
        /// the notice window with none closing.
        let besides: Int?
        let expected: Int?
    }

    nonisolated static let newsCases: [NewsCase] = [
        NewsCase(
            testDescription: "beside the window in front, the one used before it",
            keyOrder: [1, 0, 2], hidden: [], besides: 2, expected: 0
        ),
        NewsCase(
            testDescription: "beside a window, with every other hidden, none",
            keyOrder: [1, 0, 2], hidden: [0, 1], besides: 2, expected: nil
        ),
        NewsCase(
            testDescription: "past a hidden window used last",
            keyOrder: [2, 0, 1], hidden: [1], besides: nil, expected: 0
        ),
        NewsCase(
            testDescription: "every window hidden, the primary",
            keyOrder: [2, 0, 1], hidden: [0, 1, 2], besides: nil, expected: 0
        )
    ]

    @Test(arguments: newsCases)
    func theNews_goesToTheShownWindowUsedMostRecently(_ news: NewsCase) throws {
        let fixture = Fixture()
        let second = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        let windows = [fixture.registry.primary, second, fixture.registry.addWindow(WindowID())]
        for index in news.keyOrder {
            fixture.registry.windowBecameKey(windows[index].id)
        }
        for index in news.hidden {
            fixture.registry.hide(windows[index].id)
        }

        let told: ProjectWindowState? = if let besides = news.besides {
            fixture.registry.windowShown(besides: windows[besides].id)
        } else {
            fixture.registry.noticeWindow
        }

        #expect(told?.id == news.expected.map { windows[$0].id })
    }

    @Test func aNoticeStaysInItsWindow_untilThatWindowIsHidden() throws {
        let fixture = Fixture()
        let second = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        let placed = fixture.registry.placeNotice(keeping: nil) { fixture.registry.primary }
        #expect(placed == fixture.registry.primary.id)

        // The keyboard moving on leaves it where it is.
        fixture.registry.windowBecameKey(second.id)
        #expect(fixture.registry.placeNotice(keeping: placed) { second } == placed)

        fixture.registry.hide(placed)
        #expect(fixture.registry.placeNotice(keeping: placed) { second } == second.id)
    }

    // MARK: - A command for a window's views

    @Test func aCommandNoViewTakes_isReportedAsNotRun() {
        let registry = WindowRegistry(primary: WindowSelection())

        #expect(!registry.perform(.toggleAllProjects, in: registry.primary.id))
        #expect(!registry.perform(.toggleAllProjects, in: WindowID()), "a window that is not open")
    }

    @Test func aCommandOneViewTook_isNotHandedToTheNext() {
        let registry = WindowRegistry(primary: WindowSelection())
        var takers: [String] = []
        let first = registry.primary.commands.requests.sink { request in
            guard !request.isTaken else { return }
            takers.append("first")
            request.take()
        }
        let second = registry.primary.commands.requests.sink { request in
            guard !request.isTaken else { return }
            takers.append("second")
            request.take()
        }
        defer {
            first.cancel()
            second.cancel()
        }

        #expect(registry.perform(.focusSidebar, in: registry.primary.id))
        #expect(takers.count == 1)
    }
}
