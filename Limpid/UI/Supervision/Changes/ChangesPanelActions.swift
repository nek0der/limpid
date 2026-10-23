// ChangesPanelActions.swift
// Limpid — what the changes panel reads from the app and what its rows and line do.

import Foundation

/// The changes panel's way to the app: the agents of the window's session
/// and their turns, read into `ChangesPanelModel`, and the moves its rows
/// and its line make.
@MainActor
enum ChangesPanelActions {
    /// The rail's button, the menu, the panel's ×, and ⌥⌘I through the
    /// palette's dispatch. The window's layout animates the change.
    /// Written only while the window has its selection.
    static func toggle(_ window: ProjectWindowState, session: WorkspaceSession) {
        guard let selection = session.selections[window.id] else { return }
        selection.isChangesPanelPresented.toggle()
        // A sidebar kept over the panel was kept for that panel.
        if !selection.isChangesPanelPresented {
            window.isSidebarKeptOverPanel = false
        }
    }

    /// A sidebar row's "Open Changes Panel": selects the row, then shows the
    /// panel, never hides it, so the entry does what it says from either
    /// state. Selected first, so the panel opens on that row's turns.
    static func open(_ container: ContainerID, window: ProjectWindowState, session: WorkspaceSession) {
        session.setActiveContainer(container, in: window.id, intent: .person)
        guard let selection = session.selections[window.id], !selection.isChangesPanelPresented else { return }
        toggle(window, session: session)
    }

    /// The session's folder: the project's or worktree's own. `nil` for a
    /// scratch tab's container, which has none and lists no turns.
    static func folder(window: ProjectWindowState, stores: ChangesPanelStores) -> URL? {
        ReviewAgents.directory(for: window.selection.activeContainerID, in: stores.session)
    }

    /// Asks Git once for the folder's top level (`RepositoryRoots`); the
    /// panel opening asks again about a folder found in none.
    static func resolveRoot(window: ProjectWindowState, stores: ChangesPanelStores, isRefreshing: Bool = false) async {
        guard let folder = folder(window: window, stores: stores) else { return }
        await stores.repositoryRoots.resolve(folder, isRefreshing: isRefreshing)
    }

    /// While the panel shows: what changed outside every turn counted
    /// again, and the totals' one comparison read once (`WorktreeChanges`).
    /// `isRefreshing` asks Git again about a folder it did not answer for,
    /// which the panel does as it starts watching, not on every count.
    static func refresh(window: ProjectWindowState, stores: ChangesPanelStores, isRefreshing: Bool) async {
        await resolveRoot(window: window, stores: stores, isRefreshing: isRefreshing)
        guard let root = root(window: window, stores: stores) else { return }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let turns = turnsHere(root: root, stores: stores)
        await stores.worktreeChanges.refresh(
            root: rootURL,
            turns: turns,
            recorded: ChangesPanelModel.recordedNumbers(stores.turnHistory.conversations),
            deleted: stores.viewedLines.deletedTurns {
                stores.repositoryRoots.isRoot($0, of: .repository(path: root))
            }
        )
        if let comparison = totalsComparison(window: window, stores: stores) {
            await stores.worktreeChanges.loadComparison(comparison, root: rootURL)
        }
    }

    /// The comparison the panel's totals read: the worktree's unviewed
    /// range, from the same agents and lines the panel reads
    /// (`ChangesPanelModel.totalsComparison`). It moves with the viewed
    /// lines, so the panel counts it again when a mark moves one.
    static func totalsComparison(window: ProjectWindowState, stores: ChangesPanelStores) -> WorktreeChanges.Comparison? {
        ChangesPanelModel.totalsComparison(railInput(window: window, stores: stores))
    }

    /// Every agent's turns recorded under `root`, as one timeline
    /// (`ChangesPanelModel.timeline`).
    static func timeline(root: String, stores: ChangesPanelStores) -> [TurnSummary] {
        ChangesPanelModel.timeline(turnsHere(root: root, stores: stores))
    }

    /// Every agent's turns recorded under `root`.
    static func turnsHere(root: String, stores: ChangesPanelStores) -> [TurnSummary] {
        ChangesPanelModel.turnsHere(
            history: stores.turnHistory.conversations,
            root: root,
            isRoot: { stores.repositoryRoots.isRoot($0, of: .repository(path: root)) }
        )
    }

