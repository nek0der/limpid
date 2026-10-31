// ReviewTabActions.swift
// Weir — opening, showing, and closing a supervision window's review tab.

import Foundation

/// The one way the supervision window's review tab changes. The tab's state
/// (`ProjectWindowState.review`) and what draws it (the window's
/// `ReviewPresentation` and `ReviewSession`) change here together, so the
/// pane strip, the decision bar, and the pane area never disagree about
/// whether a review is open.
@MainActor
enum ReviewTabActions {
    /// Opens `request` for the agent in `agentPaneID`, in the conversation
    /// given or the one the pane's agent is in: the window's tab reads it,
    /// shown, or a new tab opens. The tab the window's project keeps comes
    /// first (`WindowRegistry.takeParkedReviewBeforeOpening`). When it names
    /// nothing to read, the tab stays as it was and a toast says why. An
    /// open overtaken while it finds the repository (the person moved on) is
    /// dropped.
    static func open(
        _ request: ReviewTabRequest,
        agentPaneID: UUID?,
        conversation: ConversationKey? = nil,
        window: ProjectWindowState,
        stores: ReviewTabStores
    ) async {
        let pending = ReviewOpenRequest(
            containerID: window.selection.activeContainerID,
            tabID: window.selection.activeTabID
        )
        let found = await window.openingReview(pending) { () -> URL? in
            let root = await root(for: agentPaneID, window: window, stores: stores)
            return isCurrent(pending, window: window, session: stores.session) ? root : nil
        }
        guard let root = found else { return }
        stores.windows.takeParkedReviewBeforeOpening(into: window, in: stores.session)
        let context = context(
            agentPaneID: agentPaneID,
            conversation: conversation,
            root: root,
            container: agentPaneID.flatMap { stores.session.tab(containing: $0)?.container } ?? window.selection.activeContainerID,
            stores: stores
        )
        switch ReviewTabModel.open(request, context, root: root.path, agentPaneID: agentPaneID, current: window.review) {
        case let .success(tab):
            apply(tab, window: window, stores: stores)
        case let .failure(reason):
            stores.toasts.show(ToastItem(message: .localized(ReviewTabText.unavailable(reason)), undo: nil), in: window.id)
        }
    }

    /// ⌥⌘R: closes the tab on screen, and otherwise shows it on the unviewed
    /// turns of the focused pane's agent.
    static func toggle(window: ProjectWindowState, stores: ReviewTabStores, paneVisibility: PaneVisibilityReporter) async {
        if window.review?.isShown == true {
            closeAsked(window: window, stores: stores, paneVisibility: paneVisibility)
            return
        }
        let request = ReviewOpenRequest(
            containerID: window.selection.activeContainerID,
            tabID: window.selection.activeTabID
        )
        let paneID = stores.session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID
        let found = await window.openingReview(request) { () -> URL? in
            let root = await root(for: paneID, window: window, stores: stores)
            return isCurrent(request, window: window, session: stores.session) ? root : nil
        }
        guard let root = found else { return }
        stores.windows.takeParkedReviewBeforeOpening(into: window, in: stores.session)
        let context = context(
            agentPaneID: paneID,
            conversation: nil,
            root: root,
            container: window.selection.activeContainerID,
            stores: stores
        )
        switch ReviewTabModel.shortcut(context, root: root.path, agentPaneID: paneID, current: window.review) {
        case .close:
            // The tab may have come to front during the wait, with a comment
            // being written in it: asked, as from its ×.
            closeAsked(window: window, stores: stores, paneVisibility: paneVisibility)
        case let .show(tab):
            apply(tab, window: window, stores: stores)
        }
    }

    /// Closes the tab from its × or ⌥⌘R, unless a comment is being written:
    /// the review keeps it until it is saved or thrown away, and closing
    /// would throw it away unasked.
    static func closeAsked(window: ProjectWindowState, stores: ReviewTabStores, paneVisibility: PaneVisibilityReporter) {
        guard heldCommentRefusal(window) == nil else {
            refuseForUnsavedComment(window: window, stores: stores)
            return
        }
        close(window: window, session: stores.session, registry: stores.registry, paneVisibility: paneVisibility)
    }

