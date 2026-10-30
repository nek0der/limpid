// ChangesPanelModel.swift
// Limpid — what the changes panel says of a worktree's turns: one timeline, each row's viewed state, and what each row offers.

import Foundation

/// The changes panel's table of contents: every conversation's turns
/// in the session's worktree as one timeline, oldest at the top as in the
/// terminal, each row with its conversation and whether its own line has
/// passed it, and what each row offers. A pure reading of the records; the
/// panel draws it and the window's actions act on it.
///
/// The timeline is built from `TurnHistory` alone, never from the records
/// on disk: what the projection leaves out (an internal agent's turns) stays
/// out, and the retention sweep and a restore keep working on the same
/// turns the panel shows.
enum ChangesPanelModel {
    /// One agent's conversation in the session's worktree.
    struct Agent: Equatable, Sendable {
        let conversation: ConversationKey
        /// Its turns recorded in this worktree, oldest first
        /// (`ReviewTabModel.turns`).
        let turns: [TurnSummary]
    }

    struct Input {
        /// Every agent of the session's worktree, in a stable order
        /// (`agents(history:running:root:isRoot:)`).
        var agents: [Agent]
        /// The conversations running in the session's panes.
        var running: [ConversationKey] = []
        /// The tab whose pane runs the conversation, and where that tab is
        /// (`liveTabs`); `nil` when no pane of the app runs it. What tells
        /// the filter's "Claude #2" apart as the one in the "claude" tab,
        /// and what names a conversation live (`ConversationTitleRule`).
        /// Left at none where only the counts are read (the rail's badge,
        /// the totals), as finding it reads every pane of the app.
        var liveTab: (ConversationKey) -> ConversationChoice.LiveTab? = { _ in nil }
        /// The conversation the panel's filter narrows the timeline to;
        /// `nil` for every conversation ("All"), the default.
        var chosen: ConversationKey?
        /// The focused pane's agent, if it runs one: where the panel opens.
        var focused: ConversationKey?
        /// How the window lists the turns (`WindowSelection.changesPanelGrouping`).
        var grouping = ChangesPanelGrouping.timeline
        /// Each conversation's viewed line, the one source of which turns
        /// are viewed and of the Undo the end line offers.
        var line: (ConversationKey) -> ViewedLine?
        /// Whether the window's selection names a worktree, or a project's
        /// own folder, whose row is still in the session: what the turns
        /// are of. One gone from disk goes on to what Git says. Whether
        /// a tab is open in it does not matter, as the turns are recorded
        /// under the worktree's folder, not under a tab.
        var hasWorktree = true
        /// What Git said of the session's folder.
        var repository: Repository = .found
        /// What changed between two recorded trees (`WorktreeChanges`):
        /// the totals' one comparison; `nil` while it is being counted, or
        /// cannot be, and nothing is said.
        var counts: (WorktreeChanges.Comparison) -> ChangeSummary? = { _ in nil }
        /// How many files changed outside every turn in the worktree;
        /// `nil` while they are being counted.
        var pathsOutsideTurns: Int?
        /// Whether that count left out what it could not order
        /// (`WorktreeChanges.incompleteOutsideTurns`), so it may be short.
        var isOutsideTurnsIncomplete = false
        /// Whether a restore that may still be undone took the turn's
        /// changes back (`RestoredTurns`).
        var isRestored: (TurnSummary) -> Bool = { _ in false }
        /// The name the person gave a tab the conversation ran in
        /// (`WorkspaceSession.conversationTabNames`), which names it once
        /// that tab is gone; `nil` for none, and where only the counts are
        /// read.
        var tabName: (ConversationKey) -> String? = { _ in nil }
        /// Why a restore to the start of the turn cannot run now
        /// (`RestoreGate`), `nil` while it can.
        var restoreBlocker: (TurnSummary) -> RestoreGate.Blocker? = { _ in nil }
        /// Each conversation's identity color (`ConversationIdentityStore`),
        /// handed out over `activeConversations`; empty where only the
        /// counts are read.
        var identities: [ConversationKey: Int] = [:]
    }

    /// What Git said of the session's folder (`RepositoryRoots`).
    enum Repository: Equatable, Sendable {
        case found
        case waiting
        case unavailable
        case notRepository
    }

