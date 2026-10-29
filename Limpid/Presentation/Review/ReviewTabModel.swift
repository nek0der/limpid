// ReviewTabModel.swift
// Limpid — what a window's review tab reads, where it goes back to, and what its bar offers.

import Foundation

/// How the review tab was asked for. Every entry opens the same tab;
/// each names the comparison it is about.
enum ReviewTabRequest: Equatable, Sendable {
    /// "Review Unviewed" on the decision bar, ⌘J's open, and ⌥⌘R: the
    /// conversation's unviewed turns.
    case unviewedTurns
    /// "Review Unviewed" on the changes panel: the worktree's unviewed
    /// turns, every conversation's, as one comparison from the oldest
    /// unviewed turn's begin to the newest one's end. The tab's
    /// conversation is the one the panel chose to open it from
    /// (`ChangesPanelModel.reviewConversation`).
    case worktreeUnviewedTurns
    /// One turn: its row in the changes panel, or "Show Partial Changes".
    case turn(TurnID)
    /// "Review Latest Turn" (⌥⌘J).
    case latestTurn
    /// "Show Current Diff".
    case uncommitted
    /// A stop's ⋯ "Show Partial Changes": the turn it stopped in when
    /// that turn can be read as one, else what is uncommitted now. A turn
    /// cut short often has no end snapshot, and a toast that it cannot be
    /// read would leave the person nothing to look at.
    case partialChanges(TurnID?)
}

/// Why a request opened nothing. The open tab, if any, stays as it was.
enum ReviewTabUnavailable: Error, Equatable, Sendable {
    /// The turn changed no files.
    case answerOnly
    /// The turn's changes could not be taken for a reason other than a lost
    /// snapshot: not a Git work tree, snapshots turned off, or a failure.
    case changesUnavailable
    /// The turn is still running; nothing it does has been seen.
    case running
    /// No such turn, or no turn that changed files.
    case noTurn
}

/// A turn as the tab fixes it: its identity and its number.
struct ReviewTabTurn: Equatable, Sendable {
    let id: TurnID
    let number: Int
}

/// What had ended when the tab's comparison was fixed. A turn that
/// ends after it is offered, never added, and "Mark as Viewed" never reaches
/// past what was there to read.
struct ReviewTabFixedPoint: Equatable, Sendable {
    /// The highest number of a turn that had ended.
    var knownThrough: Int?
    /// The latest turn that had ended: how far "Mark as Viewed" moves the
    /// line for the uncommitted changes.
    var latestEnded: ReviewTabTurn?
    /// Whether turns that end later are offered. Only for a range that
    /// reached the last turn there was to read: a past turn picked on
    /// purpose is not extended over the turns after it.
    var offersFollowingTurns = false
}

/// An insert from the review tab that delivered every comment, with what
/// the tab was when it started (`ReviewTabModel.closesAfterInsert`).
struct ReviewTabInserted: Equatable, Sendable {
    let paneID: UUID
    /// The agent in that pane, `nil` for a shell, whose pane has no
    /// decision bar to say where the comments went.
    let agent: AgentKind?
    let opening: UUID
    let selection: ReviewScopeOption
}

/// What closing the review tab after an insert did, which decides whether
/// a toast says the comments arrived.
enum ReviewTabInsertClose: Equatable, Sendable {
    /// The tab stays: the person moved on, or a comment is being written.
    case stayed
    /// Closed to a shell, where the pasted text is in view.
    case toShell
    /// Closed to an agent's pane, whose bar says where the comments went.
    case toldOnBar
    /// Closed to an agent's pane whose bar shows a request, a prompt, or a
    /// stop instead.
    case barBusy

    var needsToast: Bool {
        self == .stayed || self == .barBusy
    }
}

/// What one window's review tab is reading. A window has one at most;
/// another entry replaces what it reads rather than opening a second.
/// Changed through `ReviewTabModel`, which keeps the selection and its fixed point
/// together.
struct ReviewTabState: Equatable, Sendable {
    /// The worktree read, as Git names its top level.
    let root: String
    /// What the tab reads, as the dropdown names it.
    var selection: ReviewScopeOption
    var fixedPoint: ReviewTabFixedPoint
    /// The agent pane the review was opened from, shown again when it
    /// closes. `nil` when it was opened without one ("Show Current Diff"
    /// with every agent pane closed).
    var agentPaneID: UUID?
    /// Where comments are inserted: the agent pane, until the person picks
    /// another in the destination menu.
    var destinationPaneID: UUID?
    /// Whether the strip shows the review tab rather than a terminal tab
    /// beside it (⇧⌘[ ⇧⌘]).
    var isShown = true
    /// The conversation whose turns the tab reads: the one the entry named
    /// (the decision bar's, ⌘J's), or the agent's in its pane. Kept so the
    /// dropdown and "Mark as Viewed" read the same turns the tab opened on.
    var conversation: ConversationKey?
    /// This opening of the tab. An insert started before the tab closed
    /// must not land in the one opened after it, so it compares this.
    let opening: UUID
    /// Whether the tab was opened from a pane in no project, a scratch
    /// tab's (`isOfNoProject(agentPaneID:in:)`): the owner it was opened
    /// with, which counts only once that pane is gone. Decided as the tab is
    /// opened from a pane (`ReviewTabModel.open`). While the pane is there,
    /// whether a review stays with its window as the window switches, and
    /// where it waits once its window lets it go, follow the row the pane
    /// is on now, as its strip does (`belongs`, `isOfNoProjectNow(in:)`).
    /// Its discard marks and their Undo are not the owner's: they are the
    /// worktree's, in the one store every window shares
    /// (`WindowRegistry.reviewDiscards`), and stay there whoever owns the
    /// tab.
    var isOfNoProject = false

