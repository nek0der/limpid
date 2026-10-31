// ProjectWindowsFixture.swift
// Weir — three projects whose windows switch as the app's do, and the review tab the window suites open.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Three projects, `a`, `b`, and `c`, opened in that order, so `c` is
/// the most recent; `a` has two sessions. The primary shows `a` on
/// `aTab`, and switches projects through its registry as the app's
/// windows do.
@MainActor
struct ProjectWindowsFixture {
    let session: WorkspaceSession
    let registry: WindowRegistry
    let presenter = RecordingWindowPresenter()
    let a: Project
    let b: Project
    let c: Project
    let aTab: Tab
    let aOther: Tab
    let bTab: Tab
    let cTab: Tab

    init() {
        let session = WorkspaceSession()
        a = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("a"), suggestedName: "a")
        b = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("b"), suggestedName: "b")
        c = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("c"), suggestedName: "c")
        // Opened without selecting, and the primary put on `a` as a launch
        // puts it: setting up switches no window and uses no project.
        let primary = session.primaryWindowID
        aTab = session.openTab(container: .project(a.id), in: primary, intent: .person, selects: false)
        aOther = session.openTab(container: .project(a.id), in: primary, intent: .person, selects: false)
        bTab = session.openTab(container: .project(b.id), in: primary, intent: .person, selects: false)
        cTab = session.openTab(container: .project(c.id), in: primary, intent: .person, selects: false)
        session.primarySelection.projectID = a.id
        session.setActiveTab(aTab.id)
        registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = presenter
        registry.onVisibilityChange = { session.setWindow($0, isHidden: $1) }
        registry.show(registry.primary.id)
        registry.connectProjectSwitching(of: session)
        presenter.shown = []
        self.session = session
    }

    var primary: ProjectWindowState {
        registry.primary
    }

    /// The person chooses `tab` in `window`: a palette row, going back,
    /// a jump.
    func choose(_ tab: Tab, in window: ProjectWindowState) {
        session.setActiveTab(tab.id, in: window.id, intent: .person)
    }

    /// A second window on `project`, opened from the primary as ⌘-click
    /// opens one (`WindowRegistry.openInNewWindow`); the window that
    /// shows it already when one does.
    @discardableResult
    func window(showing project: Project) throws -> ProjectWindowState {
        let window = try #require(registry.openInNewWindow(project: project.id, in: session, from: registry.primary))
        presenter.shown = []
        return window
    }

    /// Lets go of what a window holds for the project it leaves, as the
    /// app does (`AppState.presentSupervisionWindows`).
    func tidiesAsTheAppDoes() {
        registry.onWillSwitchProject = { [session] window, from, _ in
            WindowProjectSwitch.tidy(window, leaving: from, session: session)
        }
    }

    /// A tab of the scratch tabs, opened behind.
    func scratchTab() -> Tab {
        session.openTab(container: .loose, in: primary.id, intent: .person, selects: false)
    }

    /// No project is shown by two windows, hidden ones counted,
    /// and a project with a view is shown by none.
    func expectInvariants(sourceLocation: SourceLocation = #_sourceLocation) {
        let shown = session.windowIDs.compactMap { session.selection($0)?.shownProjectID }
        #expect(shown.count == Set(shown).count, sourceLocation: sourceLocation)
        #expect(Set(session.projectViews.keys).isDisjoint(with: shown), sourceLocation: sourceLocation)
        #expect(registry.windows.count == session.windowIDs.count, sourceLocation: sourceLocation)
    }
}

/// The review tab the window suites hand a window, of one turn, what
/// discarding a hunk of it records, and a scratch pane's review, which a
/// window on no project carries.
extension ProjectWindowsFixture {
    static let discarded = ReviewHunkDiscardRecord.discarded(opID: "op", root: "/repo", note: nil)

    /// Gives `window` a review tab with a comment being written in it, of
    /// `agentPaneID`'s agent when it names one, opened from a scratch pane
    /// when `isOfNoProject`.
    @discardableResult
    static func windowWritingAComment(
        _ window: ProjectWindowState,
        agentPaneID: UUID? = nil,
        isOfNoProject: Bool = false
    ) throws -> ReviewTabState {
        let tab = try review(agentPaneID: agentPaneID, isOfNoProject: isOfNoProject)
        window.review = tab
        window.writeComment()
        return tab
    }