    /// The session folder's top level, once Git has named it.
    static func root(window: ProjectWindowState, stores: ChangesPanelStores) -> String? {
        guard let folder = folder(window: window, stores: stores),
              case let .repository(root) = stores.repositoryRoots.answer(for: folder) else { return nil }
        return root
    }

    /// What the turns recorded in the session's worktree are, for counting
    /// again when one starts, ends, or has its end snapshot taken.
    static func turnsKey(window: ProjectWindowState, stores: ChangesPanelStores) -> [TurnsKey] {
        guard let root = root(window: window, stores: stores) else { return [] }
        return turnsHere(root: root, stores: stores).map { TurnsKey(id: $0.turnID, phase: $0.phase, endTree: $0.endTree?.tree) }
    }

    struct TurnsKey: Hashable {
        let id: TurnID
        let phase: TurnPhase
        let endTree: String?
    }

    /// Whether the panel counts: not while Limpid is in the background or
    /// the window is closed, where no one reads the count and Git would
    /// run every few seconds for nothing.
    static func isWatching(window: ProjectWindowState, stores: ChangesPanelStores) -> Bool {
        stores.isAppActive() && !window.isHidden
    }

    /// What the panel shows: the worktree's timeline, narrowed to the
    /// conversation the filter chose (`ChangesPanelModel.make`).
    static func content(window: ProjectWindowState, stores: ChangesPanelStores) -> ChangesPanelModel.Content {
        let folder = folder(window: window, stores: stores)
        let answer = folder.flatMap { stores.repositoryRoots.answer(for: $0) }
        let repository: ChangesPanelModel.Repository = switch answer {
        case .repository: .found
        case .notRepository: .notRepository
        case .unavailable: .unavailable
        case nil: .waiting
        }
        let root: String? = if case let .repository(path) = answer {
            path
        } else {
            nil
        }
        var input = panelInput(answer: answer, window: window, stores: stores)
        // The panel alone says where each conversation runs; the rail,
        // drawn far more often, never reads every pane of the app for it.
        input.liveTab = liveTab(in: window.selection.activeContainerID, stores: stores)
        // The turns are the worktree's, read from its folder, so a worktree
        // with no tab open still lists them; only a selection with no
        // folder (a scratch tab, or a row that is gone) has none to list.
        input.hasWorktree = folder != nil
        input.repository = repository
        input.counts = { stores.worktreeChanges.counts(of: $0) }
        input.pathsOutsideTurns = root.flatMap { stores.worktreeChanges.outsideTurns[$0]?.count }
        input.isOutsideTurnsIncomplete = root.map { stores.worktreeChanges.incompleteOutsideTurns.contains($0) } ?? false
        // One read of what the gate weighs for every row; "Restore Code"
        // asks the gate again when pressed (`RestoreActions.confirm`).
        let gate = stores.restoreGateLookup()
        input.restoreBlocker = { RestoreGate.blocker(gate.input(for: $0)) }
        return ChangesPanelModel.make(input)
    }

    /// What the panel reads, which the rail's badge and tooltip read too:
    /// the agents, the filter, and each one's line. No tab: that is the
    /// panel's own to add (`content`).
    private static func panelInput(
        answer: RepositoryRoots.Answer?,
        window: ProjectWindowState,
        stores: ChangesPanelStores
    ) -> ChangesPanelModel.Input {
        let container = window.selection.activeContainerID
        let focused = stores.session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID
        let running = running(in: container, stores: stores)
        let restored = stores.restoredTurnIDs()
        return ChangesPanelModel.Input(
            agents: agents(answer: answer, running: running, stores: stores),
            running: running,
            chosen: window.selection.changesPanelFilter,
            focused: focused.flatMap { stores.attention.headerRuntime(inPane: $0)?.conversation },
            line: { stores.viewedLines.line(of: $0) },
            isRestored: { restored.contains($0.turnID) }
        )
    }

    /// The restore the panel's record shows: the latest of the session's
    /// worktree that may still be undone, until work goes on from it.
    static func restoreRecord(window: ProjectWindowState, stores: ChangesPanelStores) -> RestoreJournal? {
        root(window: window, stores: stores).flatMap { stores.restoreRecord($0) }
    }

