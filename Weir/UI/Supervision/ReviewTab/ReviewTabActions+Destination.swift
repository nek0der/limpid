// ReviewTabActions+Destination.swift
// Weir — where the review tab's comments go: the panes its destination menu offers, named after the worktree's conversations.

import Foundation

extension ReviewTabActions {
    /// The destination menu's choice: the tab writes to `paneID` from now
    /// on, through any change of scope, until another is chosen or the tab
    /// is opened from another agent.
    static func chooseDestination(_ paneID: UUID, window: ProjectWindowState) {
        guard window.review != nil, window.review?.destinationPaneID != paneID else { return }
        window.review?.destinationPaneID = paneID
        window.reviewPresentation.pinDestination(to: paneID)
    }

    /// Starts the terminal of `paneID`, which is not ready for a paste yet
    /// (`ReviewPasteReadiness`): a pane restored into a tab not shown since,
    /// as a surface is made only for a tab on screen, or one still typing
    /// the command it was restored with. A pane with no surface comes
    /// forward until it is ready (`ReviewPasteReadiness.bringsTabForward`).
    /// The review is then put back in front, so the insert goes on and
    /// closes it onto that pane, but only when the review was in front as
    /// the wait began and the window still shows the pane's tab with the
    /// review's opening and selection unchanged; otherwise the review stays
    /// behind. Returns `false` when the pane was not ready in time.
    static func startPane(
        _ paneID: UUID,
        window: ProjectWindowState,
        stores: ReviewTabStores,
        paneVisibility: PaneVisibilityReporter
    ) async -> Bool {
        func isReady() -> Bool {
            stores.registry.deliverer(for: paneID)?.isReadyForReviewPaste == true
        }
        guard !isReady() else { return true }
        guard let tab = stores.session.tab(containing: paneID) else { return false }
        let deliverer = stores.registry.deliverer(for: paneID)
        let bringsForward = ReviewPasteReadiness.bringsTabForward(
            hasView: deliverer != nil,
            hasSurface: deliverer?.hasTerminalSurface == true
        )
        // We note the review's opening and selection as the wait begins,
        // and only while it is in front: the review is put back in front
        // only when it still reads the same comparison after the wait.
        let shownReview = window.review.flatMap { $0.isShown ? (opening: $0.opening, selection: $0.selection) : nil }
        if bringsForward {
            hide(window: window, showing: tab.id, session: stores.session, registry: stores.registry, paneVisibility: paneVisibility)
        }
        let deadline = ContinuousClock.now + paneStartTimeout
        // A canceled wait is the insert gone; the check below says so.
        while !isReady(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // We put the review back only while the window still shows the pane's
        // tab and the same review reads the same comparison: one who went to another tab,
        // or opened another range, during the wait stays there, and the
        // review, left behind, does not close onto the pane after the
        // insert (`ReviewTabModel.closesAfterInsert`).
        if bringsForward, let shownReview, let review = window.review,
           window.selection.activeTabID == tab.id,
           review.opening == shownReview.opening, review.selection == shownReview.selection
        {
            show(window: window)
        }
        return isReady()
    }

    /// How long an insert waits for a pane's terminal to get ready: a
    /// surface is made in the next layout pass or two, a staged command goes
    /// in 600 ms after it, and its program is waited for at most
    /// `ReviewPasteReadiness.startLimit` more, so a longer wait is one that
    /// is not coming.
    static let paneStartTimeout: Duration = .seconds(5)

    /// The panes the destination menu offers: every pane of the session
    /// the tab belongs to, shells included, started or not (a pane whose
    /// terminal has not started is started by the insert).
    /// `agents` is the worktree's conversations (`conversations(of:window:stores:)`),
    /// read from the same session, so a pane is named as the scope menu's
    /// heading names its conversation.
    static func destinations(
        of tab: ReviewTabState,
        agents: [ConversationChoice],
        window: ProjectWindowState,
        stores: ReviewTabStores
    ) -> [ReviewTabModel.DestinationChoice] {
        let session = stores.session
        let tabs = session.tabs(in: container(of: tab, window: window, stores: stores))
        var tabTitles: [UUID: String] = [:]
        for owner in tabs {
            for pane in owner.splitTree.allLeafIDs() {
                tabTitles[pane] = owner.shownTitle
            }
        }
        return ReviewTabModel.destinationChoices(
            destinationPanes(in: tabs, stores: stores),
            agent: { pane in
                stores.attention.headerRuntime(inPane: pane)?.conversation.flatMap { conversation in
                    agents.first { $0.conversation == conversation }
                }
            },
            tabTitle: { tabTitles[$0] ?? "" }
        )
    }

    /// The same panes, unnamed: what the menu's poll reads what runs in,
    /// with no conversations to ask and no names to give.
    static func destinationPanes(of tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) -> [UUID] {
        destinationPanes(in: stores.session.tabs(in: container(of: tab, window: window, stores: stores)), stores: stores)
            .map(\.paneID)
    }

    private static func destinationPanes(in tabs: [Tab], stores: ReviewTabStores) -> [ReviewDestination] {
        tabs.flatMap { $0.splitTree.allLeafIDs() }.compactMap {
            ReviewAgents.destination(session: stores.session, paneID: $0, registry: stores.registry)
        }
    }

    /// The session the tab belongs to: its agent's pane's, else the
    /// window's. The one source of the panes the destination menu lists
    /// and of the conversations that name them.
    static func container(of tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) -> ContainerID {
        tab.agentPaneID.flatMap { stores.session.tab(containing: $0)?.container } ?? window.selection.activeContainerID
    }

    /// Every conversation of the tab's worktree, named as the scope menu's
    /// headings name them, for the tab's session.
    static func conversations(of tab: ReviewTabState, window: ProjectWindowState, stores: ReviewTabStores) -> [ConversationChoice] {
        ChangesPanelActions.reviewConversations(
            root: tab.root,
            container: container(of: tab, window: window, stores: stores),
            stores: stores.changes
        ).named
    }

    /// Whether the pane the tab writes to is still open.
    static func isDestinationOpen(_ tab: ReviewTabState, session: WorkspaceSession) -> Bool {
        tab.destinationPaneID.map { session.tab(containing: $0) != nil } ?? false
    }
}