    enum Content: Equatable, Sendable {
        /// No worktree is selected (a scratch tab, or a row that is gone):
        /// "No Worktree Selected", and no counts.
        case noWorktree
        /// "Not a Git Repository": its changes can't be tracked.
        case notGitRepository
        /// While Git is asked for the folder's top level: nothing yet,
        /// rather than "No Turns" for a moment.
        case waitingForRepository
        /// Git did not answer about the folder: "Couldn’t Get the Changes",
        /// and the panel asks again when it opens.
        case repositoryUnavailable
        case turns(TurnList)
    }

    struct TurnList: Equatable, Sendable {
        /// Whether the worktree has an agent at all; without one there are
        /// no counts to say.
        let hasAgents: Bool
        /// The conversation the rows are narrowed to, `nil` for all.
        let filter: ConversationKey?
        /// The filter's entries, one per conversation with a turn here, in
        /// the conversations' own order; empty with one conversation,
        /// which needs no filter and no badge on its rows.
        let conversations: [ConversationChoice]
        /// "14 turns · 10 unviewed": the worktree's, whatever the filter.
        let turnCount: Int
        let unviewedCount: Int
        /// What the worktree's unviewed range changed, as the one
        /// comparison "Review Unviewed" reads (`comparison`), and whether a
        /// shell command made some of it. Nothing while no turn is
        /// unviewed, or the range's record is incomplete.
        let added: Int
        let removed: Int
        let fileCount: Int?
        /// Whether the line counts what the unviewed range changed: not
        /// while nothing is unviewed or the comparison is unread, nor when
        /// it changed nothing, where "0 files +0 −0" would say nothing.
        let showsTurnCounts: Bool
        /// Whether turns are unviewed but their range's record is
        /// incomplete, so there is no comparison to count, which
        /// the line says in place of the counts.
        let isTotalsIncomplete: Bool
        let hasShellChanges: Bool
        let pathsOutsideTurns: Int?
        /// Whether the count outside turns may be short, which the line
        /// says beside it, or alone where it found nothing.
        let isOutsideTurnsIncomplete: Bool
        /// Whether the totals line says anything.
        let showsTotals: Bool
        /// Every row in the order drawn: the timeline's, or the sections'
        /// one after another.
        let rows: [Row]
        /// The viewed rows folded at the top of the list, `nil` when none
        /// are, and in sections, where each folds its own.
        let fold: Fold?
        /// The line below the latest turn, `nil` while a row is unviewed,
        /// and in sections, where each draws its own.
        let line: Line?
        /// Where the panel scrolls when it opens: among the rows as drawn,
        /// the focused pane's conversation's last unviewed turn, else the
        /// last unviewed, else the last.
        let scrollTarget: TurnID?
        /// A section per conversation, when the window groups the list by
        /// conversation; `nil` for the timeline. Also `nil` while the
        /// filter narrows the list to one conversation, or only one has
        /// turns here, where a section would only repeat the list.
        let sections: [Section]?
        /// Whether the list can be grouped by conversation, whichever way
        /// the window lists it: the panel offers "Timeline | By
        /// Conversation" only then (`groupable`).
        let canGroup: Bool

        /// How many digits the list's highest turn number has: every card's
        /// first column is that wide, so the prompts start at one x.
        var turnNumberDigits: Int {
            String(rows.map(\.turn.displayNumber).max() ?? 1).count
        }
    }

    /// One conversation's turns, when the list is grouped by
    /// conversation: a list of its own, with its own fold and line.
    struct Section: Equatable, Sendable, Identifiable {
        var id: ConversationKey {
            choice.conversation
        }

        let choice: ConversationChoice
        /// Its turns, oldest first.
        let rows: [Row]
        let fold: Fold?
        let line: Line?
    }

    struct Row: Equatable, Sendable, Identifiable {
        var id: TurnID {
            turn.turnID
        }

