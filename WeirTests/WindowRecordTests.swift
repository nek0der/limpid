// WindowRecordTests.swift
// Weir — the shown windows saved with the session and made again at launch, and an earlier build's hidden windows read as views.

import CoreGraphics
import Foundation
import Observation
import Testing
@testable import Weir

@Suite(.tags(.persistence))
@MainActor
struct WindowRecordTests {
    /// A session whose primary shows `first` and a second window shows
    /// `second`, laid out apart from the primary.
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let first: Project
        let second: Project
        let secondTab: Tab
        let other: WindowID

        init() {
            let (session, first) = WorkspaceSessionFixture.withProject(name: "first")
            session.openTab(container: .project(first.id))
            second = session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("second"),
                suggestedName: "second"
            )
            session.setActiveContainer(.project(first.id))
            session.primarySelection.projectID = first.id
            other = session.addWindow(showing: second.id, layoutFrom: session.primaryWindowID).windowID
            secondTab = session.openTab(container: .project(second.id), in: other)
            let selection = session.selection(other)
            selection?.frame = CGRect(x: 40, y: 60, width: 900, height: 700)
            selection?.isFullScreen = true
            selection?.sidebarWidth = 333
            selection?.sidebarHidden = true
            selection?.isChangesPanelPresented = true
            selection?.changesPanelWidth = 444
            selection?.changesPanelFilter = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
            self.session = session
            self.first = first
        }

        /// The session as the next launch reads it back from disk, into
        /// `restored`, after `edit` changed the saved JSON as an earlier or
        /// a later build would have written it.
        @discardableResult
        func relaunched(
            into restored: WorkspaceSession = WorkspaceSession(),
            editing edit: (inout [String: Any]) throws -> Void = { _ in }
        ) throws -> WorkspaceSession {
            let encoded = try JSONEncoder().encode(session.makeSnapshot())
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            try edit(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))
            return restored
        }

        /// The second window's record, read back after `edit` changed its
        /// JSON.
        func otherRecord(editing edit: (inout [String: Any]) -> Void) throws -> WindowRecord {
            let record = try #require(session.makeSnapshot().windows.last)
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            edit(&object)
            return try JSONDecoder().decode(WindowRecord.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func everyWindow_comesBackLaidOutAsItWas() throws {
        let fixture = Fixture()
        let primaryFrame = CGRect(x: 10, y: 20, width: 1100, height: 700)
        fixture.session.primarySelection.frame = primaryFrame
        fixture.session.primarySelection.sidebarWidth = 312
        fixture.session.primarySelection.sidebarHidden = true

        let restored = try fixture.relaunched()

        #expect(restored.windowIDs.count == 2)
        let other = try #require(restored.windowIDs.last)
        let selection = try #require(restored.selection(other))
        #expect(selection.projectID == fixture.second.id)
        #expect(selection.activeTabID == fixture.secondTab.id)
        #expect(selection.frame == CGRect(x: 40, y: 60, width: 900, height: 700))
        #expect(selection.isFullScreen)
        #expect(selection.sidebarWidth == 333)
        #expect(selection.sidebarHidden)
        #expect(selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 444)
        // The filter is the running app's: a launch opens the panel on "All".
        #expect(selection.changesPanelFilter == nil)
        let primary = restored.primarySelection
        #expect(primary.projectID == fixture.first.id)
        #expect(primary.frame == primaryFrame)
        #expect(primary.sidebarWidth == 312)
        #expect(primary.sidebarHidden)
        #expect(!primary.isChangesPanelPresented)
    }

    @Test func aHiddenWindowBesideAShownOne_isSavedAsItsProjectsView() throws {
        let fixture = Fixture()
        fixture.session.setWindow(fixture.other, isHidden: true)
        fixture.session.frontWindowID = fixture.session.primaryWindowID

        let snapshot = fixture.session.makeSnapshot()
        #expect(snapshot.windows.map(\.isHidden) == [false])
        #expect(snapshot.windows.map(\.isFront) == [true])
        #expect(snapshot.projectViews.map(\.projectID) == [fixture.second.id])

        let restored = try fixture.relaunched()
        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.hiddenWindowIDs.isEmpty)
        #expect(restored.frontWindowID == restored.primaryWindowID)
        let view = try #require(restored.projectViews[fixture.second.id])
        #expect(view.activeTabID == fixture.secondTab.id)
        #expect(view.sidebarWidth == 333)
        #expect(view.isChangesPanelPresented)
    }

    @Test func aWindowWithNothingLeftToShow_isNotMadeAgain() {
        let fixture = Fixture()
        var snapshot = fixture.session.makeSnapshot()
        var records = snapshot.windows
        records[0].isFront = false
        // A window whose project is gone, and a second one for a project
        // a window already shows, which was in front.
        var gone = records[1]
        gone.projectID = UUID()
        var twice = records[1]
        twice.isFront = true
        records += [gone, twice]
        snapshot.windows = records

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)

        #expect(restored.windowIDs.count == 2)
        // The one in front is put first, as the primary, so the earlier
        // record of its project is the second one, not made.
        #expect(restored.frontWindowID == restored.primaryWindowID)
        #expect(restored.primarySelection.projectID == fixture.second.id)
        let shown = restored.windowIDs.compactMap { restored.selection($0)?.shownProjectID }
        #expect(Set(shown) == [fixture.first.id, fixture.second.id])
    }

    @Test func aWindowWhoseTabIsGone_goesBackToItsProject() throws {
        let fixture = Fixture()
        var snapshot = fixture.session.makeSnapshot()
        snapshot.windows[1].activeTabID = UUID()
        // Nor may it take a tab another project's window shows.
        var elsewhere = snapshot.windows[1]
        elsewhere.activeTabID = fixture.session.primarySelection.activeTabID

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)
        let other = try #require(restored.windowIDs.last)
        #expect(restored.selection(other)?.activeTabID == fixture.secondTab.id)

        snapshot.windows[1] = elsewhere
        restored.restore(from: snapshot)
        let again = try #require(restored.windowIDs.last)
        #expect(restored.selection(again)?.activeTabID == fixture.secondTab.id)
        #expect(restored.selection(again)?.activeContainerID.projectID == fixture.second.id)
    }

    /// A session saved without `windows` (v6), or with an empty list (only
    /// a damaged file has one: this build always writes the primary first),
    /// restored into a session that had windows of its own: the primary
    /// alone, laid out as a new install starts the supervision window,
    /// the sidebar at 304pt, with every tab. A missing record costs where
    /// the window stood, never the window or what it held.
    @Test(arguments: [false, true])
    func aSnapshotWithoutWindows_restoresThePrimaryAlone_withTheSupervisionLayoutAndEveryTab(isListEmpty: Bool) throws {
        let fixture = Fixture()
        #expect(WorkspaceSession().primarySelection.sidebarWidth == 304)
        #expect(WindowRecord().sidebarWidth == 304)
        let tabs = Set(fixture.session.tabs.map(\.id))

        try fixture.relaunched(into: fixture.session) { object in
            if isListEmpty {
                object["windows"] = [Any]()
            } else {
                object.removeValue(forKey: "windows")
            }
        }

        #expect(fixture.session.windowIDs == [fixture.session.primaryWindowID])
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(fixture.session.primarySelection.sidebarWidth == 304)
        #expect(Set(fixture.session.tabs.map(\.id)) == tabs)
    }

    /// A record without a sidebar width, as a hand edit or an earlier
    /// writer may leave, reads it as the default; the values a record does
    /// carry are kept (`everyWindow_comesBackLaidOutAsItWas`).
    @Test func aRecordWithoutItsLayout_readsTheSupervisionDefaults() throws {
        let fixture = Fixture()
        #expect(try fixture.otherRecord { _ in }.sidebarWidth == 333)

        let read = try fixture.otherRecord { $0.removeValue(forKey: "sidebarWidth") }

        #expect(read.sidebarWidth == 304)
    }

    @Test func aRecordALaterBuildWrote_readsWithWhatItKnows() throws {
        let fixture = Fixture()

        let read = try fixture.otherRecord {
            $0["changesPanelAgent"] = ["shape": "unknown"]
            $0["isFloating"] = true
        }

        #expect(read.projectID == fixture.second.id)
    }

    /// The agent an earlier build's switcher showed, saved before the panel
    /// became one timeline, does not come back as the filter: the panel
    /// opens on "All".
    @Test func anAgentAnEarlierBuildSaved_doesNotNarrowTheFilter() throws {
        let fixture = Fixture()
        let saved: [String: Any] = ["provider": "claude", "conversationID": "c1", "isFallback": false]

        let restored = try fixture.relaunched { snapshot in
            var windows = try #require(snapshot["windows"] as? [[String: Any]])
            for index in windows.indices {
                windows[index]["changesPanelAgent"] = saved
            }
            snapshot["windows"] = windows
        }

        #expect(restored.windowIDs.count == 2)
        for window in restored.windowIDs {
            #expect(restored.selection(window)?.changesPanelFilter == nil)
        }
    }

    /// The filter is never written: a window's record carries no key for
    /// it, under its old name or a new one.
    @Test func theFilter_isNotWritten() throws {
        let fixture = Fixture()
        let data = try JSONEncoder().encode(fixture.session.makeSnapshot())
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains("changesPanelAgent"))
        #expect(!text.contains("changesPanelFilter"))
    }

    // MARK: - The tab column, gone

    /// A window an earlier build saved with its tabs in the column, which is
    /// gone: its record still reads, and the window comes back with the rest
    /// of its layout, on the pane strip, the only way its tabs are drawn now.
    @Test func aRecordThatSetItsTabsInAColumn_readsAndTheWindowOpensOnTheStrip() throws {
        let fixture = Fixture()

        let restored = try fixture.relaunched { object in
            var windows = try #require(object["windows"] as? [[String: Any]])
            windows[1]["tabOrientation"] = "column"
            windows[1]["tabColumnWidth"] = 222
            object["windows"] = windows
        }

        #expect(restored.windowIDs.count == 2)
        let other = try #require(restored.windowIDs.last)
        let selection = try #require(restored.selection(other))
        #expect(selection.projectID == fixture.second.id)
        #expect(selection.activeTabID == fixture.secondTab.id)
        #expect(selection.sidebarWidth == 333)
        #expect(selection.frame == CGRect(x: 40, y: 60, width: 900, height: 700))
        // Saved again, the column's keys are gone rather than carried.
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.makeSnapshot())) as? [String: Any]
        let savedWindows = try #require(saved?["windows"] as? [[String: Any]])
        #expect(savedWindows.count == 2)
        #expect(savedWindows.allSatisfy { $0["tabOrientation"] == nil && $0["tabColumnWidth"] == nil })
    }

    // MARK: - Launch

    @Test func restore_opensTheShownWindows_theFrontOneLast() throws {
        let fixture = Fixture()
        let third = fixture.session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("third"),
            suggestedName: "third"
        )
        let thirdWindow = fixture.session.addWindow(showing: third.id, layoutFrom: fixture.session.primaryWindowID).windowID
        fixture.session.setWindow(thirdWindow, isHidden: true)
        // The primary was in front: shown last, though listed first.
        fixture.session.frontWindowID = fixture.session.primaryWindowID
        let restored = try fixture.relaunched()
        let registry = WindowRegistry(primary: restored.primarySelection)
        let presenter = RecordingWindowPresenter()
        registry.presenter = presenter

        registry.adoptWindows(of: restored)
        registry.showRestoredWindows(of: restored)

        let other = try #require(restored.windowIDs.first { restored.selection($0)?.projectID == fixture.second.id })
        #expect(registry.windows.count == 2)
        #expect(presenter.shown == [other, restored.primaryWindowID])
        #expect(presenter.raisedAfterFullScreen == [restored.primaryWindowID])
        // The hidden window was not saved as a window: its project's view was.
        #expect(restored.projectViews[third.id] != nil)
    }

    @Test func restore_withEveryWindowHidden_showsTheOneLastUsed_elseThePrimary() throws {
        let fixture = Fixture()
        fixture.session.setWindow(fixture.session.primaryWindowID, isHidden: true)
        fixture.session.setWindow(fixture.other, isHidden: true)
        fixture.session.frontWindowID = fixture.other
        // Only the one the Dock would bring back is saved as a window.
        #expect(fixture.session.makeSnapshot().windows.map(\.projectID) == [fixture.second.id])
        let restored = try fixture.relaunched()
        let registry = WindowRegistry(primary: restored.primarySelection)
        let presenter = RecordingWindowPresenter()
        registry.presenter = presenter
        registry.onVisibilityChange = { restored.setWindow($0, isHidden: $1) }

        registry.adoptWindows(of: restored)
        registry.showRestoredWindows(of: restored)

        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.primarySelection.projectID == fixture.second.id)
        #expect(presenter.shown == [restored.primaryWindowID])
        #expect(presenter.raisedAfterFullScreen.isEmpty)
        #expect(restored.hiddenWindowIDs.isEmpty)
        #expect(restored.projectViews[fixture.first.id] != nil)

        fixture.session.frontWindowID = nil
        let unfronted = try fixture.relaunched()
        let second = WindowRegistry(primary: unfronted.primarySelection)
        let secondPresenter = RecordingWindowPresenter()
        second.presenter = secondPresenter
        second.adoptWindows(of: unfronted)
        second.showRestoredWindows(of: unfronted)
        #expect(unfronted.primarySelection.projectID == fixture.first.id)
        #expect(secondPresenter.shown == [unfronted.primaryWindowID])
    }

    @Test func theRestoredWindows_areListedBeforeAnythingAsksForAProjectsWindow() throws {
        let fixture = Fixture()
        let restored = try fixture.relaunched()
        let registry = WindowRegistry(primary: restored.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        registry.connectProjectSwitching(of: restored)

        registry.adoptWindows(of: restored)

        // The restored window that shows the project comes forward; the
        // primary does not switch to it as well.
        let window = registry.show(project: fixture.second.id, in: restored, from: nil, intent: .person)
        #expect(restored.windowIDs.count == 2)
        #expect(window?.id == restored.windowIDs.last)
        #expect(restored.primarySelection.shownProjectID == fixture.first.id)
    }

    @Test func aWindowOffScreen_isSavedShown_andComesBackShown() throws {
        let fixture = Fixture()
        let registry = WindowRegistry(primary: fixture.session.primarySelection)
        let presenter = RecordingWindowPresenter()
        registry.presenter = presenter
        registry.adoptWindows(of: fixture.session)
        registry.showRestoredWindows(of: fixture.session)
        // On another Space, minimized, or covered: off screen, not hidden.
        registry.windowScreenPresenceChanged(fixture.other, isOnScreen: false)
        presenter.onScreen.remove(fixture.other)

        let snapshot = fixture.session.makeSnapshot()

        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.allSatisfy { !$0.isHidden })
        let restored = try fixture.relaunched()
        let restoredRegistry = WindowRegistry(primary: restored.primarySelection)
        let restoredPresenter = RecordingWindowPresenter()
        restoredRegistry.presenter = restoredPresenter
        restoredRegistry.adoptWindows(of: restored)
        restoredRegistry.showRestoredWindows(of: restored)
        #expect(restored.hiddenWindowIDs.isEmpty)
        #expect(Set(restoredPresenter.shown) == Set(restored.windowIDs))
        #expect(restoredPresenter.shown.count == 2)
    }

    @Test func terminate_savesTheLastWindowHidden() throws {
        let fixture = Fixture()
        fixture.session.setWindow(fixture.session.primaryWindowID, isHidden: true)
        fixture.session.setWindow(fixture.other, isHidden: true)
        fixture.session.frontWindowID = fixture.other

        let records = fixture.session.makeSnapshot().windows

        let hidden = try #require(records.first)
        #expect(records.count == 1)
        #expect(hidden.isHidden)
        #expect(hidden.isFront)
        #expect(hidden.projectID == fixture.second.id)
        #expect(hidden.activeTabID == fixture.secondTab.id)
    }

    // MARK: - An earlier build's hidden windows

    /// The session saved as a build before windows closed for real saved
    /// it: every window, `hidden` saying which were hidden, and `front`
    /// the one in front.
    private static func earlierSnapshot(_ fixture: Fixture, hidden: [Bool], front: Int?) -> SessionSnapshot {
        var snapshot = fixture.session.makeSnapshot()
        for index in snapshot.windows.indices {
            snapshot.windows[index].isHidden = hidden[index]
            snapshot.windows[index].isFront = index == front
        }
        return snapshot
    }

    @Test func oldHiddenProjectWindows_becomeProjectMemory_notWindows() throws {
        let fixture = Fixture()
        let snapshot = Self.earlierSnapshot(fixture, hidden: [false, true], front: 0)

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)

        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.hiddenWindowIDs.isEmpty)
        #expect(restored.primarySelection.projectID == fixture.first.id)
        let view = try #require(restored.projectViews[fixture.second.id])
        #expect(view.activeTabID == fixture.secondTab.id)
        #expect(view.activeContainerID == .project(fixture.second.id))
        #expect(view.sidebarWidth == 333)
        #expect(view.sidebarHidden)
        #expect(view.isChangesPanelPresented)
        #expect(view.changesPanelWidth == 444)
        // Saved again, it is a view, not a window.
        let saved = restored.makeSnapshot()
        #expect(saved.windows.count == 1)
        #expect(saved.projectViews.map(\.projectID) == [fixture.second.id])
    }

    @Test func anOldSnapshotWhosePrimaryWasHidden_makesAShownWindowThePrimary() throws {
        let fixture = Fixture()
        let snapshot = Self.earlierSnapshot(fixture, hidden: [true, false], front: nil)
        let firstTab = fixture.session.primarySelection.activeTabID

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)

        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.hiddenWindowIDs.isEmpty)
        // The shown window's record, not the hidden first one's.
        #expect(restored.primarySelection.projectID == fixture.second.id)
        #expect(restored.primarySelection.activeTabID == fixture.secondTab.id)
        #expect(restored.primarySelection.sidebarWidth == 333)
        #expect(restored.primarySelection.frame == CGRect(x: 40, y: 60, width: 900, height: 700))
        let view = try #require(restored.projectViews[fixture.first.id])
        #expect(view.activeTabID == firstTab)
        #expect(view.activeContainerID == .project(fixture.first.id))
    }

    @Test func withEveryWindowHidden_onlyTheOneLastUsedIsMade() {
        let fixture = Fixture()

        let restored = WorkspaceSession()
        restored.restore(from: Self.earlierSnapshot(fixture, hidden: [true, true], front: 1))

        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.primarySelection.projectID == fixture.second.id)
        #expect(restored.hiddenWindowIDs == [restored.primaryWindowID])
        #expect(restored.projectViews[fixture.first.id] != nil)

        // With none in front, the first.
        restored.restore(from: Self.earlierSnapshot(fixture, hidden: [true, true], front: nil))
        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.primarySelection.projectID == fixture.first.id)
        #expect(restored.projectViews[fixture.second.id] != nil)
    }

    @Test func anOldScratchPrimary_besideHiddenProjectWindows_keepsTheirViews() {
        let fixture = Fixture()
        let firstTab = fixture.session.primarySelection.activeTabID
        var snapshot = Self.earlierSnapshot(fixture, hidden: [true, true], front: nil)
        // The primary was on a scratch tab naming no project, in front, and
        // each project had a window of its own, hidden.
        let scratch = fixture.session.openTab(container: .loose, in: fixture.session.primaryWindowID)
        var primary = snapshot.windows[0]
        primary.projectID = nil
        primary.activeContainerID = .loose
        primary.activeTabID = scratch.id
        primary.isHidden = false
        primary.isFront = true
        snapshot.tabs = fixture.session.tabs
        snapshot.windows = [primary] + snapshot.windows

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)

        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.primarySelection.activeTabID == scratch.id)
        // Every project has a view, so the primary takes none of them.
        #expect(restored.primarySelection.projectID == nil)
        #expect(restored.projectViews[fixture.first.id]?.activeTabID == firstTab)
        #expect(restored.projectViews[fixture.second.id]?.activeTabID == fixture.secondTab.id)
        #expect(restored.projectViews[fixture.second.id]?.sidebarWidth == 333)
        #expect(restored.projectViews.count == 2)
    }

    // MARK: - What the record may not override

    @Test func thePrimarysProject_isTheOneItsSelectionIsIn() {
        let fixture = Fixture()
        var snapshot = fixture.session.makeSnapshot()
        // A record that went out of step with the root's selection.
        snapshot.windows[0].projectID = fixture.second.id

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)

        #expect(restored.primarySelection.projectID == fixture.first.id)
        let shown = restored.windowIDs.compactMap { restored.selection($0)?.shownProjectID }
        #expect(shown.count == Set(shown).count)
        #expect(Set(shown) == [fixture.first.id, fixture.second.id])
    }

    @Test func aPrimaryOnAProjectWithNoTab_staysOnIt_besideAnotherProjectsWindow() throws {
        // The primary showed a project with no tab yet; another window
        // showed a project with one. The primary must not take that tab,
        // which would drop the other window as a second one of its project.
        let (session, empty) = WorkspaceSessionFixture.withProject(name: "empty")
        let second = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("second"),
            suggestedName: "second"
        )
        session.setActiveContainer(.project(empty.id))
        session.primarySelection.projectID = empty.id
        let other = session.addWindow(showing: second.id, layoutFrom: session.primaryWindowID).windowID
        let secondTab = session.openTab(container: .project(second.id), in: other)
        #expect(session.primarySelection.activeTabID == nil)

        let restored = WorkspaceSession()
        let data = try JSONEncoder().encode(session.makeSnapshot())
        let issue = try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))

        #expect(issue == nil)
        #expect(restored.windowIDs.count == 2)
        #expect(restored.primarySelection.activeContainerID == .project(empty.id))
        #expect(restored.primarySelection.activeTabID == nil)
        let window = try #require(restored.windowIDs.last)
        #expect(restored.selection(window)?.projectID == second.id)
        #expect(restored.selection(window)?.activeTabID == secondTab.id)
    }

    @Test func aRestoredScratchTab_isDrawnInOneWindow() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose)
        fixture.session.setActiveTab(scratch.id, in: fixture.other)
        fixture.session.setActiveTab(scratch.id)

        let restored = try fixture.relaunched()

        #expect(restored.windows(selecting: scratch.id).count == 2)
        #expect(restored.windows(showing: scratch.id).count == 1)
    }

    @Test func aLaterWindowsChange_isSeenByTheAutosave() {
        let fixture = Fixture()
        let notified = Recorded(false)
        withObservationTracking {
            _ = fixture.session.windowRecords()
        } onChange: {
            notified.value = true
        }

        fixture.session.selection(fixture.other)?.changesPanelWidth = 500

        #expect(notified.value)
    }

    // MARK: - Records that do not read

    @Test func aLaterWindowThatDoesNotRead_leavesThePrimaryAndTheOthers() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        let other = Project(name: "other", rootURL: URL(fileURLWithPath: "/tmp/other"))
        let snapshot = SessionSnapshot(projects: [project, other], tabs: [], windows: [
            WindowRecord(projectID: project.id, activeContainerID: .project(project.id), sidebarWidth: 290),
            WindowRecord(projectID: other.id, activeContainerID: .project(other.id))
        ])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var windows = try #require(object["windows"] as? [[String: Any]])
        windows.insert(["sidebarWidth": "wide", "activeContainerID": ["loose": [String: Any]()]], at: 1)
        object["windows"] = windows

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.windows.count == 2)
        #expect(decoded.windows.first?.sidebarWidth == 290)
        #expect(decoded.windows.last?.projectID == other.id)
    }

    @Test func aPrimaryThatDoesNotRead_startsFromItsDefaults_andKeepsTheOthers() throws {
        let other = Project(name: "other", rootURL: URL(fileURLWithPath: "/tmp/other"))
        let snapshot = SessionSnapshot(projects: [other], tabs: [], windows: [
            WindowRecord(),
            WindowRecord(projectID: other.id, activeContainerID: .project(other.id))
        ])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var windows = try #require(object["windows"] as? [[String: Any]])
        windows[0]["projectID"] = 42
        object["windows"] = windows

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.windows.count == 2)
        #expect(decoded.windows.first == .unread)
        #expect(decoded.windows.last?.projectID == other.id)
    }

    /// A primary's record that does not read is put back as a session with
    /// no record is, on its first tab, not as one saved on the scratch row,
    /// which its defaults would read as.
    @Test func aPrimaryThatDoesNotRead_restoresAsOneWithNoRecord() throws {
        let project = Project(name: "repo", rootURL: WorkspaceSessionFixture.projectRootURL("repo"))
        let (tab, _) = Tab.newWithSinglePane(title: "repo", workingDirectory: nil, container: .project(project.id))
        let snapshot = SessionSnapshot(projects: [project], tabs: [tab], windows: [
            WindowRecord(projectID: project.id, activeTabID: tab.id, activeContainerID: .project(project.id))
        ])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var windows = try #require(object["windows"] as? [[String: Any]])
        windows[0]["projectID"] = 42
        object["windows"] = windows
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        var withoutRecord = snapshot
        withoutRecord.windows = []

        let unread = WorkspaceSession()
        let unreadIssue = unread.restore(from: decoded)
        let missing = WorkspaceSession()
        let missingIssue = missing.restore(from: withoutRecord)

        #expect(unread.primarySelection.activeTabID == tab.id)
        #expect(unread.primarySelection.activeContainerID == .project(project.id))
        #expect(unreadIssue == missingIssue)
        #expect(missing.primarySelection.activeTabID == tab.id)
        // Saved again, the window is written as it is now.
        #expect(unread.makeSnapshot().windows.first?.isUnread == false)
    }

    /// A primary whose record does not read stands in on no tab of a
    /// project a later window that read holds: that window would be
    /// dropped as a second window of its project, and lose its own
    /// record. It takes another project's tab, or the scratch row.
    @Test(arguments: [true, false])
    func aPrimaryThatDoesNotRead_leavesALaterWindowsProjectToIt(hasAnotherTab: Bool) throws {
        let held = Project(name: "held", rootURL: WorkspaceSessionFixture.projectRootURL("held"))
        let free = Project(name: "free", rootURL: WorkspaceSessionFixture.projectRootURL("free"))
        let (heldTab, _) = Tab.newWithSinglePane(title: "held", workingDirectory: nil, container: .project(held.id))
        let (freeTab, _) = Tab.newWithSinglePane(title: "free", workingDirectory: nil, container: .project(free.id))
        let snapshot = SessionSnapshot(
            projects: [held, free],
            tabs: hasAnotherTab ? [heldTab, freeTab] : [heldTab],
            windows: [
                WindowRecord(),
                WindowRecord(projectID: held.id, activeTabID: heldTab.id, activeContainerID: .project(held.id), sidebarWidth: 333)
            ]
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var windows = try #require(object["windows"] as? [[String: Any]])
        windows[0]["projectID"] = 42
        object["windows"] = windows
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        let session = WorkspaceSession()
        session.restore(from: decoded)

        let later = try #require(session.windowIDs.dropFirst().first.flatMap { session.selection($0) })
        #expect(later.shownProjectID == held.id)
        #expect(later.activeTabID == heldTab.id)
        #expect(later.sidebarWidth == 333, "its own record, not the defaults")
        if hasAnotherTab {
            #expect(session.primarySelection.activeTabID == freeTab.id)
        } else {
            #expect(session.primarySelection.activeTabID == nil)
            #expect(session.primarySelection.activeContainerID == .loose)
        }
    }

    // MARK: - The sidebar's arrangement

    /// Each window's order, folded headers, and open sections come back as
    /// they were saved.
    @Test func eachWindowsSidebarArrangement_comesBack() throws {
        let fixture = Fixture()
        let primary = SidebarArrangement(
            projectOrder: [fixture.second.id, fixture.first.id],
            collapsedProjects: [fixture.second.id],
            openSections: [.init(project: fixture.first.id, section: .other)]
        )
        let other = SidebarArrangement(projectOrder: [fixture.first.id, fixture.second.id], collapsedProjects: [fixture.first.id])
        fixture.session.primarySelection.sidebarArrangement = primary
        fixture.session.selection(fixture.other)?.sidebarArrangement = other

        let restored = try fixture.relaunched()

        #expect(restored.primarySelection.sidebarArrangement == primary)
        let second = try #require(restored.windowIDs.dropFirst().first.flatMap { restored.selection($0) })
        #expect(second.sidebarArrangement == other)
    }

    /// A record from before arrangements has no `sidebar`: the window lists
    /// the projects in their order, every header met by the default rule.
    @Test func aRecordWithoutASidebar_readsTheDefaultArrangement() throws {
        let fixture = Fixture()
        fixture.session.primarySelection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.second.id])

        let restored = try fixture.relaunched { snapshot in
            var windows = try #require(snapshot["windows"] as? [[String: Any]])
            windows[0].removeValue(forKey: "sidebar")
            snapshot["windows"] = windows
        }

        #expect(restored.primarySelection.sidebarArrangement == SidebarArrangement())
    }

    /// A default arrangement writes no key, so a file no one arranged is the
    /// one an earlier build wrote.
    @Test func aDefaultArrangement_isNotWritten() throws {
        let fixture = Fixture()
        let record = WindowRecord(fixture.session.primarySelection, isHidden: false, isFront: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object["sidebar"] == nil)
    }

    /// A project that is gone since the save, and a section a later build
    /// named, are passed by; what reads is kept.
    @Test func aSidebarNamingAGoneProjectOrAnUnknownSection_keepsWhatReads() throws {
        let fixture = Fixture()
        let gone = UUID()
        let restored = try fixture.relaunched { snapshot in
            var windows = try #require(snapshot["windows"] as? [[String: Any]])
            windows[0]["sidebar"] = [
                "projectOrder": [gone.uuidString, fixture.second.id.uuidString, fixture.first.id.uuidString],
                "collapsedProjects": [gone.uuidString, fixture.first.id.uuidString],
                "openSections": [
                    ["project": fixture.second.id.uuidString, "section": "cleanable"],
                    ["project": fixture.first.id.uuidString, "section": "archived"],
                    ["project": gone.uuidString, "section": "other"]
                ]
            ]
            snapshot["windows"] = windows
        }

        #expect(restored.primarySelection.sidebarArrangement == SidebarArrangement(
            projectOrder: [fixture.second.id, fixture.first.id],
            collapsedProjects: [fixture.first.id],
            openSections: [.init(project: fixture.second.id, section: .cleanable)]
        ))
    }

    /// A sidebar that does not read at all is the default one; the window's
    /// record still reads.
    @Test func aSidebarThatDoesNotRead_leavesTheRestOfTheRecord() throws {
        let fixture = Fixture()
        let read = try fixture.otherRecord { $0["sidebar"] = ["projectOrder": "not a list"] }
        #expect(read.sidebar == nil)
        #expect(read.projectID == fixture.second.id)
    }

    /// Folding a header alone schedules a save.
    @Test func foldingAHeader_isSeenByTheAutosave() {
        let fixture = Fixture()
        let notified = Recorded(false)
        withObservationTracking {
            fixture.session.readSavedState()
        } onChange: {
            notified.value = true
        }

        fixture.session.primarySelection.sidebarArrangement.setCollapsed(true, fixture.second.id)

        #expect(notified.value)
    }
}