    /// Why the tab cannot be closed or read anything else, `nil` when it
    /// can: a comment being written, to save or cancel; or only the text of
    /// one that could not stay where it was written, in the review's banner,
    /// to copy or throw away (`ReviewSession.unplacedComment`).
    static func heldCommentRefusal(_ window: ProjectWindowState) -> ReviewError? {
        guard let review = window.reviewSession, review.holdsComment else { return nil }
        return review.composerHoldsUnsavedText ? .unsavedComment : .unplacedCommentHeld
    }

    /// Says a comment is held, and brings the review it is in to the front
    /// when that review is this session's; another session's would cover a
    /// terminal it has nothing to do with.
    private static func refuseForUnsavedComment(window: ProjectWindowState, stores: ReviewTabStores) {
        if let review = window.review, belongs(review, to: window.selection.activeContainerID, session: stores.session) {
            show(window: window)
        }
        let refusal = heldCommentRefusal(window) ?? .unsavedComment
        stores.toasts.show(ToastItem(message: DisplayText(error: refusal), undo: nil), in: window.id)
    }

    /// ⌘W and ⌥⌘W while the review tab is in front close the review: the
    /// panes and tabs behind it are not on screen, and closing one of them
    /// unseen would close what the person cannot see. `false`
    /// when there is no review in front, and the key closes as before; with
    /// no main window key (Settings is), there is no review in front.
    static func closeIfInFront(stores: ReviewTabStores) -> Bool {
        guard let window = stores.windows.commandTarget, window.review?.isShown == true else {
            return false
        }
        closeAsked(
            window: window,
            stores: stores,
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: stores.windows)
        )
        return true
    }

    /// Closes the tab and goes back to the agent's pane, while it exists.
    /// `returnsToAgent` is false when the person has already gone elsewhere
    /// (another session), which the close must not undo; an open asked for
    /// there (⌘J to another session's turn) is theirs too, and goes on.
    static func close(
        window: ProjectWindowState,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter,
        returnsToAgent: Bool = true,
        inserted: UUID? = nil
    ) {
        if returnsToAgent {
            window.reviewOpenRequest = nil
        }
        guard let tab = window.review else { return }
        let livePanes = session.allPaneIDs
        let pane = returnsToAgent ? ReviewTabModel.paneAfterClosing(tab, livePanes: livePanes, inserted: inserted) : nil
        if let pane, let tabID = session.tab(containing: pane)?.id {
            session.setActiveTab(tabID, in: window.id, intent: .person)
            // The leaf too, not only the keyboard: the bar, the follower,
            // and the panes' dimming read it, and a split's other leaf would
            // take the focus back as it mounts.
            if let shown = session.tab(tabID),
               shown.splitTree.focusedLeafID != pane || shown.zoomedLeafID.map({ $0 != pane }) == true
            {
                session.update(tabID) { tab in
                    tab.splitTree.focusedLeafID = pane
                    // A tab zoomed to another leaf would hide the one in
                    // front. Zoomed to this one instead, rather than
                    // unzoomed: the other leaves keep their columns and
                    // rows, where unzooming would lay every one out again.
                    if tab.zoomedLeafID != nil {
                        tab.zoomedLeafID = pane
                    }
                }
            }
        }
        // The terminals go back on screen in this pass; wake them first so
        // none shows the frame it had when the review covered it.
        ReviewPresentationCommand.reveal(session: session, window: window.id, paneVisibility: paneVisibility)
        window.letGoOfReview()
        if let pane {
            focus(pane, registry: registry)
        }
    }

    /// The window was hidden. Its review closes: a range a hidden window
    /// holds open would never age out, and an open still on its way
    /// would open it again behind the person's back. A comment being
    /// written keeps it, for when the window comes back.
    static func windowHidden(
        window: ProjectWindowState,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter
    ) {
        window.reviewOpenRequest = nil
        guard !window.reviewHasUnsavedComment else { return }
        close(window: window, session: session, registry: registry, paneVisibility: paneVisibility, returnsToAgent: false)
    }

    /// Every comment went into the pane's input: the tab closes to that
    /// pane, where Return sends them, and an agent's bar says so. Only
    /// the tab the insert started in, still in front, with no comment being
    /// written (`ReviewTabModel.closesAfterInsert`). The bar's earlier
    /// choice and "Done" give way, or the sentence would wait behind them.
    /// Says what it did: the tab stays, closes to a shell, or closes to an
    /// agent's pane whose bar says it, unless what waits there (`barItems`,
    /// a request, a stop) keeps the bar (`ReviewTabInsertClose`).
    @discardableResult
    static func closeAfterInsert(
        _ inserted: ReviewTabInserted,
        window: ProjectWindowState,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter,
        barItems: [AttentionItem] = []
    ) -> ReviewTabInsertClose {
        guard ReviewTabModel.closesAfterInsert(window.review, inserted, hasUnsavedComment: window.reviewHasUnsavedComment) else {
            return .stayed
        }
        close(window: window, session: session, registry: registry, paneVisibility: paneVisibility, inserted: inserted.paneID)
        guard let agent = inserted.agent else { return .toShell }
        let done = DecisionBarContent.DoneResult.insertedReview(agent: agent)
        guard DecisionBarContent.takes(done, over: barItems) else {
            // Nor an earlier insert's line, which would speak for this one.
            if window.pendingDecisionBarDone[inserted.paneID]?.showsOverItems == true {
                window.pendingDecisionBarDone[inserted.paneID] = nil
            }
            return .barBusy
        }
        window.forgetDecisionBarChoices(paneID: inserted.paneID)
        window.pendingDecisionBarDone[inserted.paneID] = done
        return .toldOnBar
    }

    /// Brings the review tab in front of the terminal tabs.
    static func show(window: ProjectWindowState) {
        guard window.review?.isShown == false else { return }
        window.review?.isShown = true
    }

    /// The person went to a terminal (⌘J, a notification, ⌘1…9, a click on
    /// a session's row): the review tab goes behind the active tab, still
    /// open, and the keyboard goes to that tab's pane. An open still finding
    /// its repository is dropped, so it does not cover where they went. A
    /// tab a switch to this place just brought back stays, behind: the
    /// arrival is settled here rather than forgotten, so the row the switch
    /// landed on does not close it (`ProjectWindowState
    /// .resolveParkedReviewArrival`).
    static func putBehind(
        window: ProjectWindowState,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter
    ) {
        window.reviewOpenRequest = nil
        let isShown = window.review?.isShown == true
        window.resolveParkedReviewArrival(showsTarget: true)
        guard isShown else { return }
        window.review?.isShown = false
        ReviewPresentationCommand.reveal(session: session, window: window.id, paneVisibility: paneVisibility)
        if let pane = session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID {
            focus(pane, registry: registry)
        }
    }

    /// Puts the review tab behind `tabID`, a terminal tab the person picked,
    /// keeping what it reads for when they come back.
    static func hide(
        window: ProjectWindowState,
        showing tabID: UUID,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter
    ) {
        session.setActiveTab(tabID, in: window.id, intent: .person)
        putBehind(window: window, session: session, registry: registry, paneVisibility: paneVisibility)
    }

    /// ⇧⌘[ ⇧⌘]: the review tab is the last of the strip's tabs, so stepping
    /// past either end of the terminal tabs reaches it.
    static func cycleTab(
        forward: Bool,
        window: ProjectWindowState,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter
    ) {
        let selection = window.selection
        guard let review = window.review, belongs(review, to: selection.activeContainerID, session: session) else {
            NavActions.cycleTab(session, forward: forward, in: window.id, intent: .person)
            return
        }
        let tabs = session.tabs(in: selection.activeContainerID)
        if review.isShown {
            guard let next = forward ? tabs.first : tabs.last else { return }
            hide(window: window, showing: next.id, session: session, registry: registry, paneVisibility: paneVisibility)
            return
        }
        let current = selection.activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        let next = forward ? current + 1 : current - 1
        if tabs.indices.contains(next) {
            session.setActiveTab(tabs[next].id, in: window.id, intent: .person)
        } else {
            show(window: window)
        }
    }

    /// Whether `tab` is `container`'s (`ReviewTabState.belongs`).
    static func belongs(_ tab: ReviewTabState, to container: ContainerID, session: WorkspaceSession) -> Bool {
        tab.belongs(to: container, in: session)
    }

    /// Whether `request` is the window's latest open and the person is still
    /// where they asked for it.
    static func isCurrent(_ request: ReviewOpenRequest, window: ProjectWindowState, session: WorkspaceSession) -> Bool {
        window.reviewOpenRequest == request && request.isStill(
            at: window.selection.activeContainerID,
            tabID: window.selection.activeTabID
        )
    }

    /// What becomes of the review tab as the window moves to another row
    /// (`SessionAreaView`). The review reads the session it was opened in,
    /// and another session's strip has no place for it.
    enum RowChange: Equatable {
        /// It stays as it is: there is none, or the move is the switch that
        /// brought it back with its project, which never closes it
        /// (`ProjectWindowState.isParkedReviewArrival`).
        case keep
        /// A comment held in it keeps it open, behind, back in its own
        /// strip when the person returns.
        case putBehind
        /// Nothing held: it closes.
        case close
    }

    /// The rule of `RowChange`.
    static func rowChange(hasReview: Bool, isArrival: Bool, holdsComment: Bool) -> RowChange {
        guard hasReview, !isArrival else { return .keep }
        return holdsComment ? .putBehind : .close
    }

    /// `rowChange` for `window` as it stands now. Asks for the arrival
    /// first, so any other move forgets it.
    static func rowChange(for window: ProjectWindowState) -> RowChange {
        let isArrival = window.isParkedReviewArrival()
        return rowChange(hasReview: window.review != nil, isArrival: isArrival, holdsComment: window.reviewHasUnsavedComment)
    }

    /// The window has moved to another row (`SessionAreaView`): its review
    /// tab follows `rowChange`, then the window takes, behind, a tab
    /// waiting for the row it arrives at, as a window arriving at a project
    /// takes the project's (`WindowRegistry.takeParkedReview(arrivingAt:in:)`).
    static func rowChanged(
        window: ProjectWindowState,
        session: WorkspaceSession,
        windows: WindowRegistry,
        registry: any SurfaceViewProviding,
        paneVisibility: PaneVisibilityReporter
    ) {
        switch rowChange(for: window) {
        case .keep:
            break
        case .putBehind:
            putBehind(window: window, session: session, registry: registry, paneVisibility: paneVisibility)
        case .close:
            close(window: window, session: session, registry: registry, paneVisibility: paneVisibility, returnsToAgent: false)
        }
        windows.takeParkedReview(arrivingAt: window, in: session)
    }

    /// Whether the active tab changing from `oldTabID` puts the review tab
    /// behind it. A tab closed under the review is not the person moving to
    /// a terminal, so the review stays in front; nor is a window taking up
    /// a project whose review tab another window left behind as it closed or
    /// switched projects (`ProjectWindowState.isParkedReviewArrival`).
    static func activeTabChangePutsReviewBehind(from oldTabID: UUID?, window: ProjectWindowState, session: WorkspaceSession) -> Bool {
        // Asked first, so any other move forgets the arrival.
        let isArrival = window.isParkedReviewArrival()
        guard window.review?.isShown == true, !isArrival else { return false }
        return oldTabID.map { session.tab($0) != nil } ?? true
    }

    /// The tab, applied: the window reads it, with a session on its worktree
    /// (kept when the worktree is the same, so the open file survives a
    /// change of scope), and the presentation asked for its comparison. A
    /// comment being written in the open tab keeps the tab as it is
    /// (`ReviewTabModel.refusesReplacing`).
    private static func apply(_ tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) {
        if ReviewTabModel.refusesReplacing(window.review, with: tab, hasUnsavedComment: window.reviewHasUnsavedComment) {
            refuseForUnsavedComment(window: window, stores: stores)
            return
        }
        // The arrival of a parked tab is over: the tab reads what was asked.
        window.parkedReviewArrival = nil
        let root = URL(fileURLWithPath: tab.root, isDirectory: true)
        if window.reviewSession?.root != root.resolvingSymlinksInPath() {
            window.reviewSession = stores.reviewWriters.session(root: root)
            // Another worktree's review is drawn anew, from nothing of the
            // last one's list, folds, or find bar.
            window.reviewTabView = ReviewTabViewState()
        }
        // Another opening is another review: where the last one was
        // scrolled, or was to be put back, is no place in it.
        if window.review?.opening != tab.opening {
            window.readReviewScroll = nil
            window.reviewScrollRestore = nil
        }
        window.review = tab
        window.reviewPresentation.open(root, originPaneID: tab.destinationPaneID, initialScope: tab.scope)
    }

    private static func focus(_ pane: UUID, registry: any SurfaceViewProviding) {
        Task { @MainActor in
            PaneActions.pullKeyboardFocus(to: pane, registry: registry)
        }
    }

    /// The worktree the review reads: the Git top level of the pane's
    /// project or worktree, or of the directory its shell is in when it is
    /// in neither (a scratch tab). `nil`, with a toast, outside a repository.
    private static func root(for paneID: UUID?, window: ProjectWindowState, stores: ReviewTabStores) async -> URL? {
        let session = stores.session
        let container = paneID.flatMap { session.tab(containing: $0)?.container }
            ?? window.selection.activeContainerID
        let directory = ReviewAgents.directory(for: container, in: session)
            ?? paneID.flatMap { session.workingDirectory(paneID: $0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let directory else { return nil }
        do {
            return try await stores.gitRoot(directory)
        } catch {
            // In a window left, if this one closed during the wait.
            let told = stores.windows.windowForResult(of: window, in: session)
            stores.toasts.show(ToastItem(message: DisplayText(error: error), undo: nil), in: told.id)
            return nil
        }
    }

    /// What the rules know about the agent: the conversation given (the
    /// decision bar's, ⌘J's own), or the one the pane's agent is in by
    /// the same rule the pane's header uses; its turns in this worktree; the
    /// worktree's every conversation, named, with its turns and all of them
    /// as one timeline; and the viewed lines. `container` is the session
    /// the review belongs to, whose panes say which conversations run.
    private static func context(
        agentPaneID: UUID?,
        conversation: ConversationKey?,
        root: URL,
        container: ContainerID,
        stores: ReviewTabStores,
        branchBase: String? = nil
    ) -> ReviewTabModel.Context {
        let conversation = conversation ?? agentPaneID.flatMap { stores.attention.headerRuntime(inPane: $0)?.conversation }
        let turns = conversation.map { conversation in
            ReviewTabModel.turns(
                stores.turnHistory.turns(of: conversation),
                root: root.path,
                conversation: conversation,
                // Links resolved as `ReviewGit` resolves them before it reads
                // a range, so a worktree reached through a link is the same;
                // each recorded root resolved once (`RepositoryRoots`).
                isRoot: { stores.repositoryRoots.isRoot($0, of: .repository(path: root.path)) }
            )
        } ?? []
        var context = ReviewTabModel.Context(
            turns: turns,
            conversation: conversation,
            isViewed: stores.viewedLines.isViewed,
            branchBase: branchBase
        )
        context.isAgentPaneOfNoProject = ReviewTabState.isOfNoProject(agentPaneID: agentPaneID, in: stores.session)
        let restored = stores.restoredTurnIDs()
        context.isRestored = { restored.contains($0.turnID) }
        let conversations = ChangesPanelActions.reviewConversations(root: root.path, container: container, stores: stores.changes)
        context.conversations = conversations.named
        context.conversationTurns = Dictionary(
            conversations.agents.map { ($0.conversation, $0.turns) },
            uniquingKeysWith: { first, _ in first }
        )
        // The timeline from the same turns, as the changes panel builds it.
        context.worktreeTurns = WorktreeTimeline.listed(conversations.agents.flatMap(\.turns))
        return context
    }

    /// The tab's own context: its conversation's turns as of now, for the
    /// dropdown, the turns offered after the range, and "Mark as Viewed".
    static func context(of tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) -> ReviewTabModel.Context {
        var context = context(
            agentPaneID: tab.agentPaneID,
            conversation: tab.conversation,
            root: URL(fileURLWithPath: tab.root, isDirectory: true),
            container: container(of: tab, window: window, stores: stores),
            stores: stores,
            branchBase: window.reviewSession?.base
        )
        context.hasChangesOutsideTurns = !pathsOutsideTurns(of: tab, stores: stores).isEmpty
        context.hasUnviewedChangesOutsideTurns = ReviewTabModel.hasUnviewedChangesOutsideTurns(
            window.reviewOutsideTurnsRead,
            tab: tab,
            listReads: window.reviewSession?.listReadCount ?? 0,
            viewed: stores.viewedLines.outsideTurns[tab.root]
        )
        return context
    }

    /// The paths of the tab's worktree changed outside every turn of its
    /// agents, as the changes panel counts them
    /// (`WorktreeChanges`).
    static func pathsOutsideTurns(of tab: ReviewTabState, stores: ReviewTabStores) -> Set<String> {
        stores.worktreeChanges.outsideTurns[tab.root] ?? []
    }

    /// Counts again what changed outside every turn, each time the review
    /// reads its file list: a person's edit between two turns, or since the
    /// last. The same owner and the same count as the changes
    /// panel's; what it found of the listed files is kept as what the
    /// review read (`ReviewTabModel.OutsideTurnsRead`).
    static func refreshPathsOutsideTurns(window: ProjectWindowState, stores: ReviewTabStores) async {
        guard let tab = window.review else { return }
        // The list this count goes with, taken before it waits behind the
        // panel's: a list read meanwhile has a count of its own coming.
        let listReads = window.reviewSession?.listReadCount ?? 0
        let listed = Set(window.reviewSession?.files.map(\.path) ?? [])
        defer {
            if window.review?.opening == tab.opening, window.reviewSession?.listReadCount ?? 0 == listReads {
                window.reviewOutsideTurnsRead = ReviewTabModel.OutsideTurnsRead(
                    opening: tab.opening,
                    listReads: listReads,
                    counted: stores.worktreeChanges.outsideTurnsContents[tab.root] ?? [:],
                    listed: listed
                )
            }
        }
        await stores.worktreeChanges.refresh(
            root: URL(fileURLWithPath: tab.root, isDirectory: true),
            turns: ChangesPanelModel.turnsHere(
                history: stores.turnHistory.conversations,
                root: tab.root,
                isRoot: { stores.repositoryRoots.isRoot($0, of: .repository(path: tab.root)) }
            ),
            recorded: ChangesPanelModel.recordedNumbers(stores.turnHistory.conversations),
            deleted: stores.viewedLines.deletedTurns {
                stores.repositoryRoots.isRoot($0, of: .repository(path: tab.root))
            }
        )
    }

    /// A choice from the dropdown: the same tab reading it, fixed as of now.
    /// One under another conversation's heading reads that
    /// conversation's turns from now on, and its comments go to that
    /// conversation's pane in the session, or to none until the person
    /// picks one (`ReviewTabModel.select(_:conversation:agentPaneID:in:_:)`).
    /// `conversation` is the conversation the choice is listed under, `nil`
    /// for one no conversation owns, which keeps the tab's.
    static func select(_ option: ReviewScopeOption, conversation: ConversationKey?, window: ProjectWindowState, stores: ReviewTabStores) {
        guard let tab = window.review else { return }
        guard let conversation, conversation != tab.conversation else {
            // The same choice again keeps what was fixed, and what was
            // offered since.
            guard !ReviewTabModel.isSameChoice(option, tab.selection) else { return }
            apply(ReviewTabModel.select(option, in: tab, context(of: tab, window: window, stores: stores)), window: window, stores: stores)
            return
        }
        let pane = ChangesPanelActions.pane(of: conversation, window: window, stores: stores.changes)
        var probe = tab
        probe.conversation = conversation
        if let pane {
            probe.agentPaneID = pane
        }
        let next = ReviewTabModel.select(
            option,
            conversation: conversation,
            agentPaneID: pane,
            in: tab,
            context(of: probe, window: window, stores: stores)
        )
        if ReviewTabModel.refusesReplacing(tab, with: next, hasUnsavedComment: window.reviewHasUnsavedComment) {
            refuseForUnsavedComment(window: window, stores: stores)
            return
        }
        apply(next, window: window, stores: stores)
    }

    /// Reads the files each turn of the tab's range changed, for the file
    /// tags: once per turn, as `WorktreeChanges` keeps them, every
    /// conversation's turn the range reads through. Nothing outside a range
    /// of turns, or in a worktree of one conversation, which has no tags.
    static func loadFileTagPaths(of tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) async {
        guard case let .turns(range) = tab.scope else { return }
        let context = context(of: tab, window: window, stores: stores)
        guard context.conversations.count > 1 else { return }
        let turns = ReviewScopeCatalog.turnsThrough(range, timeline: context.worktreeTurns)
        await stores.worktreeChanges.loadTurnPaths(turns, root: URL(fileURLWithPath: tab.root, isDirectory: true))
    }

    /// The tags on the stacked diff's file headers, by path, from what
    /// `loadFileTagPaths` has read so far.
    static func fileTags(of tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) -> ReviewFileTagSet {
        guard case let .turns(range) = tab.scope else { return ReviewFileTagSet() }
        let context = context(of: tab, window: window, stores: stores)
        let turns = ReviewScopeCatalog.turnsThrough(range, timeline: context.worktreeTurns)
        return ReviewFileTagSet(
            byPath: ReviewFileTags.tags(
                turns: turns,
                paths: { stores.worktreeChanges.paths(of: $0) },
                conversations: context.conversations
            ),
            unreadable: ReviewFileTags.unreadable(
                turns: turns,
                isUnreadable: { stores.worktreeChanges.isUnreadable($0) },
                conversations: context.conversations
            )
        )
    }

    /// Whether the window's review has read what its tab names
    /// (`ReviewTabModel.isShowingItsScope`).
    static func isShowingItsScope(_ tab: ReviewTabState, window: ProjectWindowState) -> Bool {
        guard let session = window.reviewSession else { return false }
        return ReviewTabModel.isShowingItsScope(tab, loadedScope: session.scope, hasLoaded: session.hasLoaded, isLoading: session.isLoading)
    }

    /// "Add to Scope": the range carried on to the turns that ended since it
    /// was fixed. The range on screen's comments and read marks join the
    /// longer one first (`ReviewSession.carryRange`), then the review reads
    /// it the way it reads any change of scope, so the file it opens and the
    /// tab's name move together. Only while the review shows the tab's
    /// range: carried from anything else, the line would end where the
    /// person has not read.
    static func addFollowingTurns(window: ProjectWindowState, stores: ReviewTabStores) {
        guard let tab = window.review, isShowingItsScope(tab, window: window),
              let carried = ReviewTabModel.addFollowingTurns(tab, context(of: tab, window: window, stores: stores)),
              case let .turns(extended) = carried.tab.scope
        else { return }
        if ReviewTabModel.refusesReplacing(tab, with: carried.tab, hasUnsavedComment: window.reviewHasUnsavedComment) {
            refuseForUnsavedComment(window: window, stores: stores)
            return
        }
        guard window.reviewSession?.carryRange(to: extended) == true else { return }
        apply(carried.tab, window: window, stores: stores)
    }

    /// "Mark as Viewed" in the tab's band: the viewed line moves to the end
    /// of the fixed range and the tab closes back to the agent's
    /// pane, whose bar says it is done, with Undo there and on a toast, as
    /// after the bar's own button. On the uncommitted changes, what
    /// changed outside turns is recorded viewed too, as the review read it,
    /// and the same Undo takes it back. A review whose pane has no
    /// conversation (a shell, or an agent not started yet) has no line to
    /// move: it records only the changes outside turns, and its Undo is the
    /// toast's alone. `action` is the one a key press was decided
    /// for; a click takes the band's as drawn. Nothing happens while a
    /// comment is being written, which closing would throw away, or while
    /// the review has not read the tab's range.
    /// Returns whether it moved anything, which is when ⌘⏎ counts toward
    /// hiding its hint.
    @discardableResult
    static func markViewed(
        _ action: ReviewTabModel.MarkViewed? = nil,
        window: ProjectWindowState,
        stores: ReviewTabStores,
        paneVisibility: PaneVisibilityReporter
    ) -> Bool {
        guard let tab = window.review, isShowingItsScope(tab, window: window) else { return false }
        guard !window.reviewHasUnsavedComment else {
            refuseForUnsavedComment(window: window, stores: stores)
            return false
        }
        let context = context(of: tab, window: window, stores: stores)
        // The conversation whose turns the review reads now, which may have
        // started in its pane after the review opened: the line that moves
        // is that one's, and so is its Undo.
        let conversation = context.conversation
        guard let action = action ?? ReviewTabModel.markViewed(tab, context) else { return false }
        let through: ReviewTabTurn?
        switch action {
        case let .throughTurn(turn): through = turn
        case let .includingChangesOutsideTurns(turn): through = turn
        case let .throughTurns(turns):
            return markViewedAcross(turns, context: context, window: window, stores: stores, paneVisibility: paneVisibility)
        }
        let change = through.flatMap { through in context.turns.first { $0.turnID == through.id } }
            .flatMap { stores.viewedLines.markViewed(through: $0, source: .review) }
        // The changes outside turns as the review last read them, with the
        // line's move, so one Undo takes back both. Their own mark is the
        // change's ID, or a new one when no turn was left to view.
        let changeID = change?.id ?? UUID()
        let outside = ReviewTabModel.outsideTurnsToRecord(
            action,
            read: window.reviewOutsideTurnsRead,
            tab: tab,
            listReads: window.reviewSession?.listReadCount ?? 0,
            viewed: stores.viewedLines.outsideTurns[tab.root]
        )
        if let outside {
            stores.viewedLines.markOutsideTurnsViewed(outside, in: tab.root, with: changeID)
        }
        guard change != nil || outside != nil else { return false }
        let livePanes = stores.session.allPaneIDs
        let pane = ReviewTabModel.paneAfterClosing(tab, livePanes: livePanes)
        close(window: window, session: stores.session, registry: stores.registry, paneVisibility: paneVisibility)
        let undo = conversation.map { ViewedLineUndo(conversation: $0, changeID: changeID) }
        let actions = ViewedLineActions(
            queue: stores.attentionQueue.queue,
            attention: stores.attention,
            history: stores.turnHistory.conversations,
            lines: stores.viewedLines,
            toasts: stores.toasts,
            window: window
        )
        // The bar's Undo speaks of the line, which a mark of the changes
        // outside turns alone did not move: the toast takes that back.
        if let pane, change != nil, let undo {
            window.pendingDecisionBarDone[pane] = .markedViewed(undo)
        }
        stores.toasts.show(ToastItem(.markedViewed(through: change?.to?.displayNumber), id: changeID) { [lines = stores.viewedLines] in
            guard let undo else {
                lines.undoOutsideTurnsMark(changeID)
                return
            }
            if let pane {
                actions.takeBack(undo, inPane: pane)
            } else {
                lines.undo(changeID, in: undo.conversation)
            }
        }, in: window.id)
        return true
    }

    /// "Mark as Viewed" on a range across conversations: each
    /// conversation's line moves to its last turn in the range, as one mark
    /// whose toast takes every move back at once, as "Mark as Viewed up to
    /// Here" on the changes panel's timeline does. The tab closes back to
    /// its pane. No decision bar says "Done" for it: a bar is one
    /// conversation's, and its Undo would take back that line alone.
    private static func markViewedAcross(
        _ turns: [ReviewTabTurn],
        context: ReviewTabModel.Context,
        window: ProjectWindowState,
        stores: ReviewTabStores,
        paneVisibility: PaneVisibilityReporter
    ) -> Bool {
        let summaries = turns.compactMap { turn in context.worktreeTurns.first { $0.turnID == turn.id } }
        let actions = ViewedLineActions(
            queue: stores.attentionQueue.queue,
            attention: stores.attention,
            history: stores.turnHistory.conversations,
            lines: stores.viewedLines,
            toasts: stores.toasts,
            window: window
        )
        // The toast names the conversation of the turn it is named after.
        let locale = stores.locale()
        let name: (ConversationKey) -> String? = { key in
            context.conversations.first { $0.conversation == key }.map { ConversationText.name($0, locale: locale) }
        }
        guard !actions.markViewed(through: summaries, source: .review, named: name).isEmpty else { return false }
        close(window: window, session: stores.session, registry: stores.registry, paneVisibility: paneVisibility)
        return true
    }

    /// ⌘⏎ in the review tab: "Mark as Viewed", through the band's gate.
    static func primaryKey(window: ProjectWindowState, stores: ReviewTabStores, paneVisibility: PaneVisibilityReporter) {
        guard let action = window.reviewBandGate.decide(at: SuspendingClock().now) else { return }
        // As on the decision bar: only a press that did something teaches
        // the key, and the two count toward one hint.
        if markViewed(action, window: window, stores: stores, paneVisibility: paneVisibility) {
            stores.primaryKeyHint.noteKeyUse()
        }
    }

    /// The band's button as drawn now, for the gate's wait, by the band of
    /// the tab opened as `opening`. A band of another tab, going as the
    /// window switches project, does not speak for the tab the window has
    /// taken meanwhile, whose band may already be drawn
    /// (`ParkedReview.Tab.open`).
    static func noteBandShown(_ shown: ReviewBandGate.Shown?, of opening: UUID, window: ProjectWindowState) {
        guard window.review?.opening == opening else { return }
        window.reviewBandGate.noteShown(shown, at: SuspendingClock().now)
    }
}
