// WindowSelectionTests.swift
// Weir — each window's selection, found by its ID, the primary's among the session's selections.

import CoreGraphics
import Foundation
import Observation
import Testing
@testable import Weir

@MainActor
struct WindowSelectionTests {
    @Test func init_putsThePrimaryInSelections() {
        let session = WorkspaceSession(activeContainerID: .loose, sidebarWidth: 300)

        #expect(session.selections.count == 1)
        #expect(session.selections[session.primaryWindowID] === session.primarySelection)
        #expect(session.primarySelection.sidebarWidth == 300)
    }

    /// Why `WindowSelection` is a class: a view that reads the selected tab
    /// must not be invalidated by the frame changing during a live resize.
    @Test func frameChanges_doNotInvalidateReadersOfTheSelectedTab() {
        let session = WorkspaceSession()
        let notified = Recorded(false)
        withObservationTracking {
            _ = session.primarySelection.activeTabID
        } onChange: {
            notified.value = true
        }

        session.primarySelection.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        session.primarySelection.sidebarWidth = 260
        #expect(!notified.value)

        // Control: the tracking is live, so the check above cannot pass by
        // observing nothing.
        session.primarySelection.activeTabID = UUID()
        #expect(notified.value)
    }

    @Test func windowID_roundTripsAsAPlainUUID() throws {
        let id = WindowID()
        let data = try JSONEncoder().encode(id)
        #expect(String(bytes: data, encoding: .utf8) == "\"\(id.rawValue.uuidString)\"")
        #expect(try JSONDecoder().decode(WindowID.self, from: data) == id)
    }

    // MARK: - Finding a window's selection

    @Test func selectionOfAnUnknownID_isNil() {
        let session = WorkspaceSession()
        let other = WorkspaceSessionFixture.addWindow(to: session)

        #expect(session.selection(WindowID()) == nil)
        #expect(session.selection(other)?.windowID == other)
    }

    @Test func aWindowsViewReadsItsOwnSelection_evenAfterTheSessionDropsIt() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        session.openTab(container: .project(project.id))
        // Another project's, for the second window to show.
        let elsewhere = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("elsewhere"))
        let second = session.openTab(container: .project(elsewhere.id), in: session.primaryWindowID, intent: .person, selects: false)
        let registry = WindowRegistry(primary: session.primarySelection)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let window = try registry.addWindow(#require(session.selection(other)))
        session.setActiveTab(second.id, in: other)
        #expect(window.selection.activeTabID == second.id)

        session.removeWindowsPastPrimary()

        #expect(session.selection(other) == nil)
        // What the window showed last, not the primary's tab.
        #expect(window.selection.activeTabID == second.id)
        #expect(window.selection !== session.primarySelection)
        #expect(registry.primary.selection === session.primarySelection)
    }

    @Test func aWindowListedAgain_keepsTheSelectionItWasMadeWith() throws {
        let session = WorkspaceSession()
        let registry = WindowRegistry(primary: session.primarySelection)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let selection = try #require(session.selection(other))
        let window = registry.addWindow(selection)

        registry.adoptWindows(of: session)

        #expect(registry.addWindow(selection) === window)
        #expect(registry.window(other) === window)
        #expect(registry.windows.count == 2)
        // Every window the registry lists reads the session's own selection.
        for listed in registry.windows {
            #expect(session.selection(listed.id) === listed.selection)
        }
    }
}
