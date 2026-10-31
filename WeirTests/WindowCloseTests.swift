// WindowCloseTests.swift
// Weir — closing a window ends it while another is shown, and hides the last one.

import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Weir

/// A window closed beside another ends: its project keeps what it showed,
/// its agents run on, the primary's role moves to a window left, and
/// nothing it held is counted or told in it again. The last window shown
/// is hidden for the Dock, and at most one is ever hidden.
@MainActor
struct WindowCloseTests {
    /// Two windows: the primary on `first`, at `firstTab`, and `other` on
    /// `second`, at `secondTab`, the one the person was in last. Both are
    /// shown, and the registry tells the session what it hides.
    /// Shared with the extension in WindowCloseReviewTests.swift and with
    /// `ParkedReviewArrivalTests`.
    @MainActor
    struct Fixture {
        let session: WorkspaceSession
        let registry: WindowRegistry
        let presenter: RecordingWindowPresenter
        let first: Project
        let firstTab: Tab
        let second: Project
        let secondTab: Tab
        let other: ProjectWindowState

        init() throws {
            let (session, first) = WorkspaceSessionFixture.withProject(name: "first")
            firstTab = session.openTab(container: .project(first.id))
            second = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("second"), suggestedName: "second")
            session.setActiveTab(firstTab.id)
            session.primarySelection.projectID = first.id
            registry = WindowRegistry(primary: session.primarySelection)
            presenter = RecordingWindowPresenter()
            registry.presenter = presenter
            registry.onVisibilityChange = { session.setWindow($0, isHidden: $1) }
            registry.show(registry.primary.id)
            other = try #require(registry.openInNewWindow(project: second.id, in: session, from: registry.primary))
            secondTab = session.openTab(container: .project(second.id), in: other.id)
            registry.windowBecameKey(other.id)
            self.session = session
            self.first = first
        }

        var primary: ProjectWindowState {
            registry.primary
        }

        var secondPane: UUID {
            secondTab.splitTree.allLeafIDs()[0]
        }

        /// A window on `project` listed and shown beside `hidden`, laid out
        /// like it (`WorkspaceSession.addWindow(showing:layoutFrom:)`): a state
        /// no entry point leaves, for the close's own guard.
        func windowBeside(_ hidden: ProjectWindowState, showing project: Project) -> ProjectWindowState {
            let window = registry.addWindow(session.addWindow(showing: project.id, layoutFrom: hidden.id))
            registry.show(window.id)
            return window
        }

        /// Closes `window` as its close button would.
        func close(_ window: ProjectWindowState) {
            registry.close(window.id, in: session)
        }

        /// The person chooses `second` in `window` (project ▾, a card, a
        /// notification): it switches in place unless another window shows
        /// the project, which comes forward instead. The registry switches
        /// the session's windows from here on, as the app's always does.
        func chooseSecond(in window: ProjectWindowState) throws -> ProjectWindowState {
            registry.connectProjectSwitching(of: session)
            return try #require(registry.show(project: second.id, in: session, from: window, intent: .person))
        }

        /// Tidies a window as it closes, telling its toasts in `toasts`, as
        /// the app does (`WindowClosing.tidy`).
        func tidiesOnClose(into toasts: ToastCenter) {
            registry.onClose = { [session, registry] window in
                WindowClosing.tidy(window, session: session, registry: registry, toasts: toasts)
            }
        }

        /// A window beside the others with no project, on the scratch tabs.
        func addEmptyWindow() throws -> ProjectWindowState {
            let id = WorkspaceSessionFixture.addWindow(to: session)
            let window = try registry.addWindow(#require(session.selection(id)))
            registry.show(id)
            return window
        }

    }

    private static let english = Locale(identifier: "en")

    // MARK: - Closing, hiding, and the primary