    /// The comparison read, `nil` when there is none: no unviewed turns, or
    /// a record that lost a snapshot.
    var scope: ReviewScope? {
        selection.scope
    }

    /// Whether a review opened from `agentPaneID` belongs to no project: its
    /// pane is in a scratch tab. Without a pane, it is the project's it is
    /// opened in.
    @MainActor
    static func isOfNoProject(agentPaneID: UUID?, in session: WorkspaceSession) -> Bool {
        agentPaneID.flatMap { session.tab(containing: $0) }.map { $0.container.projectID == nil } ?? false
    }

    /// Whether the tab is of no project as it stands: by the row its
    /// agent's pane is on now, the rule its strip shows it by (`belongs`).
    /// A scratch tab moved to a project's row takes its review to that
    /// project, which a window switching away can no longer show; a
    /// project's tab moved to the scratch row leaves its review with no
    /// project, which every window can. The owner the tab was opened with
    /// (`isOfNoProject`) decides only once the pane is gone.
    @MainActor
    func isOfNoProjectNow(in session: WorkspaceSession) -> Bool {
        guard let row = agentPaneID.flatMap({ session.tab(containing: $0)?.container }) else { return isOfNoProject }
        return row.projectID == nil
    }

    /// Whether the tab is `container`'s, so the strip of a window on that
    /// container shows it: opened from one of its panes. One whose agent's
    /// pane is gone stays wherever it is shown.
    @MainActor
    func belongs(to container: ContainerID, in session: WorkspaceSession) -> Bool {
        guard let agent = agentPaneID, let agentContainer = session.tab(containing: agent)?.container else { return true }
        return agentContainer == container
    }
}

/// An open the window waits for, and where the person was when they asked
/// for it. A newer request replaces it, and moving to another session or
/// tab before it lands leaves it unapplied.
struct ReviewOpenRequest: Equatable, Sendable {
    let id = UUID()
    let containerID: ContainerID
    let tabID: UUID?

    /// Whether the person is still where they asked from.
    func isStill(at containerID: ContainerID, tabID: UUID?) -> Bool {
        self.containerID == containerID && self.tabID == tabID
    }
}

/// What ⌥⌘R does.
enum ReviewTabShortcut: Equatable, Sendable {
    /// The tab is on screen: close it.
    case close
    /// Show the tab on the unviewed turns, opening it if there is none.
    case show(ReviewTabState)
}

/// The rules of the review tab, as plain values so they are tested without
/// a window.
enum ReviewTabModel {
    /// What the rules need to know about the agent's turns.
    struct Context {
        /// The turns of the conversation the review follows, recorded in
        /// this worktree (`turns(_:root:conversation:)`), oldest first.
        var turns: [TurnSummary]
        /// That conversation, `nil` for a pane with no agent.
        var conversation: ConversationKey?
        /// Every conversation's turns recorded in this worktree, as one
        /// timeline (`WorktreeTimeline.listed`): what the worktree's
        /// unviewed turns read, what a range across conversations marks
        /// viewed, and what the file tags read through.
        var worktreeTurns: [TurnSummary] = []
        /// Every conversation of the worktree, named as the changes panel
        /// names it (`ChangesPanelModel.conversations`): the scope menu's
        /// headings, and the names the destination menu gives panes. One
        /// for a worktree of one conversation, none before one ran.
        var conversations: [ConversationChoice] = []
        /// Each of those conversations' turns in this worktree, oldest
        /// first (`turns(_:root:conversation:)`): what its section of the
        /// scope menu lists.
        var conversationTurns: [ConversationKey: [TurnSummary]] = [:]
        /// Whether a turn is above the viewed line.
        var isViewed: (TurnSummary) -> Bool
        /// Whether a restore took the turn back (`RestoredTurns.ids`): not
        /// a choice, nor among the unviewed turns.
        var isRestored: (TurnSummary) -> Bool = { _ in false }
        /// The branch to compare against, `nil` without one.
        var branchBase: String?
        /// Whether some uncommitted change was made outside every turn,
        /// which the dropdown says.
        var hasChangesOutsideTurns = false
        /// Whether one of those has not been marked viewed, which keeps
        /// "Mark as Viewed" on the uncommitted changes.
        var hasUnviewedChangesOutsideTurns = false
        /// Whether the pane the review is opened from is in no project, a
        /// scratch tab's (`ReviewTabState.isOfNoProject(agentPaneID:in:)`):
        /// who owns the tab it opens (`opened`).
        var isAgentPaneOfNoProject = false

