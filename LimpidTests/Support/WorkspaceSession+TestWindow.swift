// WorkspaceSession+TestWindow.swift
// Limpid — test overloads that pick the window (the primary when none is named) and the person's intent, for suites that
// test what a selection does.

import Foundation
@testable import Limpid

// Every selection names its window and why it is made, so none
// falls back to a window or a reason its caller did not choose. Most suites
// test what a selection does, not which window it lands in or for whom, so
// they make it through these: in the window named, or the primary when none
// is, as the person's choice, and a tab opened selected. A suite about
// windows or intents passes its own `WindowID` and `SelectionIntent` to the
// production signatures, which these never shadow: each one here leaves out
// the intent.

extension WorkspaceSession {
    /// The window a test names, or the primary when it names none.
    fileprivate func testWindow(_ window: WindowID?) -> WindowID {
        window ?? primaryWindowID
    }

    func showsScratch(in window: WindowID?) -> Bool {
        showsScratch(in: testWindow(window))
    }

    func claimScratch(for window: WindowID?) {
        claimScratch(for: testWindow(window))
    }

    func setActiveTab(_ tabID: UUID?, in window: WindowID? = nil) {
        setActiveTab(tabID, in: testWindow(window), intent: .person)
    }

    func setActiveContainer(_ container: ContainerID, in window: WindowID? = nil) {
        setActiveContainer(container, in: testWindow(window), intent: .person)
    }

    @discardableResult
    func activateProject(_ projectID: UUID, in window: WindowID? = nil) -> Tab? {
        activateProject(projectID, in: testWindow(window), intent: .person)
    }

    @discardableResult
    func openTab(
        container: ContainerID,
        title: String? = nil,
        workingDirectory: URL? = nil,
        in window: WindowID? = nil
    ) -> Tab {
        openTab(
            container: container,
            title: title,
            workingDirectory: workingDirectory,
            in: testWindow(window),
            intent: .person,
            selects: true
        )
    }

    /// A tab in the primary window's container, which it always has.
    @discardableResult
    func openTabInActiveScope() -> Tab {
        openTab(container: primarySelection.activeContainerID, in: primaryWindowID, intent: .person, selects: true)
    }

    @discardableResult
    func openTabInActiveScope(in window: WindowID?) -> Tab? {
        openTabInActiveScope(in: testWindow(window), intent: .person)
    }

    @discardableResult
    func openProject(
        at url: URL,
        in window: WindowID? = nil,
        resolveMainCheckout: (URL) async -> URL = GitProcess.resolveMainCheckout(of:)
    ) async -> Project {
        await openProject(at: url, in: testWindow(window), intent: .person, resolveMainCheckout: resolveMainCheckout)
    }

    @discardableResult
    func addOrActivateProject(rootURL: URL, suggestedName: String? = nil, in window: WindowID? = nil) -> Project {
        addOrActivateProject(rootURL: rootURL, suggestedName: suggestedName, in: testWindow(window), intent: .person)
    }

    func recordNavigation(from previous: NavTarget, in window: WindowID? = nil) {
        recordNavigation(from: previous, in: testWindow(window))
    }

    func navigateBack(in window: WindowID? = nil) {
        navigateBack(in: testWindow(window), intent: .person)
    }

    func navigateForward(in window: WindowID? = nil) {
        navigateForward(in: testWindow(window), intent: .person)
    }

    @discardableResult
    func createGitWorktree(
        projectID: UUID,
        path: URL,
        baseBranch: String,
        newBranchName: String?,
        openTab: Bool,
        in window: WindowID? = nil,
        git: any GitRunning = LiveGit()
    ) async throws -> Worktree {
        try await createGitWorktree(
            projectID: projectID,
            path: path,
            baseBranch: baseBranch,
            newBranchName: newBranchName,
            openTab: openTab,
            in: testWindow(window),
            intent: .person,
            git: git
        )
    }
}

extension TabActions {
    static func newTab(_ session: WorkspaceSession, in window: WindowID? = nil) {
        newTab(session, in: session.testWindow(window), intent: .person)
    }

    @discardableResult
    static func newTab(
        _ session: WorkspaceSession,
        in container: ContainerID,
        running agent: AgentKind?,
        window: WindowID? = nil
    ) -> UUID? {
        newTab(session, in: container, running: agent, window: session.testWindow(window), intent: .person, selects: true)
    }

    @discardableResult
    static func newTab(
        _ session: WorkspaceSession,
        in container: ContainerID,
        typing command: String,
        window: WindowID? = nil
    ) -> UUID? {
        newTab(session, in: container, typing: command, window: session.testWindow(window), intent: .person, selects: true)
    }

    static func reopenClosedTab(_ session: WorkspaceSession, specificID: UUID? = nil, in window: WindowID? = nil) {
        reopenClosedTab(session, specificID: specificID, in: session.testWindow(window), intent: .person)
    }

    static func movePaneToNewTab(_ session: WorkspaceSession, paneID: UUID, in window: WindowID? = nil) {
        movePaneToNewTab(session, paneID: paneID, in: session.testWindow(window), intent: .person)
    }

    static func mergePaneIntoTab(
        _ session: WorkspaceSession,
        paneID: UUID,
        into targetTabID: UUID,
        in window: WindowID? = nil
    ) {
        mergePaneIntoTab(session, paneID: paneID, into: targetTabID, in: session.testWindow(window), intent: .person)
    }
}

extension SearchActions {
    static func beginSearch(_ session: WorkspaceSession, in window: WindowID? = nil) {
        beginSearch(session, in: session.testWindow(window))
    }

}