// MARK: - The turn list's grouping

/// Kept apart from the suite's body, which is at its length limit.
extension WindowRecordTests {
    /// A window that grouped its turn list by conversation comes back
    /// grouped, and one left on the timeline comes back on it.
    @Test func windowRecord_grouping_roundTrips() throws {
        let fixture = Fixture()
        fixture.session.selection(fixture.other)?.changesPanelGrouping = .byConversation

        let restored = try fixture.relaunched()

        let other = try #require(restored.windowIDs.last)
        #expect(restored.selection(other)?.changesPanelGrouping == .byConversation)
        #expect(restored.primarySelection.changesPanelGrouping == .timeline)
    }

    /// A record written before the grouping was saved opens on the timeline.
    @Test func windowRecord_missingGrouping_decodesAsTimeline() throws {
        let fixture = Fixture()
        fixture.session.selection(fixture.other)?.changesPanelGrouping = .byConversation

        let read = try fixture.otherRecord { $0.removeValue(forKey: "changesPanelGrouping") }

        #expect(read.changesPanelGrouping == .timeline)
        #expect(read.projectID == fixture.second.id)
    }

    /// A grouping a later build knows and this one does not opens on the
    /// timeline, and costs nothing else in the record.
    @Test func windowRecord_unknownGrouping_decodesAsTimeline() throws {
        let fixture = Fixture()

        let read = try fixture.otherRecord { $0["changesPanelGrouping"] = "byWorktree" }
        let mistyped = try fixture.otherRecord { $0["changesPanelGrouping"] = 3 }

        #expect(read.changesPanelGrouping == .timeline)
        #expect(read.projectID == fixture.second.id)
        #expect(mistyped.changesPanelGrouping == .timeline)
        #expect(mistyped.changesPanelWidth == 444)
    }
}