        let turn: TurnSummary
        let status: Status
        /// Whether the turn is at or above its conversation's line,
        /// whatever it changed.
        let isViewed: Bool
        /// Whether the row opens its turn in the review: not while it
        /// runs, when it changed nothing, or when its changes could not be
        /// taken. A record that lost a snapshot opens, to say so.
        let isSelectable: Bool
        /// The one move of the line the row's card offers.
        let action: RowAction?
        /// Whether the card offers "Restore Code to Before This Turn…": an
        /// ended turn that may have changed files, whose start was
        /// recorded, and not one a restore already took back.
        var offersRestore = false
        /// Why that entry is off now, `nil` while the restore can run.
        var restoreBlocker: RestoreGate.Blocker?
        /// Whether the reason is said in a line under the card
        /// (`ChangesPanelModel.placeBlockerNote`).
        var showsBlockerNote = false
        /// Whether the card shows its moves at rest, not only under the
        /// pointer: the list's last card with moves, the one most often
        /// acted on, and the one whose note says why a restore waits
        /// (`ChangesPanelModel.placeMovesAtRest`).
        var showsMovesAtRest = false
        /// The conversation the turn is of, for the row's bar and badge;
        /// `nil` in a worktree of one conversation, where the badge would
        /// only repeat the kind every row.
        var conversation: ConversationChoice?
        /// Whether the row's move of the line moves other conversations'
        /// lines too: "Mark as Viewed up to Here" while another
        /// conversation has a turn not viewed that ended by this one's end,
        /// "Mark as Unviewed from Here" while another has a viewed turn from
        /// this row on. Whatever the filter shows, so the label says it
        /// ("Mark All Conversations as Viewed up to Here"), not the tooltip
        /// alone.
        var movesOtherLines = false
        /// Whether the row's move of the line reaches its own
        /// conversation's line alone: in a section, which reads as that
        /// conversation's list, so a move there must not reach the lines of
        /// sections above or below it (`turnsMoved(by:at:in:movesOnlyItsOwnLine:)`).
        var movesOnlyItsOwnLine = false
    }

    enum Status: Equatable, Sendable {
        case viewed
        case unviewed
        case running
        /// Ended with no files changed ("No file changes").
        case answerOnly
        /// The changes could not be taken, which is no answer about them:
        /// never "No file changes".
        case changesUnavailable
        /// A snapshot is gone: "Incomplete record", and no diff is guessed.
        case incompleteRecord
        /// A restore took the turn's changes back, and may still be undone.
        case restored

        /// Whether the turn's own counts stand for it: an ended turn whose
        /// changes were taken. Any other state is said in words instead.
        var hasCounts: Bool {
            self == .viewed || self == .unviewed
        }
    }

    enum RowAction: Hashable, Sendable {
        /// "Mark as Viewed up to Here", under an unviewed turn.
        case markViewedThrough
        /// "Mark as Unviewed from Here", under a viewed one.
        case markUnviewedFrom
    }

    /// The viewed rows at the top of the list, folded into one line ("Show
    /// 12 earlier viewed turns"): a long timeline is mostly history.
    struct Fold: Equatable, Sendable {
        /// How many rows, from the first, the fold holds.
        let count: Int
    }

    /// The line below the latest turn, once every row is viewed: "Viewed
    /// up to here", with "Unmark as Viewed" while the last mark can still
    /// be taken back.
    struct Line: Equatable, Sendable {
        /// The moves of the last mark, one per conversation it moved, taken
        /// back together; empty when the mark can no longer be taken back.
        let undo: [ViewedLineUndo]
    }

    /// The turns the window's review tab reads while it is in front, so
    /// the list rings the turns the diff beside it is of, whichever
    /// conversations they are in. None while the tab is behind a terminal
    /// tab or reads no turns (the uncommitted changes, the branch).
    static func turnsShownInReview(_ review: ReviewTabState?) -> Set<TurnID> {
        guard let review, review.isShown, case let .turns(range)? = review.scope else { return [] }
        return Set(range.turnIDs)
    }