extension PaneActions {
    static func split(
        _ session: WorkspaceSession,
        direction: SplitDirection,
        registry: (any SurfaceViewProviding)? = nil,
        minPaneSize: PaneMinimumSize = .zero,
        toastCenter: ToastCenter? = nil,
        in window: WindowID? = nil
    ) {
        split(
            session,
            direction: direction,
            registry: registry,
            minPaneSize: minPaneSize,
            toastCenter: toastCenter,
            in: session.testWindow(window)
        )
    }

    static func closeActivePane(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        agentProjection: AgentProjectionAdapter? = nil,
        in window: WindowID? = nil
    ) {
        closeActivePane(
            session,
            registry: registry,
            source: source,
            attention: attention,
            agentProjection: agentProjection,
            in: session.testWindow(window)
        )
    }

    static func focusPane(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        direction: SpatialDirection,
        in window: WindowID? = nil
    ) {
        focusPane(session, registry: registry, direction: direction, in: session.testWindow(window))
    }

    static func activateAndFocus(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID,
        in window: WindowID? = nil
    ) {
        activateAndFocus(
            session,
            registry: registry,
            tabID: tabID,
            paneID: paneID,
            in: session.testWindow(window),
            intent: .person
        )
    }

    static func unzoom(_ session: WorkspaceSession, tabID: UUID, in window: WindowID? = nil) {
        unzoom(session, tabID: tabID, in: session.testWindow(window), intent: .person)
    }

    static func toggleZoom(_ session: WorkspaceSession, in window: WindowID? = nil) {
        toggleZoom(session, in: session.testWindow(window))
    }

    static func equalizeSplits(_ session: WorkspaceSession, in window: WindowID? = nil) {
        equalizeSplits(session, in: session.testWindow(window))
    }
}

extension NavActions {
    static func activateTabInActiveContainer(at index: Int, in session: WorkspaceSession, window: WindowID? = nil) {
        activateTabInActiveContainer(at: index, in: session, window: session.testWindow(window), intent: .person)
    }

    static func cycleTab(_ session: WorkspaceSession, forward: Bool, in window: WindowID? = nil) {
        cycleTab(session, forward: forward, in: session.testWindow(window), intent: .person)
    }
}

extension SessionLaunchStore {
    func begin(
        projectID: UUID,
        worktreeID: UUID,
        request: SessionLaunchRequest,
        notes: [SessionLaunch.Note] = [],
        in session: WorkspaceSession,
        window: WindowID? = nil
    ) {
        begin(
            projectID: projectID,
            worktreeID: worktreeID,
            request: request,
            notes: notes,
            in: session,
            window: session.testWindow(window)
        )
    }

    /// Keeps the launch's window, as a bar with no window of its own would.
    func retry(worktreeID: UUID, in session: WorkspaceSession) {
        retry(worktreeID: worktreeID, in: session, window: nil)
    }

    /// Keeps the launch's window, as a bar with no window of its own would.
    func skipSetup(worktreeID: UUID, in session: WorkspaceSession) {
        skipSetup(worktreeID: worktreeID, in: session, window: nil)
    }

    @discardableResult
    func open(
        _ choice: WorktreeOpenChoice,
        in container: ContainerID,
        session: WorkspaceSession,
        window: WindowID? = nil
    ) -> UUID? {
        open(
            SessionLaunchRequest(open: choice),
            in: container,
            session: session,
            window: session.testWindow(window),
            intent: .person,
            selects: true
        )
    }
}

extension ToastCenter {
    /// A toast whose caller knows no window: the one in front.
    func show(_ item: ToastItem) {
        showInFrontWindow(item)
    }
}

extension SessionSidebarModel {
    @MainActor
    init(
        project: Project?,
        session: WorkspaceSession,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation],
        approvals: ApprovalLedger,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?,
        locale: Locale
    ) {
        self.init(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: queue,
            runtimes: runtimes,
            approvals: approvals,
            pullRequest: pullRequest,
            gitFacts: gitFacts,
            locale: locale
        )
    }

    @MainActor
    init(
        activeIn session: WorkspaceSession,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation],
        approvals: ApprovalLedger,
        pullRequest: PRInfo?,
        gitFacts: GitFacts?,
        locale: Locale
    ) {
        self.init(
            activeIn: session,
            window: session.primaryWindowID,
            queue: queue,
            runtimes: runtimes,
            approvals: approvals,
            pullRequest: pullRequest,
            gitFacts: gitFacts,
            locale: locale
        )
    }
}

extension PaneStripModel {
    @MainActor
    init(
        container: ContainerID,
        session: WorkspaceSession,
        queue: AttentionQueue,
        mountedTmuxPaneIDs: Set<UUID>,
        reviewTab: ReviewTab
    ) {
        self.init(
            container: container,
            session: session,
            window: session.primaryWindowID,
            queue: queue,
            mountedTmuxPaneIDs: mountedTmuxPaneIDs,
            reviewTab: reviewTab
        )
    }
}

extension SupervisionPaletteFacts {
    /// A window with no project, one session row at most, and no review
    /// tab: what a test that does not ask about the window's rows hands the
    /// palette.
    static let empty = SupervisionPaletteFacts(projectID: nil, sessionRowCount: 0, hasReviewTab: false)
}

extension CommandPaletteCatalog {
    static func buildItems(
        session: WorkspaceSession,
        settings: SettingsStore,
        attention: AttentionState,
        registry: (any SurfaceViewProviding)? = nil,
        supervision: SupervisionPaletteFacts = .empty,
        locale: Locale
    ) -> [CommandPaletteItem] {
        buildItems(
            session: session,
            settings: settings,
            attention: attention,
            registry: registry,
            supervision: supervision,
            window: session.primaryWindowID,
            locale: locale
        )
    }
}