        init(
            turns: [TurnSummary],
            conversation: ConversationKey? = nil,
            isViewed: @escaping (TurnSummary) -> Bool,
            branchBase: String?,
            hasChangesOutsideTurns: Bool = false,
            hasUnviewedChangesOutsideTurns: Bool = false
        ) {
            self.turns = turns
            self.conversation = conversation
            self.isViewed = isViewed
            self.branchBase = branchBase
            self.hasChangesOutsideTurns = hasChangesOutsideTurns
            self.hasUnviewedChangesOutsideTurns = hasUnviewedChangesOutsideTurns
        }
    }

    /// What "Mark as Viewed" in the tab's bar would do.
    enum MarkViewed: Equatable, Sendable {
        /// Move the viewed line to the end of the fixed range, not to a
        /// turn that ended since.
        case throughTurn(ReviewTabTurn)
        /// A range across conversations: each conversation's line moves to
        /// its last turn in the range, as one mark with one Undo. The
        /// range's last turn's conversation first.
        case throughTurns([ReviewTabTurn])
        /// The uncommitted changes: the turns that had ended when the tab
        /// was fixed, and what changed outside them too.
        case includingChangesOutsideTurns(through: ReviewTabTurn?)
    }

    /// The changes outside turns as the review last read its list: each
    /// listed path's contents then. What "Mark as Viewed" records, so what
    /// is recorded viewed is what was there to view, not what an editor
    /// wrote since; a count the changes panel runs later does not move it.
    struct OutsideTurnsRead: Equatable, Sendable {
        /// The opening and the list it was read with
        /// (`ReviewSession.listReadCount`); another's says nothing of what
        /// the review shows now, such as the list of the range chosen before.
        let opening: UUID
        let listReads: Int
        let contents: [String: String]

        /// Only the paths the review listed: one that appeared since was
        /// never there to view.
        init(opening: UUID, listReads: Int, counted: [String: String], listed: Set<String>) {
            self.opening = opening
            self.listReads = listReads
            contents = counted.filter { listed.contains($0.key) }
        }
    }

    /// Whether some change outside turns the review read, with the list it
    /// shows now (`listReads`), is not viewed as it read it.
    static func hasUnviewedChangesOutsideTurns(
        _ read: OutsideTurnsRead?,
        tab: ReviewTabState,
        listReads: Int,
        viewed: [String: String]?
    ) -> Bool {
        guard let read, read.opening == tab.opening, read.listReads == listReads else { return false }
        return !WorktreeChanges.unviewed(read.contents, viewed: viewed).isEmpty
    }

    /// What "Mark as Viewed" records of the changes outside turns: their
    /// contents as the review read them, or `nil` where the action does not
    /// take them in or all were viewed as they are.
    static func outsideTurnsToRecord(
        _ action: MarkViewed,
        read: OutsideTurnsRead?,
        tab: ReviewTabState,
        listReads: Int,
        viewed: [String: String]?
    ) -> [String: String]? {
        guard case .includingChangesOutsideTurns = action, let read,
              hasUnviewedChangesOutsideTurns(read, tab: tab, listReads: listReads, viewed: viewed)
        else { return nil }
        return read.contents
    }

    /// The left part of the tab's bar.
    enum BandStatus: Equatable, Sendable {
        case unviewedFiles(Int)
        case allFilesViewed
        case noChanges
        case incompleteRecord
    }

    /// `turns` cut to one conversation and one worktree. A conversation
    /// resumed in another worktree keeps its turns, but those compare that
    /// worktree's trees: offered here, the range would be refused when read,
    /// or counted as an incomplete record. A turn with no tree recorded
    /// stays, since nothing says it was elsewhere. `isRoot` says whether a
    /// tree's recorded root is `root`; by name unless the caller can resolve
    /// links, as `ReviewGit` does before it reads a range.
    static func turns(
        _ turns: [TurnSummary],
        root: String,
        conversation: ConversationKey,
        isRoot: ((String) -> Bool)? = nil
    ) -> [TurnSummary] {
        let isRoot = isRoot ?? { $0 == root }
        return turns.filter { turn in
            turn.conversation == conversation
                && [turn.beginTree, turn.endTree].allSatisfy { tree in tree.map { isRoot($0.root) } ?? true }
        }
        .sorted { $0.displayNumber < $1.displayNumber }
    }

    /// What `request` reads, or why it reads nothing. The unviewed turns
    /// always answer, "none" included, so the tab can say so rather than
    /// stay shut; a turn whose record lost a snapshot answers too, and the
    /// tab says the record is incomplete.
    static func selection(for request: ReviewTabRequest, _ context: Context) -> Result<ReviewScopeOption, ReviewTabUnavailable> {
        switch request {
        case .unviewedTurns:
            return .success(.unviewedTurns(ReviewScopeCatalog.unviewedTurns(
                turns: context.turns,
                isViewed: context.isViewed,
                isRestored: context.isRestored
            )))
        case .worktreeUnviewedTurns:
            return .success(.worktreeUnviewedTurns(ReviewScopeCatalog.unviewedTurns(
                turns: context.worktreeTurns,
                isViewed: context.isViewed,
                isRestored: context.isRestored
            )))
        case let .turn(id):
            guard let turn = context.turns.first(where: { $0.turnID == id }) else { return .failure(.noTurn) }
            return selection(of: turn)
        case .latestTurn:
            // The newest turn that did something: an answer after it does
            // not hide it, and one whose changes could not be taken says why
            // rather than open the one before.
            guard let turn = context.turns.last(where: { $0.phase != .started && $0.hasPrompt && $0.changes != .unchanged })
            else { return .failure(.noTurn) }
            return selection(of: turn)
        case .uncommitted:
            return .success(.uncommitted(includesChangesOutsideTurns: context.hasChangesOutsideTurns))
        case let .partialChanges(id):
            if let id, case let .success(option) = selection(for: .turn(id), context), case .turn = option {
                return .success(option)
            }
            return selection(for: .uncommitted, context)
        }
    }