    static func make(_ input: Input) -> Content {
        guard input.hasWorktree else { return .noWorktree }
        switch input.repository {
        case .found: break
        case .waiting: return .waitingForRepository
        case .unavailable: return .repositoryUnavailable
        case .notRepository: return .notGitRepository
        }
        let counts = unviewedCounts(input)
        let agents = input.agents
        // A filter from another worktree, or of a conversation no longer
        // here, narrows nothing.
        let filter = agents.contains { $0.conversation == input.chosen } ? input.chosen : nil
        let conversations = agents.count > 1 ? choices(agents, among: agents, input: input, unviewed: counts) : []
        let timeline = timeline(agents.flatMap(\.turns))
        let shown = filter.map { filter in timeline.filter { $0.conversation == filter } } ?? timeline
        // What each row's move does to the other lines, read once for every
        // row, over the whole timeline whatever the filter shows: the move
        // reaches the conversations the filter hides too.
        let others = WorktreeTimeline.OtherLines(timeline) { turn in
            input.line(turn.conversation)?.isViewed(turn) ?? false
        }
        // Each row's conversation read by key rather than a scan of the
        // choices for every row; the first choice of a key wins, as a scan
        // would find it.
        let choiceByConversation = Dictionary(conversations.map { ($0.conversation, $0) }) { first, _ in first }
        var rows = shown.map { turn in
            var row = row(turn, line: input.line(turn.conversation), input: input)
            row.conversation = choiceByConversation[turn.conversation]
            row.movesOtherLines = switch row.action {
            case .markViewedThrough: others.marksOthers(turn)
            case .markUnviewedFrom: others.unmarksOthers(turn)
            case nil: false
            }
            return row
        }
        // Each section reads as a list of its own, so each places its own
        // moves at rest and its own note, as the timeline does once.
        let groupable = Self.groupable(timeline, conversations: conversations, filter: filter)
        let sections = input.grouping == .byConversation
            ? groupable.map { Self.placed(Self.sections(rows, conversations: $0, line: input.line)) }
            : nil
        if let sections {
            rows = sections.flatMap(\.rows)
        } else {
            placeBlockerNote(rows: &rows)
            placeMovesAtRest(rows: &rows)
        }
        var fileCount: Int?
        var added = 0
        var removed = 0
        let unviewed = unviewedTurns(of: timeline, input: input)
        let range: ReviewTurnRange? = if case let .range(range) = unviewed {
            range
        } else {
            nil
        }
        // Unviewed turns whose range has no fixed comparison: the line says
        // so, rather than nothing, which reads as nothing to count.
        let isTotalsIncomplete = if case .incomplete = unviewed {
            true
        } else {
            false
        }
        if case let .changed(files, lines, gone)? = range.map(comparison).flatMap(input.counts) {
            fileCount = files
            added = lines
            removed = gone
        }
        // Said only of what a turn of the range changed
        // (`TurnSummary.hasShellChanges`).
        let inRange = Set(range?.turnIDs ?? [])
        let hasShellChanges = timeline.contains { turn in
            if case .changed = turn.changes, inRange.contains(turn.turnID) {
                turn.hasShellChanges
            } else {
                false
            }
        }
        let showsTurnCounts = added != 0 || removed != 0 || (fileCount ?? 0) != 0
        // Said only once there is a count to qualify.
        let isOutsideTurnsIncomplete = input.pathsOutsideTurns != nil && input.isOutsideTurnsIncomplete
        return .turns(TurnList(
            hasAgents: !agents.isEmpty,
            filter: filter,
            conversations: conversations,
            turnCount: timeline.count,
            unviewedCount: counts.values.reduce(0, +),
            added: added,
            removed: removed,
            fileCount: fileCount,
            showsTurnCounts: showsTurnCounts,
            isTotalsIncomplete: isTotalsIncomplete,
            hasShellChanges: hasShellChanges,
            pathsOutsideTurns: input.pathsOutsideTurns,
            isOutsideTurnsIncomplete: isOutsideTurnsIncomplete,
            showsTotals: showsTurnCounts || isTotalsIncomplete || hasShellChanges || (input.pathsOutsideTurns ?? 0) > 0
                || isOutsideTurnsIncomplete,
            rows: rows,
            fold: sections == nil ? fold(rows) : nil,
            line: sections == nil ? line(rows, conversations: agents.map(\.conversation), line: input.line) : nil,
            scrollTarget: scrollTarget(rows, focused: input.focused),
            sections: sections,
            canGroup: groupable != nil
        ))
    }

    /// Every agent's unviewed turns together, counted as the rail's badge
    /// counts them.
    static func unviewedTotal(_ input: Input) -> Int {
        unviewedCounts(input).values.reduce(0, +)
    }

    /// Each agent's unviewed turns, counted once for everything a reading
    /// of the panel asks of them.
    static func unviewedCounts(_ input: Input) -> [ConversationKey: Int] {
        var counts: [ConversationKey: Int] = [:]
        for agent in input.agents where counts[agent.conversation] == nil {
            counts[agent.conversation] = unviewedCount(agent.turns, line: input.line(agent.conversation), isRestored: input.isRestored)
        }
        return counts
    }