    /// What the rail's button says: the session's turns waiting to be
    /// read, every agent's together, for its badge; and the conversations
    /// with turns to read, named and counted as the panel names and counts
    /// them, for its tooltip's breakdown (`ChangesPanelModel.rail`). Read
    /// on every draw of the rail, so it reads the agents once, never the
    /// panel's rows nor the app's other panes.
    static func railFacts(window: ProjectWindowState, stores: ChangesPanelStores) -> (unviewed: Int, agents: [ConversationChoice]) {
        ChangesPanelModel.rail(railInput(window: window, stores: stores))
    }

    /// The session's turns waiting to be read, every agent's together, as
    /// the rail's badge counts them.
    static func unviewedCount(window: ProjectWindowState, stores: ChangesPanelStores) -> Int {
        ChangesPanelModel.unviewedTotal(railInput(window: window, stores: stores))
    }

    private static func railInput(window: ProjectWindowState, stores: ChangesPanelStores) -> ChangesPanelModel.Input {
        panelInput(
            answer: folder(window: window, stores: stores).flatMap { stores.repositoryRoots.answer(for: $0) },
            window: window,
            stores: stores
        )
    }

    /// The conversations of a review tab's worktree: each with its
    /// turns recorded there, and each named as the panel names it, with
    /// its unviewed turns and the tab that runs it. What the scope menu
    /// heads a section with, and what the destination menu names a pane
    /// after. `container` is the session the tab belongs to
    /// (`ReviewTabActions.container(of:window:stores:)`), whose panes the
    /// destination menu lists, so a pane and its section are named from
    /// the same panes.
    static func reviewConversations(
        root: String,
        container: ContainerID,
        stores: ChangesPanelStores
    ) -> (agents: [ChangesPanelModel.Agent], named: [ConversationChoice]) {
        let running = running(in: container, stores: stores)
        let restored = stores.restoredTurnIDs()
        let input = ChangesPanelModel.Input(
            agents: agents(answer: .repository(path: root), running: running, stores: stores),
            running: running,
            liveTab: liveTab(in: container, stores: stores),
            line: { stores.viewedLines.line(of: $0) },
            isRestored: { restored.contains($0.turnID) }
        )
        return (input.agents, ChangesPanelModel.conversations(input))
    }

    /// The filter's choice: one conversation, or `nil` for all.
    /// Kept with the project's view while the app runs, so the panel
    /// comes back narrowed as it was left; a launch opens it on
    /// "All" (`WindowSelection.changesPanelFilter`).
    static func select(_ conversation: ConversationKey?, window: ProjectWindowState, session: WorkspaceSession) {
        session.selections[window.id]?.changesPanelFilter = conversation
    }

    /// A row: its turn in the review, from the pane its agent runs in.
    static func open(_ turn: TurnSummary, window: ProjectWindowState, stores: ChangesPanelStores) {
        let pane = pane(of: turn.conversation, window: window, stores: stores)
        Task {
            await stores.openReview(.turn(turn.turnID), pane, turn.conversation, window)
        }
    }

    /// "Review Unviewed" in the head: the worktree's unviewed turns, every
    /// conversation's as one comparison, opened from the pane of the
    /// focused conversation when it has one of them, else of the
    /// conversation of the newest (`ChangesPanelModel.reviewConversation`).
    /// The decision bar's button keeps opening its own conversation's.
    static func reviewUnviewed(window: ProjectWindowState, stores: ChangesPanelStores) {
        guard let root = root(window: window, stores: stores) else { return }
        let focused = stores.session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID
            .flatMap { stores.attention.headerRuntime(inPane: $0)?.conversation }
        let restored = stores.restoredTurnIDs()
        let conversation = ChangesPanelModel.reviewConversation(
            timeline(root: root, stores: stores),
            focused: focused,
            isViewed: stores.viewedLines.isViewed,
            isRestored: { restored.contains($0.turnID) }
        )
        let agentPane = conversation.flatMap { Self.pane(of: $0, window: window, stores: stores) }
        Task {
            await stores.openReview(.worktreeUnviewedTurns, agentPane, conversation, window)
        }
    }