    /// The tab after `request`: the open tab reading something else, or a
    /// new one, shown either way. A tab opened from another agent's pane
    /// follows that agent, destination included; one opened again from the
    /// same agent keeps the destination the person picked.
    static func open(
        _ request: ReviewTabRequest,
        _ context: Context,
        root: String,
        agentPaneID: UUID?,
        current: ReviewTabState?,
        opening: UUID = UUID()
    ) -> Result<ReviewTabState, ReviewTabUnavailable> {
        selection(for: request, context).map { selection in
            opened(selection, context, root: root, agentPaneID: agentPaneID, current: current, opening: opening)
        }
    }

    /// ⌥⌘R: closes the tab on screen, and otherwise shows it on the unviewed
    /// turns.
    static func shortcut(
        _ context: Context,
        root: String,
        agentPaneID: UUID?,
        current: ReviewTabState?,
        opening: UUID = UUID()
    ) -> ReviewTabShortcut {
        if current?.isShown == true {
            return .close
        }
        let selection = ReviewScopeOption.unviewedTurns(ReviewScopeCatalog.unviewedTurns(
            turns: context.turns,
            isViewed: context.isViewed,
            isRestored: context.isRestored
        ))
        return .show(opened(selection, context, root: root, agentPaneID: agentPaneID, current: current, opening: opening))
    }

    /// The tab reading `selection`, chosen in the dropdown: the same tab,
    /// fixed again as of now.
    static func select(_ selection: ReviewScopeOption, in tab: ReviewTabState, _ context: Context) -> ReviewTabState {
        var next = tab
        next.selection = selection
        next.fixedPoint = fixedPoint(selection, context)
        return next
    }

    /// The same, for a choice under another conversation's heading in the
    /// menu: the tab reads that conversation's turns from now on, and
    /// its comments go to that conversation's pane, `agentPaneID`, or to
    /// none while it has no pane, as switching from the decision bar does,
    /// so they never go into the previous agent's input. The pane the tab
    /// returns to on closing stays the one it came from when the
    /// conversation has none. `context` is that conversation's.
    static func select(
        _ selection: ReviewScopeOption,
        conversation: ConversationKey,
        agentPaneID: UUID?,
        in tab: ReviewTabState,
        _ context: Context
    ) -> ReviewTabState {
        var next = select(selection, in: tab, context)
        guard tab.conversation != conversation else { return next }
        next.conversation = conversation
        next.destinationPaneID = agentPaneID
        if let agentPaneID {
            next.agentPaneID = agentPaneID
        }
        return next
    }

    /// What "Add to Scope" makes: the tab, reading the range carried on,
    /// and the turns it was carried on to. The review carries its comments
    /// and marks into that range (`ReviewSession.carryRange`) and reads it as
    /// any change of scope.
    struct Extension {
        let tab: ReviewTabState
        let turns: [TurnSummary]
    }

    /// "Add to Scope": the fixed range carried on to every turn that ended
    /// after it, those offered and the answers before them, fixed again as
    /// of now. `nil` when nothing is offered.
    static func addFollowingTurns(_ tab: ReviewTabState, _ context: Context) -> Extension? {
        guard !followingTurns(tab, context).isEmpty, case let .turns(range) = tab.scope else { return nil }
        let turns = ReviewScopeCatalog.followingTurns(after: range, in: context.turns)
        guard let extended = range.extended(with: turns) else { return nil }
        let selection: ReviewScopeOption = switch tab.selection {
        case .unviewedTurns: .unviewedTurns(.range(extended))
        case .worktreeUnviewedTurns: .worktreeUnviewedTurns(.range(extended))
        case let .turn(_, prompt): .turn(extended, prompt: prompt)
        default: tab.selection
        }
        return Extension(tab: select(selection, in: tab, context), turns: turns)
    }

    /// The turns that ended after the fixed range since it was fixed, which
    /// the top of the tab offers to add.
    static func followingTurns(_ tab: ReviewTabState, _ context: Context) -> [TurnSummary] {
        guard tab.fixedPoint.offersFollowingTurns, case let .turns(range) = tab.scope else { return [] }
        let known = tab.fixedPoint.knownThrough ?? 0
        return ReviewScopeCatalog.followingTurns(after: range, in: context.turns).filter { $0.displayNumber > known }
    }

    /// The dropdown's choices in its order, every section's
    /// (`ReviewScopeMenu`), with the tab's own fixed selection in place of
    /// the one of its kind computed now.
    static func menu(_ tab: ReviewTabState, _ context: Context) -> [ReviewScopeOption] {
        ReviewScopeMenu.make(tab, context).choices.map(\.option)
    }