    /// The turns that need reading and are not viewed: what the rail's
    /// badge adds up across a session's agents, and the filter shows per
    /// conversation. The same turns "Review Unviewed" opens
    /// (`ReviewScopeCatalog`). A turn a restore took back has nothing left
    /// to read, and is not counted.
    static func unviewedCount(
        _ turns: [TurnSummary],
        line: ViewedLine?,
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> Int {
        listed(turns).count { turn in
            ReviewScopeCatalog.isReadable(turn) && !(line?.isViewed(turn) ?? false)
                && !isRestored(turn)
        }
    }

    /// A record nobody prompted is no turn.
    static func listed(_ turns: [TurnSummary]) -> [TurnSummary] {
        turns.filter(\.hasPrompt)
    }

    // MARK: - The timeline

    /// Every conversation's turns as one timeline, in the worktree's one
    /// order (`WorktreeTimeline.listed`), which the review reads its
    /// ranges from too. A record nobody prompted is left out.
    static func timeline(_ turns: [TurnSummary]) -> [TurnSummary] {
        WorktreeTimeline.listed(turns)
    }

    /// The comparison the totals read (`comparison`), for asking Git to
    /// count it before the panel draws it. `nil` when there is none.
    static func totalsComparison(_ input: Input) -> WorktreeChanges.Comparison? {
        unviewedRange(of: timeline(input.agents.flatMap(\.turns)), input: input).map(comparison)
    }

    /// The worktree's unviewed range: the one comparison "Review
    /// Unviewed" opens, from the oldest unviewed turn's begin to the end of
    /// the one that ended last (`ReviewScopeCatalog.unviewedTurns`). `nil`
    /// when nothing is unviewed, or the record is incomplete.
    private static func unviewedRange(of timeline: [TurnSummary], input: Input) -> ReviewTurnRange? {
        guard case let .range(range) = unviewedTurns(of: timeline, input: input) else { return nil }
        return range
    }

    private static func unviewedTurns(of timeline: [TurnSummary], input: Input) -> ReviewUnviewedTurns {
        ReviewScopeCatalog.unviewedTurns(
            turns: timeline,
            isViewed: { input.line($0.conversation)?.isViewed($0) ?? false },
            isRestored: input.isRestored
        )
    }

    /// The two trees the totals compare: the unviewed range's, so the
    /// totals say what "Review Unviewed" shows, never the pulls and merges
    /// between turns long viewed.
    static func comparison(_ range: ReviewTurnRange) -> WorktreeChanges.Comparison {
        WorktreeChanges.Comparison(begin: range.beginTree, end: range.endTree)
    }

    /// The conversation "Review Unviewed" opens the worktree's unviewed
    /// turns from: the focused pane's, while it has an unviewed turn
    /// in the worktree, else the conversation of the newest unviewed turn,
    /// whose pane the review returns to. `nil` when nothing is unviewed.
    static func reviewConversation(
        _ timeline: [TurnSummary],
        focused: ConversationKey?,
        isViewed: (TurnSummary) -> Bool,
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> ConversationKey? {
        let unviewed = timeline.filter { ReviewScopeCatalog.isReadable($0) && !isViewed($0) && !isRestored($0) }
        if let focused, unviewed.contains(where: { $0.conversation == focused }) {
            return focused
        }
        return unviewed.max { WorktreeTimeline.endDate($0) < WorktreeTimeline.endDate($1) }?.conversation
    }

    // MARK: - The rows

    private static func row(_ turn: TurnSummary, line: ViewedLine?, input: Input) -> Row {
        let isViewed = line?.isViewed(turn) ?? false
        let isRestored = input.isRestored(turn)
        let status: Status = if turn.phase == .started {
            .running
        } else if turn.changes.isLostSnapshot {
            .incompleteRecord
        } else if case .unavailable = turn.changes {
            .changesUnavailable
        } else if !turn.changes.mayHaveChangedFiles {
            .answerOnly
        } else if isRestored {
            .restored
        } else {
            isViewed ? .viewed : .unviewed
        }
        // The line moves under any ended turn, whatever it changed; a turn
        // still running is left below it, since nobody has seen it. A
        // restored turn neither opens nor moves the line: its changes are
        // gone, and the struck row is only a record of them.
        let action: RowAction? = turn.phase == .started || status == .restored
            ? nil
            : (isViewed ? .markUnviewedFrom : .markViewedThrough)
        let offersRestore = status.hasCounts && turn.beginTree != nil
        let isReadable = ReviewScopeCatalog.isReadable(turn) || (turn.phase != .started && turn.changes.isLostSnapshot)
        return Row(
            turn: turn,
            status: status,
            isViewed: isViewed,
            isSelectable: isReadable && status != .restored,
            action: action,
            offersRestore: offersRestore,
            restoreBlocker: offersRestore ? input.restoreBlocker(turn) : nil
        )
    }

    /// The viewed rows at the top of the list, folded: the run of viewed
    /// rows from the first, two or more of them, and never the last row,
    /// which is what the panel opens on. Below the first unviewed row the
    /// rows stay as they are, viewed or not: another conversation's viewed
    /// turn between two unviewed ones is part of the story.
    static func fold(_ rows: [Row]) -> Fold? {
        let count = rows.dropLast().prefix { $0.isViewed }.count
        return count >= 2 ? Fold(count: count) : nil
    }

    /// The fold as its line offers it: only while it hides its rows. Once
    /// opened the line leaves the list, and while the review reads a row it
    /// holds the rows stay shown, where a line offering to show them would
    /// be wrong. `hidden` is what the list hides
    /// (`hiddenRows(fold:isUnfolded:shownInReview:rows:)`); a closed
    /// section hides its rows too, and draws no line, so its caller asks
    /// only for an open one.
    static func foldLine(_ fold: Fold?, rows: [Row], hidden: Set<TurnID>) -> Fold? {
        guard let fold, let first = rows.first, hidden.contains(first.id) else { return nil }
        return fold
    }

    /// The rows the fold hides: those it holds, until the person opens
    /// it, and none while the review tab reads a turn among them, which the
    /// list rings and must show.
    static func hiddenRows(fold: Fold?, isUnfolded: Bool, shownInReview: Set<TurnID>, rows: [Row]) -> Set<TurnID> {
        guard let fold, !isUnfolded else { return [] }
        let folded = Set(rows.prefix(fold.count).map(\.id))
        return folded.isDisjoint(with: shownInReview) ? folded : []
    }

    /// The rows the list draws, in order: what a remembered scroll place
    /// is looked for among, so a place on a row folded away since is no
    /// place, and the list opens where it would.
    static func drawnRows(_ rows: [Row], hidden: Set<TurnID>) -> [TurnID] {
        rows.map(\.id).filter { !hidden.contains($0) }
    }

    /// The line below the latest turn: drawn once every row is
    /// viewed, and then "Unmark as Viewed" takes back the last mark while
    /// it is still the last move of each line it moved. The last mark is
    /// the one of the latest move among the conversations shown, by its
    /// place among the store's marks (`ViewedLineChange.sequence`); its moves
    /// are every move with the same `markID` among `conversations`, the
    /// worktree's, whether the filter shows them or not, so one press takes
    /// back what one press did, before a relaunch and after it. A move from
    /// a file that kept no mark is taken back alone. A conversation whose
    /// line moved on since keeps its line.
    static func line(
        _ rows: [Row],
        conversations: [ConversationKey],
        line: (ConversationKey) -> ViewedLine?
    ) -> Line? {
        guard !rows.isEmpty, rows.allSatisfy(\.isViewed) else { return nil }
        /// The conversation's last move, while its line still stands where
        /// that move put it.
        func standing(_ conversation: ConversationKey) -> ViewedLineChange? {
            guard let viewedLine = line(conversation), let last = viewedLine.history.last,
                  let position = viewedLine.position, last.to == position
            else { return nil }
            return last
        }
        var shown: [ConversationKey] = []
        for row in rows where !shown.contains(row.turn.conversation) {
            shown.append(row.turn.conversation)
        }
        // By the mark's place among the store's marks, which the file
        // keeps; a move from a file without it, by its time.
        let latest = shown.compactMap { conversation in standing(conversation).map { (conversation, $0) } }
            .max { lhs, rhs in
                let left = (lhs.1.sequence ?? 0, lhs.1.at, lhs.1.id.uuidString)
                let right = (rhs.1.sequence ?? 0, rhs.1.at, rhs.1.id.uuidString)
                return left < right
            }
        guard let (conversation, change) = latest else { return Line(undo: []) }
        guard let markID = change.markID else {
            return Line(undo: [ViewedLineUndo(conversation: conversation, changeID: change.id)])
        }
        var every = shown
        for other in conversations where !every.contains(other) {
            every.append(other)
        }
        let undo = every.compactMap { conversation -> ViewedLineUndo? in
            guard let move = standing(conversation), move.markID == markID else { return nil }
            return ViewedLineUndo(conversation: conversation, changeID: move.id)
        }
        .sorted { $0.conversation.conversationID < $1.conversation.conversationID }
        return Line(undo: undo)
    }

    /// Where the panel opens, among the rows as drawn: the focused pane's
    /// conversation's last unviewed turn, else the last unviewed, else the last.
    private static func scrollTarget(_ rows: [Row], focused: ConversationKey?) -> TurnID? {
        let unviewed = rows.filter { $0.status == .unviewed }
        return (unviewed.last { $0.turn.conversation == focused } ?? unviewed.last ?? rows.last)?.id
    }

    /// The list's last card with moves shows them at rest (each section's,
    /// in the list grouped by conversation), and so does the
    /// card whose note says why a restore waits, so the note never speaks
    /// of a glyph out of sight. The others show them under the pointer or
    /// the keyboard or while the review reads them, so the list does not
    /// repeat the same glyphs down every card. A running turn, last while
    /// it runs, has no moves to show. Placed after `placeBlockerNote`.
    static func placeMovesAtRest(rows: inout [Row]) {
        if let last = rows.lastIndex(where: { $0.action != nil || $0.offersRestore }) {
            rows[last].showsMovesAtRest = true
        }
        for index in rows.indices where rows[index].showsBlockerNote {
            rows[index].showsMovesAtRest = true
        }
    }

    /// Why a restore is off is said in a line under one entry only: the
    /// list's last one (each section's, in the list grouped by
    /// conversation), the latest turn's, which is where the reader looks.
    /// Said under every entry, the line would come and go on every card
    /// as an agent starts and stops, and the list would jump. The others
    /// keep the reason in their tooltip and VoiceOver hint.
    static func placeBlockerNote(rows: inout [Row]) {
        guard let lastRow = rows.lastIndex(where: \.offersRestore) else { return }
        rows[lastRow].showsBlockerNote = rows[lastRow].restoreBlocker != nil
    }
}

extension ChangesPanelModel {
    /// The numbers of every turn recorded, by conversation, in any
    /// worktree: a number missing there is a turn the retention sweep
    /// deleted (`OutsideTurnsPlan.make`).
    static func recordedNumbers(_ history: [ConversationKey: [TurnSummary]]) -> [ConversationKey: Set<Int>] {
        history.mapValues { Set($0.map(\.displayNumber)) }
    }

    /// Every agent's turns recorded in a worktree, which is what the
    /// changes outside turns are counted against (`OutsideTurnsPlan`).
    static func turnsHere(
        history: [ConversationKey: [TurnSummary]],
        root: String,
        isRoot: @escaping (String) -> Bool
    ) -> [TurnSummary] {
        agents(history: history, running: [], root: root, isRoot: isRoot).flatMap(\.turns)
    }

    /// The agents of a session's worktree, in a stable order: each
    /// conversation with a turn recorded in it, by its first turn, then an
    /// agent running in the session that has none here yet. A conversation
    /// whose turns were all recorded in other worktrees is not this
    /// session's (`ReviewTabModel.turns`), unless it runs here now.
    static func agents(
        history: [ConversationKey: [TurnSummary]],
        running: [ConversationKey],
        root: String,
        isRoot: @escaping (String) -> Bool
    ) -> [Agent] {
        let isRunning = Set(running)
        let recorded = history.compactMap { conversation, turns -> Agent? in
            let here = ReviewTabModel.turns(turns, root: root, conversation: conversation, isRoot: isRoot)
            let hasTreeHere = here.contains { turn in
                [turn.beginTree, turn.endTree].contains { $0.map { isRoot($0.root) } ?? false }
            }
            guard !here.isEmpty, hasTreeHere || isRunning.contains(conversation) else { return nil }
            return Agent(conversation: conversation, turns: here)
        }
        /// By the first turn's start, and by ID where two started at once.
        func start(_ agent: Agent) -> Date {
            UnreadTurnRules.date(agent.turns.first?.startedAt) ?? .distantPast
        }
        let ordered = recorded.sorted { lhs, rhs in
            start(lhs) == start(rhs) ? lhs.conversation.conversationID < rhs.conversation.conversationID : start(lhs) < start(rhs)
        }
        var seen = Set(ordered.map(\.conversation))
        var waiting: [ConversationKey] = []
        for conversation in running where seen.insert(conversation).inserted {
            waiting.append(conversation)
        }
        return ordered + waiting.map { Agent(conversation: $0, turns: []) }
    }
}
