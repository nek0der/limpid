// SupervisionWindowActions.swift
// Limpid — the supervision window's own actions, shared by the menu bar and the palette.

import os
import SwiftUI

private let log = Logger.limpid("supervision.keys")

/// What the supervision window's own keys do. The menu bar runs them
/// in the key main window (`WindowRegistry.commandTarget`); the palette
/// reaches them through a notification the window's root receives, since
/// Core, where the palette dispatches, cannot name a window.
@MainActor
enum SupervisionWindowActions {
    /// These are the palette's rows whose keys the window's menu runs itself, since
    /// Core cannot name what they act on: ⌘[ ⌘] over the session rows, ⇧⌘[ ⇧⌘]
    /// through the review tab, ⌘W ⌥⌘W closing the review tab while it
    /// is in front, and the pane commands, which do nothing while it is.
    /// We run them here as the menu runs them, so a row and its key never do
    /// two things. It returns false for any other row, and for a close with
    /// no review in front, which the shared dispatch then runs in the
    /// window.
    static func runPaletteShortcut(_ action: LimpidShortcutAction, in window: ProjectWindowState, state: AppState) -> Bool {
        // A pane command while the review is in front does nothing, as its
        // row is off (`ProjectWindowState.arePanesHidden`): the review may
        // have come to the front since the palette was built.
        if SupervisionPaletteFacts.isOffPaneCommand(action, arePanesHidden: window.arePanesHidden) {
            return true
        }
        let paneVisibility = PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry)
        switch action {
        case .nextSession, .previousSession:
            SessionRowNavigation.cycle(
                forward: action == .nextSession,
                in: window,
                session: state.session,
                sections: state.sidebarSections(in: window)
            )
            return true
        case .nextTab, .previousTab:
            ReviewTabActions.cycleTab(
                forward: action == .nextTab,
                window: window,
                session: state.session,
                registry: state.registry,
                paneVisibility: paneVisibility
            )
            return true
        case .closeSurface, .closeTab:
            return ReviewTabActions.closeIfInFront(stores: state.reviewTabStores)
        default:
            return false
        }
    }

    /// ⌃⌘J: the Needs Attention list, hung from its pill in the title bar.
    static func showNeedsAttention(in window: ProjectWindowState) {
        window.toggleTitleBarMenu(.needsAttention, anchor: window.needsAttentionAnchor, isOpenedFromKeyboard: true)
    }

    /// ⇧⌘A: Open Tabs for the session the window shows, hung from its
    /// strip's leading button. A window choosing a project shows no strip,
    /// and so has nothing to list.
    static func showOpenTabs(in window: ProjectWindowState) {
        guard !window.selection.isChoosingProject, window.openTabsAnchor != .zero else { return }
        window.toggleTitleBarMenu(
            .openTabs(window.selection.activeContainerID),
            anchor: window.openTabsAnchor,
            isOpenedFromKeyboard: true
        )
    }

    /// Go Back, from the menu or the title bar's back button: one step back
    /// in `window`'s own history: the menu's focused window, or the
    /// window the button is in, which need not be the key one.
    static func goBack(in window: ProjectWindowState, session: WorkspaceSession) {
        closeFloatingSurfaces(in: window, session: session)
        session.navigateBack(in: window.id, intent: .person)
    }

    /// Go Forward, from the menu or the title bar's forward button.
    static func goForward(in window: ProjectWindowState, session: WorkspaceSession) {
        closeFloatingSurfaces(in: window, session: session)
        session.navigateForward(in: window.id, intent: .person)
    }

    /// The window's open dropdown and its palette close before a step
    /// through the history: both describe the place the window is leaving
    /// (its worktree ▾ checks the old row, its palette's rows were built
    /// for it), as a switch to another project closes them
    /// (`WindowProjectSwitch.tidy`). A palette open in another window is
    /// that window's, and stays.
    private static func closeFloatingSurfaces(in window: ProjectWindowState, session: WorkspaceSession) {
        if window.titleBarMenu != nil {
            window.titleBarMenu = nil
        }
        if session.commandPaletteState?.windowID == window.id {
            CommandPaletteActions.closeCommandPalette(session)
        }
    }

    /// ⇧⌘W: closes the window, or hides it when it is the last one shown;
    /// its agents and terminals keep running.
    static func closeWindow(_ window: ProjectWindowState, registry: WindowRegistry, session: WorkspaceSession) {
        registry.close(window.id, in: session)
    }

    /// ⌘N, the worktree menu's "New Worktree…", and the palette: the new
    /// worktree sheet for the project the window shows,
    /// or for `projectID` (a header's ＋, which a window that shows
    /// no project has too). With neither, nothing opens.
    static func newSession(in window: ProjectWindowState, session: WorkspaceSession, projectID: UUID? = nil) {
        guard let projectID = projectID ?? window.selection.shownProjectID else {
            log.notice("new session asked for in a window with no project")
            return
        }
        // One sheet at a time, and none under another sheet
        // (`NewWorktreeSheetSlot`).
        if window.openNewWorktreeSheet(NewSessionSheetRequest(projectID: projectID)) == .refusedWindowCovered {
            log.notice("new worktree sheet asked for under another sheet")
        }
    }

    /// ⌥⌘N's first use after an update from the release where those keys
    /// opened the sheet: the sheet once more, saying what they do from now
    /// on, rather than a worktree made with nothing asked
    /// (`KeyboardSettings.noteChangedKeys(since:)`). Whether it took ⌥⌘N;
    /// the note is recorded as said once the sheet is up.
    static func introduceInstantWorktree(in window: ProjectWindowState, keyboard: KeyboardSettings) -> Bool {
        guard keyboard.isIntroductionDue(for: .newWorktreeNow),
              let projectID = window.selection.shownProjectID
        else { return false }
        window.openNewWorktreeSheet(NewSessionSheetRequest(projectID: projectID), introducesInstantKey: true)
        return true
    }

    /// A sidebar header's ＋ and its menu's New Worktree in…: the sheet for
    /// that project. A project another window shows is worked on in
    /// that window: it comes forward and opens the sheet, so the
    /// worktree made, its launch, and its tab are all that window's. Any
    /// other project's sheet opens here, and making the worktree switches
    /// this window to it, as choosing one of its rows does.
    static func newWorktree(
        inProject projectID: UUID,
        from window: ProjectWindowState,
        session: WorkspaceSession,
        registry: WindowRegistry
    ) {
        if let other = registry.window(showingProject: projectID, in: session), other.id != window.id {
            registry.raise(other.id, in: session)
            newSession(in: other, session: session)
            return
        }
        newSession(in: window, session: session, projectID: projectID)
    }

    /// Answer… on a row of a project another window shows: that window
    /// comes forward and opens its own card on the request, as the
    /// person goes on there. Any other row's opens this window's card.
    static func answer( // swiftlint:disable:this function_parameter_count
        _ request: ApprovalPresentation,
        inProject projectID: UUID?,
        from window: ProjectWindowState,
        approvals: ApprovalPresentationStore,
        session: WorkspaceSession,
        registry: WindowRegistry
    ) {
        if let projectID, let other = registry.window(showingProject: projectID, in: session), other.id != window.id {
            registry.raise(other.id, in: session)
            other.approvalCard.present(request, from: approvals)
            return
        }
        window.approvalCard.present(request, from: approvals)
    }

    /// A row's Open Changes Panel: the row selected and the panel opened in
    /// the window that shows the row's project, brought forward, which may
    /// be another than the one asked; else in this one, switched to
    /// the row's project as choosing the row does.
    static func openChangesPanel(
        _ row: ContainerID,
        from window: ProjectWindowState,
        session: WorkspaceSession,
        registry: WindowRegistry
    ) {
        if let projectID = row.projectID, let other = registry.window(showingProject: projectID, in: session), other.id != window.id {
            registry.raise(other.id, in: session)
            ChangesPanelActions.open(row, window: other, session: session)
            return
        }
        ChangesPanelActions.open(row, window: window, session: session)
    }

    /// ⌘O and project ▾'s Open Folder…: a folder as a project, shown in
    /// this window.
    static func openFolder(
        from window: ProjectWindowState,
        session: WorkspaceSession,
        registry: WindowRegistry,
        frecency: FrecencyStore?
    ) {
        ProjectFolderPanel.chooseFolder { url in
            Task { await openProject(at: url, from: window, session: session, registry: registry, frecency: frecency) }
        }
    }

    /// A folder opened as a project (⌘O, a recent project in the palette):
    /// `window` switches to it in place, brought back if hidden, or the
    /// window that shows it already comes forward
    /// (`WindowRegistry.show(project:in:from:intent:)`). Asked of a window
    /// already hidden (the File menu's with every window closed), that
    /// window is the one that switches and comes back.
    ///
    /// The folder is resolved first, which takes a while. A person who
    /// moved to another row or project meanwhile, or closed the window, is
    /// not taken back to where they asked from (`intentAfterWait(from:)`):
    /// the project is added, and waits in project ▾ and the palette. No
    /// toast says so: the wait is that of one git command, and what was
    /// opened is one choice away in project ▾. A project shown counts
    /// toward project ▾'s order as choosing it there does (`frecency`), so
    /// one just opened is not listed last. `resolveMainCheckout` is
    /// injectable so a test can act during the wait. Returns the window that
    /// shows the project, `nil` when none was switched to it.
    @discardableResult
    static func openProject(
        at url: URL,
        from window: ProjectWindowState,
        session: WorkspaceSession,
        registry: WindowRegistry,
        frecency: FrecencyStore?,
        resolveMainCheckout: (URL) async -> URL = GitProcess.resolveMainCheckout(of:)
    ) async -> ProjectWindowState? {
        let asked = session.waitOrigin(in: window.id)
        let project = await session.addProject(at: url, resolveMainCheckout: resolveMainCheckout)
        let intent = session.intentAfterWait(from: asked)
        guard intent == .person else {
            log.notice("opened project left behind: the person moved on while it was resolved")
            return nil
        }
        let shown = registry.show(project: project.id, in: session, from: window, intent: intent)
        if shown != nil {
            frecency?.record(ProjectMenuModel.frecencyKey(project.id))
        }
        return shown
    }

    /// Folders handed to Limpid from outside it: Finder's Open With, `open
    /// -a`, a drop on the Dock icon (`LimpidAppDelegate`). The first opens
    /// as ⌘O opens one, in the window the person was last in
    /// (`openProject`); each other in a window of its own, or the window
    /// that shows it already comes forward (`WindowRegistry.openInNewWindow`),
    /// so a drop of several folders leaves none of them only in project ▾.
    /// What is not a folder names no project, and is left alone; nor is a
    /// package (an app, an Xcode project), which ⌘O cannot choose either.
    ///
    /// The window switched in place comes to the front, which ⌘O does not
    /// need: the folder came from another app, or Settings has the
    /// keyboard, so the window it switches may be behind them.
    static func openFolders(
        _ urls: [URL],
        session: WorkspaceSession,
        registry: WindowRegistry,
        frecency: FrecencyStore?,
        resolveMainCheckout: (URL) async -> URL = GitProcess.resolveMainCheckout(of:)
    ) async {
        let folders = urls.filter(isFolder)
        guard let first = folders.first else {
            log.notice("nothing opened from outside: no folder among \(urls.count, privacy: .public) items")
            return
        }
        if let shown = await openProject(
            at: first,
            from: registry.backgroundCommandTarget,
            session: session,
            registry: registry,
            frecency: frecency,
            resolveMainCheckout: resolveMainCheckout
        ) {
            registry.show(shown.id)
        }
        for url in folders.dropFirst() {
            let project = await session.addProject(at: url, resolveMainCheckout: resolveMainCheckout)
            if registry.openInNewWindow(project: project.id, in: session, from: registry.backgroundCommandTarget) != nil {
                frecency?.record(ProjectMenuModel.frecencyKey(project.id))
            }
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // A failed read is no folder: there is nothing to open as a project.
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    /// The palette's rows the supervision window runs itself: the keys its
    /// menu runs differently (`runPaletteShortcut`) and the rows that go
    /// somewhere (`runProjectRow`). `.notHandled` for any other row, which
    /// the shared dispatch runs in this window.
    /// `opensInNewWindow`: the row was committed with ⌘ (`runProjectRow`).
    static func runPaletteAction(
        _ action: CommandPaletteAction,
        in window: ProjectWindowState,
        state: AppState,
        opensInNewWindow: Bool = false
    ) -> PaletteRowHandling {
        if case let .shortcutAction(shortcut) = action {
            return runPaletteShortcut(shortcut, in: window, state: state) ? .handled : .notHandled
        }
        if action == .restoreTurn {
            return RestoreActions.runFromPalette(window: window, state: state)
        }
        return runProjectRow(
            action,
            in: window,
            session: state.session,
            registry: state.windowRegistry,
            frecency: state.frecencyStore,
            opensInNewWindow: opensInNewWindow
        )
    }

    /// File → New Window, the palette, and the Dock menu: a
    /// window that shows nothing yet, or the hidden one.
    static func newWindow(from window: ProjectWindowState?, session: WorkspaceSession, registry: WindowRegistry) {
        registry.openEmptyWindow(in: session, from: window)
    }

    /// A palette row that goes somewhere. This window's own project,
    /// as project ▾ does, changes nothing; another project, or a worktree
    /// or a tab of one, switches this window to that project in place, or
    /// brings forward the window that shows it, as project ▾ does
    /// (`WindowRegistry.show(project:in:from:intent:)`). A worktree or tab
    /// of this window's project is the shared dispatch's, which gives the
    /// terminal back the keyboard after, as does a row with nothing to do.
    /// A project row counts toward project ▾'s order through the palette's
    /// own record of the row; a recent project opened, through
    /// `openProject` (`frecency`).
    ///
    /// Committed with ⌘ (`opensInNewWindow`), a row of another
    /// project, a worktree or a tab of one, opens in a new window instead,
    /// or in the window that shows the project already
    /// (`WindowRegistry.openInNewWindow`), and the row is selected there. A
    /// row of this window's project runs as without ⌘: it is here already.
    static func runProjectRow(
        _ action: CommandPaletteAction,
        in window: ProjectWindowState,
        session: WorkspaceSession,
        registry: WindowRegistry,
        frecency: FrecencyStore?,
        opensInNewWindow: Bool = false
    ) -> PaletteRowHandling {
        let shownProjectID = window.selection.shownProjectID
        // The window that shows the row's project once it is opened with ⌘;
        // `nil` without ⌘, for this window's project, or when none could.
        let newWindow = { (projectID: UUID) -> ProjectWindowState? in
            guard opensInNewWindow, projectID != shownProjectID else { return nil }
            return registry.openInNewWindow(project: projectID, in: session, from: window)
        }
        switch action {
        case let .activateProject(projectID):
            if opensInNewWindow, projectID != shownProjectID {
                return newWindow(projectID) == nil ? .handledReturningKeyboard : .handled
            }
            // The project's terminal takes the keyboard as it is drawn, here
            // or in the window brought forward.
            guard projectID != shownProjectID,
                  registry.show(project: projectID, in: session, from: window, intent: .person) != nil
            else { return .handledReturningKeyboard }
            return .handled
        case let .activateWorktree(projectID, worktreeID):
            guard projectID != shownProjectID else { return .notHandled }
            let target = opensInNewWindow ? newWindow(projectID) : window
            guard let target else { return .handledReturningKeyboard }
            session.setActiveContainer(.worktree(projectID: projectID, worktreeID: worktreeID), in: target.id, intent: .person)
            return .handled
        case let .jumpToTab(tabID):
            guard let projectID = session.tab(tabID)?.container.projectID, projectID != shownProjectID else { return .notHandled }
            let target = opensInNewWindow ? newWindow(projectID) : window
            guard let target else { return .handledReturningKeyboard }
            session.setActiveTab(tabID, in: target.id, intent: .person)
            return .handled
        case let .openRecentProject(url):
            // The project's terminal takes the keyboard as it is drawn once
            // the folder is resolved; until then, or when it is this
            // window's project, this terminal has it.
            Task { await openProject(at: url, from: window, session: session, registry: registry, frecency: frecency) }
            return .handledReturningKeyboard
        default:
            return .notHandled
        }
    }

    /// ⌥⌘0: the keyboard to the sessions sidebar, shown first if hidden.
    /// An open dropdown closes first: closing later would hand the
    /// keyboard back to the terminal.
    static func focusSidebar(in session: WorkspaceSession, window: ProjectWindowState) {
        window.titleBarMenu = nil
        showSidebar(in: session, window: window)
        window.sidebarFocusRequest = UUID()
    }

    /// ⌘B and the sidebar's rail button: the sidebar shown or hidden. While
    /// the panel has folded it, asking is asking to see it: it comes back,
    /// and the panel goes over the terminal if it must.
    static func toggleSidebar(in session: WorkspaceSession, window: ProjectWindowState) {
        // Written only while the window has its selection.
        guard let selection = session.selections[window.id] else { return }
        if selection.sidebarHidden || window.isSidebarFoldedForChanges(isPresented: selection.isChangesPanelPresented) {
            showSidebar(in: session, window: window)
        } else {
            selection.sidebarHidden = true
        }
    }

    /// Asked for, the sidebar stays: with the panel open, the panel makes
    /// room by going over the terminal rather than folding it again.
    private static func showSidebar(in session: WorkspaceSession, window: ProjectWindowState) {
        if let selection = session.selections[window.id], selection.sidebarHidden {
            selection.sidebarHidden = false
        }
        if window.selection.isChangesPanelPresented {
            window.isSidebarKeptOverPanel = true
        }
    }

    /// ⌘⏎ in `paneID`: true when the window took the key.
    static func handlePrimaryKey(
        _ press: PrimaryKeyPress,
        inPane paneID: UUID,
        window: ProjectWindowState,
        state: AppState
    ) -> Bool {
        // A panel over the whole window (All Projects, the keyboard
        // shortcuts) has the person's attention: the bar
        // under it is not what they look at, and the key is spent rather
        // than reaching the terminal under it.
        guard !window.isWindowOverlayPresented else { return true }
        // A stop keeps its bar, and ⌘⏎ with it, after its agent left.
        let hasAgent = DecisionBarModel.hasBar(
            in: paneID,
            runtimes: state.attention.allRuntimes,
            session: state.session,
            queue: state.attentionQueue.queue
        )
        return switch window.primaryActionGate.decide(
            press,
            inPane: paneID,
            hasAgent: hasAgent,
            // Only this window's card: one focused in another window holds
            // back nothing here.
            isApprovalCardFocused: window.approvalCard.isFocused,
            at: SuspendingClock().now
        ) {
        case .passThrough:
            false
        case .swallow:
            true
        case let .perform(action):
            performKey(action, inPane: paneID, window: window, state: state)
        }
    }

    /// The window is back in front: ⌘⏎ waits before it acts.
    static func windowCameToFront(_ window: ProjectWindowState) {
        log.debug("primary key settling restarted for window \(window.id.rawValue, privacy: .public)")
        window.primaryActionGate.restartSettling(at: SuspendingClock().now)
        window.reviewBandGate.restartSettling(at: SuspendingClock().now)
    }

    /// Only a press that did something teaches the key, so only that one
    /// counts toward hiding the hint.
    private static func performKey(_ action: PrimaryAction, inPane paneID: UUID, window: ProjectWindowState, state: AppState) -> Bool {
        if perform(action, inPane: paneID, window: window, state: state) {
            state.primaryKeyHint.noteKeyUse()
        }
        return true
    }

    /// The decision bar's primary button, pressed or reached with ⌘⏎.
    /// Returns whether it did anything.
    @discardableResult
    static func perform(_ action: PrimaryAction, inPane paneID: UUID, window: ProjectWindowState, state: AppState) -> Bool {
        switch action {
        case let .markReviewed(itemID, throughTurn):
            viewedLineActions(window: window, state: state).markViewed(itemID, through: throughTurn, inPane: paneID)
        case let .resume(itemID):
            resume(itemID, inPane: paneID, window: window, state: state)
        case let .notifyAtReset(itemID):
            requestResetNotice(itemID, state: state)
        case let .closeAllTabs(itemID):
            closeAllTabs(itemID, window: window, state: state)
        }
    }

    /// "Close All Tabs" on a worktree that is gone: every
    /// tab of the row the stop names, asked about once as the row's own
    /// menu asks.
    private static func closeAllTabs(_ itemID: AttentionItemID, window: ProjectWindowState, state: AppState) -> Bool {
        guard let item = state.attentionQueue.queue.item(itemID),
              case let .sessionRow(projectID?, root) = item.subject,
              let project = state.session.projects.first(where: { $0.id == projectID }),
              let worktree = project.worktrees.first(where: {
                  $0.workingDirectory.standardizedFileURL == root.standardizedFileURL
              })
        else { return false }
        let container = ContainerID.worktree(projectID: projectID, worktreeID: worktree.id)
        guard !state.session.tabs(in: container).isEmpty else { return false }
        TabActions.closeAllTabs(
            state.session,
            registry: state.registry,
            in: container,
            agentProjection: state.agentProjection,
            from: window.id
        )
        return true
    }

    /// "Notify When It Resets", for the stop `itemID` while it still
    /// offers it (`UsageLimitResetSync.requestIfOffered`).
    static func requestResetNotice(_ itemID: AttentionItemID, state: AppState) -> Bool {
        guard let item = state.attentionQueue.queue.item(itemID) else { return false }
        return state.usageLimitResetSync?.requestIfOffered(item, now: Date()) ?? false
    }

    /// "Resume Same Conversation": types the strict resume into
    /// the shell the stopped agent left, and waits for the conversation to
    /// be back (`StopLedgerStore`). Asked again at the press, as the bar
    /// asked: the shell must be in front with nothing half typed, and no
    /// resume already on its way (a second press would type it twice).
    private static func resume(_ itemID: AttentionItemID, inPane paneID: UUID, window: ProjectWindowState, state: AppState) -> Bool {
        guard let record = state.stopLedger.ledger.record(itemID),
              record.paneID == paneID,
              [.available, .failed].contains(state.stopResumeOffer(record)),
              let command = StopResumeRules.command(for: record),
              let typist = state.registry.view(for: paneID),
              typist.typeAgentCommand(command)
        else {
            log.notice("resume not typed for a stop in its pane")
            // The bar says why at once rather than at its next read.
            state.refreshStopResumeOffers()
            return false
        }
        state.stopLedger.markResuming(itemID, window: window.id)
        state.refreshStopResumeOffers()
        return true
    }

    /// What the window hands its panes for ⌘⏎ and its bars for their
    /// buttons.
    static func primaryActionHandler(window: ProjectWindowState, state: AppState) -> PrimaryActionHandler {
        PrimaryActionHandler(
            windowID: window.id,
            handle: { [window, state] press, paneID in
                handlePrimaryKey(press, inPane: paneID, window: window, state: state)
            },
            perform: { [window, state] action, paneID in
                _ = perform(action, inPane: paneID, window: window, state: state)
            },
            undo: { [window, state] undo, paneID in
                takeBack(undo, inPane: paneID, window: window, state: state)
            },
            startNewConversation: { [window, state] itemID, paneID in
                startNewConversation(itemID, inPane: paneID, window: window, state: state)
            },
            showPartialChanges: { [window, state] itemID, paneID in
                showPartialChanges(itemID, inPane: paneID, window: window, state: state)
            },
            openReview: { [window, state] paneID, conversation in
                Task {
                    await ReviewTabActions.open(
                        .unviewedTurns,
                        agentPaneID: paneID,
                        conversation: conversation,
                        window: window,
                        stores: state.reviewTabStores
                    )
                }
            }
        )
    }

    /// ⋯ "Start New Conversation" on a stop: the agent's own command
    /// at the shell the stopped one left, in the conversation's folder,
    /// under the resume's conditions, and the stop goes; the person chose
    /// not to pick the conversation up.
    private static func startNewConversation(
        _ itemID: AttentionItemID,
        inPane paneID: UUID,
        window _: ProjectWindowState,
        state: AppState
    ) {
        guard let record = state.stopLedger.ledger.record(itemID),
              record.paneID == paneID,
              state.stopStartsNew(record),
              let command = StopResumeRules.newConversationCommand(for: record),
              let typist = state.registry.view(for: paneID),
              typist.typeAgentCommand(command)
        else {
            log.notice("new conversation not typed for a stop in its pane")
            state.refreshStopResumeOffers()
            return
        }
        // Moved on from for good: a relaunch must not resume it again.
        state.forgetStoppedConversation(record)
        state.stopLedger.dismiss(itemID)
    }

    /// ⋯ "Show Partial Changes" on a stop, in the conversation its
    /// turn was recorded in (`ReviewTabRequest.partialChanges`).
    private static func showPartialChanges(_ itemID: AttentionItemID, inPane paneID: UUID, window: ProjectWindowState, state: AppState) {
        guard let record = state.stopLedger.ledger.record(itemID) else { return }
        let conversation = record.turnID.flatMap { state.agentProjection.turnHistory.turn($0)?.conversation } ?? record.conversation
        Task {
            await ReviewTabActions.open(
                .partialChanges(record.turnID),
                agentPaneID: paneID,
                conversation: conversation,
                window: window,
                stores: state.reviewTabStores
            )
        }
    }

    /// Undo on the bar's "Done" line after "Mark as Viewed".
    static func takeBack(_ undo: ViewedLineUndo, inPane paneID: UUID, window: ProjectWindowState, state: AppState) {
        viewedLineActions(window: window, state: state).takeBack(undo, inPane: paneID)
    }

    static func viewedLineActions(window: ProjectWindowState, state: AppState) -> ViewedLineActions {
        ViewedLineActions(
            queue: state.attentionQueue.queue,
            attention: state.attention,
            history: state.agentProjection.turnHistory.conversations,
            lines: state.viewedLines,
            toasts: state.toastCenter,
            window: window
        )
    }
}

/// The window's way to ⌘⏎, handed to each pane's surface, and to
/// the decision bar's buttons. Equal by window, so a redraw of the window
/// does not tell every pane it changed.
struct PrimaryActionHandler: Equatable, Sendable {
    let windowID: WindowID
    let handle: @MainActor @Sendable (PrimaryKeyPress, UUID) -> Bool
    /// The bar's primary button, clicked: the same action, without the
    /// gate, which only keeps a key press from landing on an item it was
    /// not meant for.
    let perform: @MainActor @Sendable (PrimaryAction, UUID) -> Void
    /// The bar's Undo on its "Done" line.
    let undo: @MainActor @Sendable (ViewedLineUndo, UUID) -> Void
    /// The stop's ⋯ "Start New Conversation" and "Show Partial Changes",
    /// by the stop's item and its pane.
    let startNewConversation: @MainActor @Sendable (AttentionItemID, UUID) -> Void
    let showPartialChanges: @MainActor @Sendable (AttentionItemID, UUID) -> Void
    /// The bar's "Review Unviewed": the window's review tab on the pane's
    /// unviewed turns.
    let openReview: @MainActor @Sendable (UUID, ConversationKey?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

extension EnvironmentValues {
    /// Nil outside a supervision window, where ⌘⏎ is the terminal's.
    @Entry var primaryActionHandler: PrimaryActionHandler?
}