    /// Whether a tab with a comment being written refuses to read `next`
    /// instead: the review keeps a comment until it is saved or thrown
    /// away, and the tab must not name a comparison it is not showing. Any
    /// change of comparison counts, another worktree's included.
    static func refusesReplacing(_ current: ReviewTabState?, with next: ReviewTabState, hasUnsavedComment: Bool) -> Bool {
        guard hasUnsavedComment, let current else { return false }
        return current.root != next.root || current.scope != next.scope
    }

    /// The pane to show when the tab closes, or after "Mark as Viewed"
    /// closes it: the agent's, while it still exists. After an insert, the
    /// pane the comments went to, where Return sends them.
    static func paneAfterClosing(_ tab: ReviewTabState, livePanes: Set<UUID>, inserted: UUID? = nil) -> UUID? {
        [inserted, tab.agentPaneID].compactMap(\.self).first { livePanes.contains($0) }
    }

    /// Whether ⌘W and ⌥⌘W have something to close in the window: a
    /// terminal tab, or the review tab in front, which they close first
    /// (`ReviewTabActions.closeIfInFront`). A review stays open with every
    /// terminal tab closed, so the tab alone cannot say.
    static func closeCommandsAreLive(hasActiveTab: Bool, review: ReviewTabState?) -> Bool {
        hasActiveTab || review?.isShown == true
    }

    /// Whether the tab closes after an insert that delivered every comment:
    /// only the tab the insert started in, reading the same comparison, in
    /// front. One the person put behind a terminal, opened again, or read
    /// another range in while Git ran is theirs, and a comment being written
    /// would be thrown away.
    static func closesAfterInsert(_ tab: ReviewTabState?, _ inserted: ReviewTabInserted, hasUnsavedComment: Bool) -> Bool {
        guard let tab, tab.isShown, !hasUnsavedComment else { return false }
        return tab.opening == inserted.opening && tab.selection == inserted.selection
    }

    /// A pane the destination menu offers, named as the menu shows it.
    struct DestinationChoice: Equatable, Sendable {
        let destination: ReviewDestination
        /// The pane's name where no conversation names it.
        let label: String
        /// Its place among the other panes of that name (two shells in one
        /// worktree), from 1; `nil` for a name only it has.
        var place: Int?
        /// The conversation the pane runs, where the changes panel names it
        /// by its title or number ("Claude #2"): the pane is named as the
        /// scope menu's heading names the conversation, so the two read as
        /// one. Optional, as a shell or an untitled lone agent of its kind
        /// has its pane's name.
        var agent: ConversationChoice?
        /// What tells the pane apart from another pane running the same
        /// conversation; `nil` when it is the conversation's one pane.
        var agentDistinction: AgentDistinction?
    }

    /// How one of two panes running a conversation is told apart. Never by
    /// a bare number after the conversation's own ("Claude #1 2"), which
    /// reads as a count beside it, as "Claude 2 [2]" did.
    enum AgentDistinction: Equatable, Sendable {
        /// By its tab's title: "Claude #1 · “first”".
        case tab(String)
        /// By its place among the panes whose tabs have the same title,
        /// from 1, set off from the name: "Claude #1 (2)".
        case place(Int)
    }

    /// The destination menu's entries, in the session's order. A pane
    /// running a conversation the changes panel names apart from its kind
    /// is named after it (`agent`), and told apart from another pane of the
    /// same conversation by its tab's title (`tabTitle`), or by its place
    /// where the titles are the same too. Two other panes with the same
    /// name (two shells in one worktree) get the place they sit at among
    /// those, since a list of identical names is not a choice.
    static func destinationChoices(
        _ destinations: [ReviewDestination],
        agent: (UUID) -> ConversationChoice? = { _ in nil },
        tabTitle: (UUID) -> String = { _ in "" }
    ) -> [DestinationChoice] {
        let agents = destinations.map { destination in
            agent(destination.paneID).flatMap { $0.hasOwnName ? $0 : nil }
        }
        struct Pane: Hashable {
            let conversation: ConversationKey
            let tabTitle: String
        }
        var paneCounts: [ConversationKey: Int] = [:]
        var tabCounts: [Pane: Int] = [:]
        var titleCounts: [String: Int] = [:]
        for (destination, agent) in zip(destinations, agents) {
            if let agent {
                paneCounts[agent.conversation, default: 0] += 1
                tabCounts[Pane(conversation: agent.conversation, tabTitle: tabTitle(destination.paneID)), default: 0] += 1
            } else {
                titleCounts[destination.title, default: 0] += 1
            }
        }
        var tabsSeen: [Pane: Int] = [:]
        var titlesSeen: [String: Int] = [:]
        return zip(destinations, agents).map { destination, agent in
            guard let agent else {
                guard titleCounts[destination.title, default: 0] > 1 else {
                    return DestinationChoice(destination: destination, label: destination.title)
                }
                titlesSeen[destination.title, default: 0] += 1
                return DestinationChoice(
                    destination: destination,
                    label: destination.title,
                    place: titlesSeen[destination.title, default: 0]
                )
            }
            let pane = Pane(conversation: agent.conversation, tabTitle: tabTitle(destination.paneID))
            tabsSeen[pane, default: 0] += 1
            let distinction: AgentDistinction? = if paneCounts[agent.conversation, default: 0] < 2 {
                nil
            } else if tabCounts[pane, default: 0] < 2, !pane.tabTitle.isEmpty {
                .tab(pane.tabTitle)
            } else {
                .place(tabsSeen[pane, default: 0])
            }
            return DestinationChoice(destination: destination, label: destination.title, agent: agent, agentDistinction: distinction)
        }
    }