    /// "Mark as Viewed up to Here" on a row: every conversation's line
    /// comes up to the row's turn's end (`WorktreeTimeline.marksThrough`).
    /// `name` names a conversation as the toast does.
    static func markViewed(
        through turn: TurnSummary,
        named name: (ConversationKey) -> String?,
        window: ProjectWindowState,
        stores: ChangesPanelStores
    ) {
        let turns = root(window: window, stores: stores).map { Self.timeline(root: $0, stores: stores) } ?? []
        viewedLineActions(window: window, stores: stores).markViewed(through: WorktreeTimeline.marksThrough(turn, in: turns), named: name)
    }

    /// "Mark as Unviewed from Here" on a row: every conversation's line
    /// goes back above the row's place on the timeline
    /// (`WorktreeTimeline.unmarksFrom`), as one mark.
    static func markNotViewed(
        from turn: TurnSummary,
        named name: (ConversationKey) -> String?,
        window: ProjectWindowState,
        stores: ChangesPanelStores
    ) {
        let turns = root(window: window, stores: stores).map { Self.timeline(root: $0, stores: stores) } ?? []
        viewedLineActions(window: window, stores: stores).markNotViewed(from: WorktreeTimeline.unmarksFrom(turn, in: turns), named: name)
    }

    /// "Unmark as Viewed" on the line: the last mark's moves, every
    /// conversation's, go back together.
    static func unmark(_ undo: [ViewedLineUndo], window: ProjectWindowState, stores: ChangesPanelStores) {
        viewedLineActions(window: window, stores: stores).unmark(undo)
    }

    /// Every agent of the session's worktree, each with its turns recorded
    /// there. None until Git has named the worktree's top level, which is
    /// the root the hook records every turn's trees under.
    private static func agents(
        answer: RepositoryRoots.Answer?,
        running: [ConversationKey],
        stores: ChangesPanelStores
    ) -> [ChangesPanelModel.Agent] {
        guard let answer, case let .repository(root) = answer else { return [] }
        return ChangesPanelModel.agents(
            history: stores.turnHistory.conversations,
            running: running,
            root: root,
            isRoot: { stores.repositoryRoots.isRoot($0, of: answer) }
        )
    }

    private static func running(in container: ContainerID, stores: ChangesPanelStores) -> [ConversationKey] {
        panes(in: container, stores: stores).compactMap { stores.attention.headerRuntime(inPane: $0)?.conversation }
    }

    /// The tab that runs each conversation, read from every pane of the app
    /// with `container`'s first (`ChangesPanelModel.liveTabs`).
    private static func liveTab(in container: ContainerID, stores: ChangesPanelStores) -> (ConversationKey) -> ConversationChoice.LiveTab? {
        let session = stores.session
        let panes = session.tabs.flatMap { tab in
            let isInSession = tab.container == container
            let live = ConversationChoice.LiveTab(
                title: tab.displayTitle,
                isInSession: isInSession,
                checkoutPlace: isInSession ? nil : CheckoutName.place(of: tab.container, in: session)
            )
            return tab.splitTree.allLeafIDs().map { pane in
                ChangesPanelModel.LivePane(conversation: stores.attention.headerRuntime(inPane: pane)?.conversation, tab: live)
            }
        }
        let tabs = ChangesPanelModel.liveTabs(panes)
        return { tabs[$0] }
    }

    /// The session's panes, in its tabs' order.
    private static func panes(window: ProjectWindowState, stores: ChangesPanelStores) -> [UUID] {
        panes(in: window.selection.activeContainerID, stores: stores)
    }

    private static func panes(in container: ContainerID, stores: ChangesPanelStores) -> [UUID] {
        stores.session.tabs(in: container).flatMap { $0.splitTree.allLeafIDs() }
    }

    /// The pane `conversation`'s agent runs in, if it still runs here.
    static func pane(of conversation: ConversationKey, window: ProjectWindowState, stores: ChangesPanelStores) -> UUID? {
        panes(window: window, stores: stores).first { stores.attention.headerRuntime(inPane: $0)?.conversation == conversation }
    }

    private static func viewedLineActions(window: ProjectWindowState, stores: ChangesPanelStores) -> ViewedLineActions {
        ViewedLineActions(
            queue: stores.attentionQueue.queue,
            attention: stores.attention,
            history: stores.turnHistory.conversations,
            lines: stores.viewedLines,
            toasts: stores.toasts,
            window: window
        )
    }
}
