// TitleBarHistoryTests.swift
// Weir — the title bar's back and forward follow their window's history and act on that window.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
@Suite("Title bar back and forward")
struct TitleBarHistoryTests {
    /// Two loose tabs, A in front, and a second window beside the primary
    /// that has stepped from B to A, so its back side has B.
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let tabA: Weir.Tab
        let tabB: Weir.Tab
        let window: ProjectWindowState

        init() throws {
            let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
            let selection = WindowSelection()
            session.addSelection(selection)
            let window = ProjectWindowState(selection: selection)
            session.setActiveTab(tabB.id, in: window.id)
            let before = try #require(session.currentNavTarget(in: window.id))
            session.setActiveTab(tabA.id, in: window.id)
            session.recordNavigation(from: before, in: window.id)
            self.session = session
            self.tabA = tabA
            self.tabB = tabB
            self.window = window
        }

        var model: TitleBarHistoryModel {
            TitleBarHistoryModel(session: session, window: window.id)
        }
    }

    @Test func buttons_followTheWindowsHistory() throws {
        let fixture = try Fixture()
        #expect(fixture.model.canGoBack)
        #expect(!fixture.model.canGoForward)

        fixture.session.navigateBack(in: fixture.window.id, intent: .person)
        #expect(!fixture.model.canGoBack)
        #expect(fixture.model.canGoForward)

        fixture.session.navigateForward(in: fixture.window.id, intent: .person)
        #expect(fixture.model.canGoBack)
        #expect(!fixture.model.canGoForward)
    }

    /// A view that builds the model in its body hears of a step through
    /// the history, so its buttons turn on and off without anything else
    /// changing: the model reads the window's stacks through observation.
    @Test func buildingTheModel_observesTheHistory() throws {
        let fixture = try Fixture()
        let hasChanged = Recorded(false)
        withObservationTracking {
            _ = fixture.model
        } onChange: {
            hasChanged.value = true
        }

        fixture.session.navigateBack(in: fixture.window.id, intent: .person)

        #expect(hasChanged.value)
    }

    /// Another window's history turns nothing on here: the primary has
    /// none, though the second window has a step back.
    @Test func buttons_readOnlyTheirOwnWindow() throws {
        let fixture = try Fixture()
        let primary = TitleBarHistoryModel(session: fixture.session, window: fixture.session.primaryWindowID)
        #expect(!primary.canGoBack)
        #expect(!primary.canGoForward)
    }

    /// A window the session no longer lists has no history to walk.
    @Test func buttons_areOff_forAWindowTheSessionDoesNotKnow() {
        let session = WorkspaceSession()
        let model = TitleBarHistoryModel(session: session, window: WindowID())
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
    }

    /// The button acts on the window it is in, though the primary is the
    /// one the session shows first.
    @Test func goBack_stepsTheButtonsWindow_notThePrimary() throws {
        let fixture = try Fixture()
        let primaryTab = fixture.session.primarySelection.activeTabID

        SupervisionWindowActions.goBack(in: fixture.window, session: fixture.session)

        #expect(fixture.session.selection(fixture.window.id)?.activeTabID == fixture.tabB.id)
        #expect(fixture.session.primarySelection.activeTabID == primaryTab)

        SupervisionWindowActions.goForward(in: fixture.window, session: fixture.session)
        #expect(fixture.session.selection(fixture.window.id)?.activeTabID == fixture.tabA.id)
    }

    /// A step closes the window's open dropdown and its palette, which
    /// describe the place it leaves.
    @Test func goBack_closesTheWindowsDropdownAndPalette() throws {
        let fixture = try Fixture()
        fixture.window.titleBarMenu = TitleBarMenuRequest(menu: .worktree, anchor: .zero)
        fixture.session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: fixture.window.id)

        SupervisionWindowActions.goBack(in: fixture.window, session: fixture.session)

        #expect(fixture.window.titleBarMenu == nil)
        #expect(fixture.session.commandPaletteState == nil)
    }

    /// A palette open in another window is that window's, and stays.
    @Test func goForward_leavesAnotherWindowsPaletteOpen() throws {
        let fixture = try Fixture()
        fixture.session.navigateBack(in: fixture.window.id, intent: .person)
        let palette = CommandPaletteState(locale: Locale(identifier: "en"), windowID: fixture.session.primaryWindowID)
        fixture.session.commandPaletteState = palette

        SupervisionWindowActions.goForward(in: fixture.window, session: fixture.session)

        #expect(fixture.session.commandPaletteState === palette)
        #expect(fixture.session.selection(fixture.window.id)?.activeTabID == fixture.tabA.id)
    }

    /// The pair as the bar draws it is the width the width rules are
    /// checked with (`SupervisionWindowWidthsTests.historyWidth`): two
    /// squares as tall as the palette field, 2pt apart.
    @Test func thePair_isAsWideAsTheWidthRulesAssume() throws {
        try withTempDir { directory in
            let fixture = try Fixture()
            let settings = SettingsStore(directory: directory)
            let host = NSHostingView(rootView: TitleBarHistoryButtons()
                .environment(fixture.session)
                .environment(fixture.window)
                .environment(settings))
            let size = host.fittingSize
            let layout = WeirLayout.Supervision.self
            #expect(size.width == 2 * layout.titleBarHistoryButtonSize + layout.titleBarHistoryButtonSpacing)
            #expect(size.width == SupervisionWindowWidthsTests.historyWidth)
            #expect(size.height == WeirLayout.titleBarControlHeight)
        }
    }
}