    /// What the band says of where comments go. Insert is
    /// disabled only when there is no pane to write to; what the agent is
    /// doing does not matter, and a pane whose terminal is still being
    /// looked at is not reported missing.
    enum DestinationStatus: Equatable, Sendable {
        case ready(ReviewDestination)
        case resolving
        /// The pane is there, with no terminal to write to; whether the
        /// menu has other panes to offer instead.
        case noTerminal(hasOtherPanes: Bool)
        /// The scope's conversation has no pane any more (it ended, or its
        /// pane was closed), so the tab writes nowhere until the person
        /// picks one of the panes still open. Named after the conversation
        /// as the scope menu names it: "no pane" read as false
        /// beside a live agent in the next tab.
        case conversationPaneClosed(ConversationChoice)
        /// The pane the person picked was closed, and others are open.
        case paneClosed
        /// The tab was opened with no pane and no conversation to follow
        /// ("Show Current Diff" with every agent pane closed): nothing
        /// closed, there is only nothing chosen yet, and others are open.
        case unchosen
        /// No pane of the workspace has a terminal to write to.
        case noPane

        var isReady: Bool {
            if case .ready = self {
                true
            } else {
                false
            }
        }

        /// Whether the band offers "Choose Destination…" in place of a
        /// destination: the tab writes nowhere, and there are panes to pick.
        var offersChoice: Bool {
            switch self {
            case .conversationPaneClosed, .paneClosed, .unchosen: true
            case .ready, .resolving, .noTerminal, .noPane: false
            }
        }

        /// Whether the band says, before "Choose Destination…", why the
        /// tab writes nowhere: not where nothing was chosen, which the
        /// button says by itself.
        var hasClosedReason: Bool {
            offersChoice && self != .unchosen
        }
    }

    /// Where `tab`'s comments go, or why they go nowhere. A tab with no
    /// pane open to write to says whose pane closed when it was the scope's
    /// conversation's: the destination cleared on switching to a
    /// conversation with no pane (`opened`), or the agent's own pane, since
    /// closed. Named from `agents`, the worktree's conversations ("Claude #1"),
    /// or by its kind alone when they do not list it. A pane the person
    /// picked and then closed is no conversation's. A tab that never had a
    /// pane or a conversation has had nothing close. "No pane" is said only
    /// where `choices`, the panes the menu offers, has none.
    static func destinationStatus(_ tab: ReviewTabState, _ input: DestinationInput) -> DestinationStatus {
        guard input.isPaneOpen else {
            guard !input.choices.isEmpty else { return .noPane }
            guard let conversation = tab.conversation else {
                return tab.destinationPaneID == nil ? .unchosen : .paneClosed
            }
            let isConversationsPane = tab.destinationPaneID == nil || tab.destinationPaneID == tab.agentPaneID
            guard isConversationsPane else { return .paneClosed }
            let named = input.agents.first { $0.conversation == conversation }
                ?? ConversationChoice(conversation: conversation, ordinal: nil, unviewedCount: 0)
            return .conversationPaneClosed(named)
        }
        if let destination = input.destination {
            return .ready(destination)
        }
        guard !input.isResolving else { return .resolving }
        // A pane between probes may still be listed; it is no other pane.
        return .noTerminal(hasOtherPanes: input.choices.contains { $0.destination.paneID != tab.destinationPaneID })
    }

    /// What `destinationStatus` reads besides the tab.
    struct DestinationInput {
        /// Whether the pane the tab writes to is still open.
        let isPaneOpen: Bool
        /// The review's last reading of that pane; `nil` while it has no
        /// terminal, or before the first probe answers.
        let destination: ReviewDestination?
        let isResolving: Bool
        /// The panes the destination menu offers.
        let choices: [DestinationChoice]
        /// The worktree's conversations, whose names the band uses.
        let agents: [ConversationChoice]
    }

    /// The band's look: the decision bar's receipt, in the unread
    /// blue, while the range holds something past the viewed line, which is
    /// what "Mark as Viewed" would move; the bar at rest for a range already
    /// viewed and for the main diff, which no line describes. Checking the
    /// files does not change it: a checkbox is a reading mark, and the
    /// viewed line is the one "viewed". Decided from the tab and the
    /// records alone, so it is the same while the range loads.
    static func bandTone(_ tab: ReviewTabState, _ context: Context) -> DecisionBarModel.Tone {
        markViewed(tab, context) == nil ? .muted : .unread
    }