    @Test func closingOneOfTwoWindows_closesIt_andKeepsItsProjectsViewAndAgents() throws {
        let fixture = try Fixture()
        let pane = fixture.secondPane
        fixture.session.update(fixture.secondTab.id) {
            $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())]
        }

        fixture.close(fixture.other)

        #expect(fixture.registry.window(fixture.other.id) == nil)
        #expect(fixture.session.selection(fixture.other.id) == nil)
        #expect(fixture.presenter.closed == [fixture.other.id])
        #expect(!fixture.primary.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        // The project keeps what the window showed, and its session runs on.
        let view = try #require(fixture.session.projectViews[fixture.second.id])
        #expect(view.activeTabID == fixture.secondTab.id)
        #expect(fixture.session.tab(fixture.secondTab.id) != nil)
        #expect(fixture.session.hasLiveAgentAnywhere())
    }

    @Test func closingTheLastWindow_hidesIt_andTheDockBringsItBack() throws {
        let fixture = try Fixture()
        fixture.close(fixture.other)
        fixture.presenter.shown = []

        fixture.close(fixture.primary)

        #expect(fixture.primary.isHidden)
        #expect(fixture.registry.windows.map(\.id) == [fixture.primary.id])
        #expect(fixture.presenter.closed == [fixture.other.id])
        #expect(fixture.session.hiddenWindowIDs == [fixture.primary.id])
        // Still the project's window: it keeps its selection.
        #expect(fixture.session.projectViews[fixture.first.id] == nil)

        fixture.registry.showLastWindow()

        #expect(fixture.presenter.shown == [fixture.primary.id])
        #expect(!fixture.primary.isHidden)
    }

    @Test func aMinimizedWindowCounts_soClosingTheOtherOneClosesIt() throws {
        let fixture = try Fixture()
        // Minimized: off screen, but not hidden.
        fixture.registry.windowScreenPresenceChanged(fixture.other.id, isOnScreen: false)
        fixture.presenter.onScreen.remove(fixture.other.id)
        let closing = fixture.primary

        fixture.close(closing)

        #expect(fixture.presenter.closed == [closing.id])
        #expect(fixture.registry.window(closing.id) == nil)
        #expect(fixture.primary === fixture.other)
        #expect(!fixture.other.isHidden)
    }

    @Test func closingThePrimary_handsThePrimaryToAShownWindow() throws {
        let fixture = try Fixture()
        let closing = fixture.primary

        fixture.close(closing)

        #expect(fixture.registry.primary === fixture.other)
        #expect(fixture.registry.windows.map(\.id) == [fixture.other.id])
        #expect(fixture.session.primaryWindowID == fixture.other.id)
        #expect(fixture.session.primarySelection === fixture.other.selection)
        #expect(fixture.session.windowIDs == [fixture.other.id])
        // What reads the primary now reads the window left.
        #expect(fixture.session.primarySelection.activeTabID == fixture.secondTab.id)
        let view = try #require(fixture.session.projectViews[fixture.first.id])
        #expect(view.activeTabID == fixture.firstTab.id)
    }

    @Test func commandTarget_afterThePrimaryCloses_isAShownWindow() throws {
        let fixture = try Fixture()
        fixture.registry.windowBecameKey(fixture.primary.id)

        fixture.close(fixture.primary)

        #expect(fixture.registry.backgroundCommandTarget === fixture.other)
        #expect(fixture.registry.noticeWindow === fixture.other)
    }

    @Test func aClosedKeyWindow_leavesNoCommandTarget() throws {
        let fixture = try Fixture()
        fixture.registry.windowBecameKey(fixture.other.id)

        fixture.close(fixture.other)

        // Closed, it has no keyboard; AppKit makes another window key and
        // that one reports in turn.
        #expect(fixture.registry.commandTarget == nil)
        fixture.registry.windowBecameKey(fixture.primary.id)
        #expect(fixture.registry.commandTarget === fixture.primary)
    }

    @Test func closingAWindowNeverLeavesTwoHidden() throws {
        let fixture = try Fixture()
        fixture.close(fixture.other)
        fixture.close(fixture.primary)
        let hidden = fixture.primary
        // A window on the second project beside the hidden one, which no
        // entry point opens (one asked of a hidden window switches it in
        // place, `openInNewWindow`): the close must still leave one hidden.
        let opened = fixture.windowBeside(hidden, showing: fixture.second)
        #expect(opened !== hidden)
        #expect(!opened.isHidden)

        fixture.close(opened)

        #expect(fixture.registry.windows.map(\.id) == [opened.id])
        #expect(fixture.registry.windows.filter(\.isHidden).count == 1)
        #expect(opened.isHidden)
        #expect(fixture.registry.primary === opened)
        #expect(fixture.session.windowIDs == [opened.id])
        #expect(fixture.presenter.closed.last == hidden.id)
        // The window that ended keeps its project's view.
        let view = try #require(fixture.session.projectViews[fixture.first.id])
        #expect(view.activeTabID == fixture.firstTab.id)
    }

    // MARK: - What the closed window held

    @Test func aClosedWindowsPanes_stopCountingAsDrawnOrSeen() throws {
        let fixture = try Fixture()
        let pane = fixture.secondPane
        fixture.registry.didReportDisplay(window: fixture.other.id, rendered: [pane], attended: [pane])
        #expect(fixture.registry.visibility.union.contains(pane))
        #expect(fixture.registry.attention.attendedPanes == [pane])

        fixture.close(fixture.other)

        #expect(!fixture.registry.visibility.union.contains(pane))
        #expect(fixture.registry.attention.attendedPanes.isEmpty)
    }

    @Test func aClosedWindowsToastsCardsAndAnchors_go() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        let approvals = ApprovalPresentationStore()
        let card = fixture.other.approvalCard
        fixture.tidiesOnClose(into: toasts)
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        approvals.receive([request])
        let closed = fixture.other.id
        card.updateRowAnchor(CGRect(x: 0, y: 40, width: 200, height: 20), for: request, in: approvals)
        card.present(request, from: approvals)
        toasts.show(ToastItem(message: .verbatim("Done"), undo: nil), in: closed)

        fixture.close(fixture.other)

        #expect(toasts.current(in: closed) == nil)
        #expect(card.state == ApprovalCardState())
        #expect(card.presentedApproval(in: approvals) == nil)
        #expect(card.rowAnchor(for: request) == nil)
        // The request itself waits on, to be opened again.
        #expect(approvals.pending.map(\.id) == [request.id])
    }

    @Test func aNoticeFixedToAClosedWindow_movesToAShownOne() throws {
        let fixture = try Fixture()
        let placed = fixture.other.id

        fixture.close(fixture.other)

        #expect(fixture.registry.placeNotice(keeping: placed) { fixture.registry.noticeWindow } == fixture.primary.id)
    }

    @Test func theScratchOfAClosedWindow_goesToAnotherThatHasItSelected() throws {
        let fixture = try Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.other.id)
        // The primary has it selected too, without having chosen it.
        fixture.session.setActiveTab(scratch.id, in: fixture.primary.id, intent: .repair)
        #expect(fixture.session.scratchDrawingWindowID == fixture.other.id)

        fixture.close(fixture.other)

        #expect(fixture.session.scratchDrawingWindowID == fixture.primary.id)
        #expect(fixture.session.windows(showing: scratch.id) == [fixture.primary.id])
        // The closed window's project comes back to the scratch tab it was on.
        let view = try #require(fixture.session.projectViews[fixture.second.id])
        #expect(view.activeContainerID == .loose)
        #expect(view.activeTabID == scratch.id)
    }

    @Test func theViewAClosedWindowLeaves_movesNoWindowOnScratchWithNoProject() throws {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("only"), suggestedName: "only")
        let projectTab = session.openTab(container: .project(project.id))
        let scratch = session.openTab(container: .loose)
        session.setActiveTab(scratch.id)
        // The primary has shown no project: the only one is another window's.
        session.primarySelection.projectID = nil
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let id = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(projectTab.id, in: id)
        let selection = try #require(session.selection(id))
        selection.projectID = project.id
        let window = registry.addWindow(selection)
        registry.show(session.primaryWindowID)
        registry.show(id)
        #expect(session.primarySelection.shownProjectID == nil)

        registry.close(window.id, in: session)

        #expect(session.primarySelection.activeTabID == scratch.id)
        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.primarySelection.projectID == nil)
        #expect(session.projectViews[project.id]?.activeTabID == projectTab.id)
    }

    // MARK: - Work that ends after its window closed

    @Test(.timeLimit(.minutes(1)))
    func aSetupFinishingAfterItsWindowClosed_movesNoOtherWindow() async throws {
        try await withTempDir { dir in
            let fixture = try await SessionLaunchFixture.make(in: dir, bootstrap: [.shorthand("sleep 0.3")])
            let session = fixture.session
            let row = ContainerID.worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            // The primary shows another project, on its empty row.
            let elsewhere = session.addOrActivateProject(rootURL: dir.appendingPathComponent("elsewhere"), suggestedName: "elsewhere")
            session.setActiveContainer(.project(elsewhere.id))
            session.primarySelection.projectID = elsewhere.id
            let registry = WindowRegistry(primary: session.primarySelection)
            registry.presenter = RecordingWindowPresenter()
            // The session is asked for in a second window, on its empty row,
            // where the tab would come to front.
            let launching = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(row, in: launching)
            try registry.addWindow(#require(session.selection(launching)))
            registry.show(session.primaryWindowID)
            registry.show(launching)
            fixture.store.begin(
                projectID: fixture.project.id,
                worktreeID: fixture.worktree.id,
                request: SessionLaunchRequest(open: .shell),
                in: session,
                window: launching
            )

            registry.close(launching, in: session)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                !fixture.tabs.isEmpty
            }

            let tab = try #require(fixture.tabs.first)
            #expect(session.windowIDs == [session.primaryWindowID])
            #expect(session.primarySelection.activeContainerID == .project(elsewhere.id))
            #expect(session.primarySelection.activeTabID == nil)
            // The row the window left shows the new tab when the project is
            // shown again: the tab would have come to front there.
            #expect(session.projectViews[fixture.project.id]?.activeContainerID == row)
            #expect(session.projectViews[fixture.project.id]?.activeTabID == tab.id)
        }
    }

    @Test func anAwaitedOpenFromAClosedWindow_writesNoPrimarySelection() async throws {
        let fixture = try Fixture()
        let before = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))
        let folder = URL(fileURLWithPath: "/weir-opened-\(UUID().uuidString)")

        let project = await fixture.session.openProject(at: folder, in: fixture.other.id, intent: .person) { url in
            // The window closes while the folder is resolved.
            fixture.close(fixture.other)
            return url
        }

        #expect(fixture.session.windowIDs == [fixture.primary.id])
        #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == before)
        #expect(fixture.session.projectViews[project.id] == nil)
        let tab = try #require(fixture.session.tabs(in: .project(project.id)).first)
        #expect(fixture.session.project(project.id)?.lastActiveTabID == tab.id)
    }

    @Test func aPaletteRunAddressedToAClosedWindow_doesNothing() throws {
        let fixture = try Fixture()
        let closed = fixture.other.id
        fixture.close(fixture.other)
        let before = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))

        try CommandPaletteActions.runRowForTest(
            .activateProject(fixture.second.id),
            session: fixture.session,
            window: closed,
            commands: fixture.registry
        )

        #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == before)
        #expect(fixture.session.windowIDs == [fixture.primary.id])
        // The row a window's chrome would run is for that window alone: a
        // closed window runs nothing, and no other window runs it for it.
        let ranInPrimary = Recorded(false)
        let token = fixture.primary.commands.requests.sink { _ in ranInPrimary.value = true }
        defer { token.cancel() }
        let execution = CommandPaletteExecution(action: .activateProject(fixture.second.id), windowID: closed)
        #expect(!fixture.registry.perform(.runPaletteRow(execution), in: closed))
        #expect(!ranInPrimary.value)
    }

    @Test func aRestoreFinishingAfterItsWindowClosed_offersUndoInAnotherWindow() throws {
        let fixture = try Fixture()
        let pane = fixture.secondPane
        let closed = fixture.other
        // Open, it is told where it began.
        let open = RestoreActions.places(forEndOf: closed, paneID: pane, registry: fixture.registry, session: fixture.session)
        #expect(open.toast === closed)
        #expect(open.bar === closed)

        fixture.close(closed)

        // No window shows the pane: the toast, with its Undo, is told in
        // the window left, and no bar takes the "Done" line.
        let gone = RestoreActions.places(forEndOf: closed, paneID: pane, registry: fixture.registry, session: fixture.session)
        #expect(gone.toast === fixture.primary)
        #expect(gone.bar == nil)

        // Shown again in a window of its own, the project's window tells it,
        // and the bar of the window that draws the pane takes the line.
        let reopened = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        let again = RestoreActions.places(forEndOf: closed, paneID: pane, registry: fixture.registry, session: fixture.session)
        #expect(again.toast === reopened)
        #expect(again.bar === reopened)
    }

    // MARK: - The toast

    @Test func theToast_isToldInTheWindowLeft_withTheProjectsName() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)

        fixture.close(fixture.other)

        let toast = try #require(toasts.current(in: fixture.primary.id))
        guard case let .localized(message) = toast.message else {
            Issue.record("the toast is localized")
            return
        }
        #expect(message.resolved(in: Self.english) == "Closed the window. second’s agents and terminals keep running.")
        #expect(toast.undo == nil)
    }

    @Test func closingAnEmptyWindow_showsNoToast() throws {
        let fixture = try Fixture()
        let empty = try fixture.addEmptyWindow()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)

        fixture.close(empty)

        #expect(fixture.registry.window(empty.id) == nil)
        #expect(toasts.items.isEmpty)
    }

    @Test func theLastWindowHidden_showsNoToast_norTheEarlierHiddenOneEnding() throws {
        let fixture = try Fixture()
        fixture.close(fixture.other)
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)

        fixture.close(fixture.primary)
        #expect(toasts.items.isEmpty)

        // The hidden one ends as a window beside it is closed and hidden in
        // turn: nothing is told in the window going away.
        let opened = fixture.windowBeside(fixture.primary, showing: fixture.second)
        fixture.close(opened)

        #expect(fixture.registry.windows.map(\.id) == [opened.id])
        #expect(toasts.items.isEmpty)
    }
}