    /// A review tab and a hunk of the range it reads.
    static func reviewAndHunk() throws -> (tab: ReviewTabState, hunk: ReviewHunkKey) {
        let tab = try review()
        guard case let .turns(range) = tab.scope else { throw CancellationError() }
        let hunk = ReviewHunkKey(
            scopeID: range.scopeID,
            root: range.root,
            fromTree: range.beginTree,
            toTree: range.endTree,
            path: "a.swift",
            header: "@@ -1,2 +1,3 @@"
        )
        return (tab, hunk)
    }

    /// A review tab reading turn `T7` of `/repo`, of `agentPaneID`'s agent
    /// when it names one.
    static func review(agentPaneID: UUID? = nil, isOfNoProject: Bool = false) throws -> ReviewTabState {
        let range = try TurnSummaryFixture.range(number: 7)
        return ReviewTabState(
            root: "/repo",
            selection: .turn(range, prompt: TurnPrompt(head: nil)),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: agentPaneID,
            destinationPaneID: nil,
            opening: UUID(),
            isOfNoProject: isOfNoProject
        )
    }

    /// A hunk of a scratch pane's review, as a discard is recorded under.
    static let scratchHunk = ReviewHunkKey(
        scopeID: "scratch",
        root: "/scratch",
        fromTree: "f",
        toTree: "t",
        path: "s.swift",
        header: "@@ -1 +1 @@"
    )

    /// The primary, on `a`, reviewing a scratch pane, with a discard there.
    func reviewAScratchPane(hasComment: Bool) throws {
        let scratch = scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        primary.review = try Self.review(agentPaneID: pane, isOfNoProject: true)
        if hasComment {
            primary.writeComment()
        }
        primary.hunkDiscards[Self.scratchHunk] = Self.discarded
    }

    /// A window on no project, closed with a review of `agentPaneID`'s
    /// agent, else of a scratch pane's, a comment written in it when
    /// `hasComment`.
    func closeAWindowOfNoProject(agentPaneID: UUID? = nil, hasComment: Bool) throws -> ReviewTabState {
        let closing = try window(showing: b)
        session.showProject(nil, in: closing.id, intent: .person, reason: .person)
        #expect(closing.selection.shownProjectID == nil)
        let scratch = scratchTab()
        let scratchPane = try #require(scratch.splitTree.allLeafIDs().first)
        let pane = agentPaneID ?? scratchPane
        let tab = try Self.review(agentPaneID: pane, isOfNoProject: agentPaneID == nil)
        closing.review = tab
        if hasComment {
            closing.writeComment()
        }
        registry.close(closing.id, in: session)
        #expect(registry.window(closing.id) == nil)
        return tab
    }

    /// A window on `project` closes with a scratch pane's review holding a
    /// comment, on the scratch row when `onScratchRow`, else on the
    /// project's row.
    func closeWritingAScratchComment(
        showing project: Project,
        onScratchRow: Bool = false
    ) throws -> ReviewTabState {
        let closing = try window(showing: project)
        let scratch = session.openTab(container: .loose, in: closing.id, intent: .person, selects: false)
        if onScratchRow {
            session.setActiveContainer(.loose, in: closing.id, intent: .person)
        }
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try Self.windowWritingAComment(closing, agentPaneID: pane, isOfNoProject: true)
        #expect(closing.selection.shownProjectID == project.id)
        registry.close(closing.id, in: session)
        // Never kept for the project the window showed.
        #expect(registry.parkedReviews[project.id] == nil)
        return tab
    }

    /// `window` moves to the scratch row, its view following the move as
    /// it does for any row (`SessionAreaView`).
    func arriveAtTheScratchRow(_ window: ProjectWindowState) {
        session.setActiveContainer(.loose, in: window.id, intent: .person)
        ReviewTabActions.rowChanged(
            window: window,
            session: session,
            windows: registry,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: registry)
        )
    }
}