    /// What "Mark as Viewed" does here, or `nil` where it is not offered: a
    /// range already viewed, nothing to read, and the branch, which no line
    /// describes. Only turns that had ended when the tab was fixed
    /// count.
    static func markViewed(_ tab: ReviewTabState, _ context: Context) -> MarkViewed? {
        switch tab.selection {
        case let .unviewedTurns(.range(range)), let .worktreeUnviewedTurns(.range(range)), let .turn(range, _):
            let inRange = Set(range.turnIDs)
            // The tab's conversation's turns, and across conversations the
            // worktree's: a range may hold either.
            let turns = (context.turns + context.worktreeTurns).filter { inRange.contains($0.turnID) }
            guard turns.contains(where: { !context.isViewed($0) }) else { return nil }
            // By number, not by the end turn: the line passes the turns
            // numbered up to where it stands, and in a timeline's order the
            // turn that ended last need not be the one numbered last.
            let lasts = lastTurns(of: turns, in: range)
            // The worktree's range goes through the worktree's history
            // whatever it holds: it may hold one conversation, and that one
            // need not be the tab's, whose turns alone `.throughTurn` reads.
            if case .worktreeUnviewedTurns = tab.selection {
                return .throughTurns(lasts)
            }
            guard range.isAcrossConversations else {
                return .throughTurn(lasts.first ?? ReviewTabTurn(id: range.endTurnID, number: range.lastNumber))
            }
            return .throughTurns(lasts)
        case .uncommitted:
            let latest = tab.fixedPoint.latestEnded
            let hasUnviewedTurns = context.turns.contains { turn in
                ReviewScopeCatalog.isReadable(turn) && !context.isViewed(turn) && turn.displayNumber <= (latest?.number ?? 0)
            }
            return hasUnviewedTurns || context.hasUnviewedChangesOutsideTurns ? .includingChangesOutsideTurns(through: latest) : nil
        case .unviewedTurns, .worktreeUnviewedTurns, .incompleteTurn, .branch:
            return nil
        }
    }

    /// Each conversation's last turn among `turns`, the range's: where its
    /// line moves. The range's end turn's conversation first, which the
    /// toast names the mark after; the rest in a stable order.
    private static func lastTurns(of turns: [TurnSummary], in range: ReviewTurnRange) -> [ReviewTabTurn] {
        var last: [ConversationKey: TurnSummary] = [:]
        for turn in turns where (last[turn.conversation]?.displayNumber ?? Int.min) < turn.displayNumber {
            last[turn.conversation] = turn
        }
        let ordered = last.values.sorted { lhs, rhs in
            if (lhs.conversation == range.conversation) != (rhs.conversation == range.conversation) {
                return lhs.conversation == range.conversation
            }
            return lhs.conversation.conversationID < rhs.conversation.conversationID
        }
        return ordered.map { ReviewTabTurn(id: $0.turnID, number: $0.displayNumber) }
    }

    /// The bar's status, from what the tab reads, the files listed and
    /// those marked read.
    static func bandStatus(_ selection: ReviewScopeOption, fileIDs: [String], viewed: Set<String>) -> BandStatus {
        switch selection {
        case .unviewedTurns(.incomplete), .worktreeUnviewedTurns(.incomplete), .incompleteTurn:
            return .incompleteRecord
        default:
            guard !fileIDs.isEmpty else { return .noChanges }
            let unviewed = fileIDs.count { !viewed.contains($0) }
            return unviewed == 0 ? .allFilesViewed : .unviewedFiles(unviewed)
        }
    }

    /// Whether two choices read the same comparison. "(Including Outside
    /// Turns)" describes the uncommitted changes as they are now; it fixes
    /// nothing, so it does not make them another choice.
    static func isSameChoice(_ lhs: ReviewScopeOption, _ rhs: ReviewScopeOption) -> Bool {
        switch (lhs, rhs) {
        case (.uncommitted, .uncommitted): true
        default: lhs == rhs
        }
    }

    /// `selection` as the dropdown and the tab name it now: the uncommitted
    /// changes say whether some were made outside turns as of the last
    /// count, not as of when they were chosen.
    static func shown(_ selection: ReviewScopeOption, _ context: Context) -> ReviewScopeOption {
        guard case .uncommitted = selection else { return selection }
        return .uncommitted(includesChangesOutsideTurns: context.hasChangesOutsideTurns)
    }

    /// Whether the review has read the comparison the tab names: loaded, not
    /// loading, and the same scope. Until then the band and "Add to Scope"
    /// would act on a range the person is not looking at, so they
    /// wait; the tab and the review hold their scopes apart while one loads.
    static func isShowingItsScope(_ tab: ReviewTabState, loadedScope: ReviewScope?, hasLoaded: Bool, isLoading: Bool) -> Bool {
        guard let scope = tab.scope else { return false }
        return hasLoaded && !isLoading && loadedScope == scope
    }

    /// What had ended as of now, for `selection`.
    static func fixedPoint(_ selection: ReviewScopeOption, _ context: Context) -> ReviewTabFixedPoint {
        let ended = context.turns.filter { $0.phase != .started }
        var point = ReviewTabFixedPoint(
            knownThrough: ended.map(\.displayNumber).max(),
            latestEnded: ViewedLine.latestEnded(in: context.turns).map { ReviewTabTurn(id: $0.turnID, number: $0.displayNumber) }
        )
        // A range across conversations is not carried on: "Add to Scope"
        // adds one conversation's turns, and the worktree's unviewed turns
        // are opened again for the rest.
        if case let .turns(range) = selection.scope, !range.isAcrossConversations {
            point.offersFollowingTurns = !ended.contains { $0.displayNumber > range.lastNumber && ReviewScopeCatalog.isReadable($0) }
        }
        return point
    }

    /// The tab reading `selection`: the open one, shown again, or a new one.
    /// A tab opened from another agent's pane follows that agent,
    /// destination included; one opened again from the same agent, or from
    /// no pane at all, keeps the agent and the destination it had.
    private static func opened(
        _ selection: ReviewScopeOption,
        _ context: Context,
        root: String,
        agentPaneID: UUID?,
        current: ReviewTabState?,
        opening: UUID = UUID()
    ) -> ReviewTabState {
        guard var tab = current, tab.root == root else {
            return ReviewTabState(
                root: root,
                selection: selection,
                fixedPoint: fixedPoint(selection, context),
                agentPaneID: agentPaneID,
                destinationPaneID: agentPaneID,
                conversation: context.conversation,
                opening: opening,
                isOfNoProject: context.isAgentPaneOfNoProject
            )
        }
        tab = select(selection, in: tab, context)
        if let agentPaneID, tab.agentPaneID != agentPaneID {
            tab.agentPaneID = agentPaneID
            tab.destinationPaneID = agentPaneID
        }
        // The latest opening from a pane decides who owns the tab: the same
        // worktree opened again from a project's pane is that project's
        // review from now on, and goes with it. Its discards do not move:
        // they are the worktree's, in the one store every window shares
        // (`WindowRegistry.reviewDiscards`). Opened from no pane, it keeps
        // its owner.
        if agentPaneID != nil {
            tab.isOfNoProject = context.isAgentPaneOfNoProject
        }
        if let conversation = context.conversation {
            // Another agent: the insertion follows it, to its
            // pane, and to none for an agent with no pane in the session
            // (the scope menu reaches conversations that ended),
            // so comments on its turns never go into the previous agent's
            // input; the person can pick a pane in the band's menu. Set
            // whether or not the pane the tab returns to changed: back to
            // an agent from one with no pane, that pane is the same. The
            // pane the tab returns to on closing stays the one it came from
            // when the agent has none.
            if tab.conversation.map({ $0 != conversation }) ?? false {
                tab.destinationPaneID = agentPaneID
            }
            tab.conversation = conversation
        }
        tab.isShown = true
        return tab
    }

    /// One turn, opened from its row or by ⌥⌘J. Its record decides before
    /// its trees do: a turn whose changes could not be taken is not read as
    /// a diff even with both trees there (a snapshot that left out a large
    /// file reads as that file added or removed), and one that lost a
    /// snapshot opens to say the record is incomplete rather than pass for
    /// an answer. A record nobody prompted is no turn to review.
    private static func selection(of turn: TurnSummary) -> Result<ReviewScopeOption, ReviewTabUnavailable> {
        if turn.phase == .started {
            return .failure(.running)
        }
        guard turn.hasPrompt else { return .failure(.noTurn) }
        switch turn.changes {
        case .unchanged:
            return .failure(.answerOnly)
        case .unavailable where turn.changes.isLostSnapshot:
            return .success(.incompleteTurn(turn.displayNumber))
        case .unavailable:
            return .failure(.changesUnavailable)
        case .changed, .pending, .unknown:
            guard let range = ReviewTurnRange(turns: [turn]) else { return .success(.incompleteTurn(turn.displayNumber)) }
            return .success(.turn(range, prompt: turn.prompt))
        }
    }
}

/// When ⌘⏎ performs the review tab's "Mark as Viewed": as on the
/// decision bar, only once the button has been on screen for
/// `PrimaryActionGate.settleTime`, so a press meant for the screen before
/// does not mark a range that just replaced it, and once per showing of
/// the same button, so a held key does not mark twice.
struct ReviewBandGate: Sendable {
    /// What one showing of the button is: the opening of the tab, what it
    /// reads, and what the button does. Another range ending at the same
    /// turn, or the same range opened again, is a new showing.
    struct Shown: Equatable, Sendable {
        let opening: UUID
        let selection: ReviewScopeOption
        let action: ReviewTabModel.MarkViewed
    }

    private var shown: Shown?
    private var since: SuspendingClock.Instant?
    private var spent: Shown?

    /// Records the button as drawn now, `nil` when none is (behind a
    /// terminal tab, closed, or loading). The wait starts over only when
    /// the showing changes.
    mutating func noteShown(_ next: Shown?, at now: SuspendingClock.Instant) {
        if spent != next {
            spent = nil
        }
        guard let next else {
            shown = nil
            since = nil
            return
        }
        if shown != next {
            shown = next
            since = now
        }
    }

    /// The window came back in front: what it shows is new to the person
    /// again.
    mutating func restartSettling(at now: SuspendingClock.Instant) {
        if shown != nil {
            since = now
        }
    }

    /// The action a press performs, or `nil` when it is dropped.
    mutating func decide(at now: SuspendingClock.Instant) -> ReviewTabModel.MarkViewed? {
        guard let current = shown, let since, now - since >= PrimaryActionGate.settleTime, spent != current else { return nil }
        spent = current
        return current.action
    }
}
