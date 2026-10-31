// ReviewScopeMenuTests.swift
// Weir — the review tab across a worktree's conversations: the scope menu, the file tags, Mark as Viewed, and the draft.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Review scope menu across conversations")
struct ReviewScopeMenuTests {
    private typealias Fixture = TurnSummaryFixture
    private static let root = "/repo"
    private static let pane = UUID()
    private static let en = Locale(identifier: "en")
    private static let ja = Locale(identifier: "ja")
    private static let claude = Fixture.conversation("claude")
    private static let codex = Fixture.conversation("codex")
    private static let quiet = Fixture.conversation("quiet")

    /// A turn of `conversation` with both snapshots, started at minute
    /// `start` and ended at minute `end` of 10 a.m. Turns of Claude and of
    /// the quiet conversation that share a number and an end time end at one
    /// tree; Codex's never share one with them.
    private static func turn(
        _ number: Int,
        of conversation: ConversationKey = claude,
        start: Int,
        end: Int? = nil,
        hasBegin: Bool = true,
        hasEnd: Bool = true,
        changes: String = Fixture.changedFiles
    ) throws -> TurnSummary {
        try Fixture.timed(
            number,
            conversation: conversation.conversationID,
            start: 36000 + start * 60,
            end: 36000 + (end ?? start + 1) * 60,
            changes: changes,
            hasBegin: hasBegin,
            hasEnd: hasEnd,
            endKind: conversation == codex ? "c" : "a"
        )
    }

    private static func named(
        _ conversation: ConversationKey,
        ordinal: Int?,
        unviewed: Int,
        runningHere: Bool = false
    ) -> ConversationChoice {
        ConversationChoice(
            conversation: conversation,
            ordinal: ordinal,
            unviewedCount: unviewed,
            liveTab: runningHere ? ConversationChoice.LiveTab(title: "claude", isInSession: true) : nil
        )
    }

    /// Codex T1 (unviewed, 10:00–10:02), Claude T3 (viewed, 10:05),
    /// Claude T4 (unviewed, 10:10), and a third conversation, ended and
    /// viewed (10:20).
    @MainActor
    private struct Worktree {
        let codex1: TurnSummary
        let claude3: TurnSummary
        let claude4: TurnSummary
        let quiet1: TurnSummary
        let context: ReviewTabModel.Context

        var timeline: [TurnSummary] {
            [codex1, claude3, claude4, quiet1]
        }

        init() throws {
            codex1 = try ReviewScopeMenuTests.turn(1, of: ReviewScopeMenuTests.codex, start: 0, end: 2)
            claude3 = try ReviewScopeMenuTests.turn(3, start: 5)
            claude4 = try ReviewScopeMenuTests.turn(4, start: 10)
            quiet1 = try ReviewScopeMenuTests.turn(1, of: ReviewScopeMenuTests.quiet, start: 20)
            let viewed: Set<TurnID> = [claude3.turnID, quiet1.turnID]
            var context = ReviewTabModel.Context(
                turns: [claude3, claude4],
                conversation: ReviewScopeMenuTests.claude,
                isViewed: { viewed.contains($0.turnID) },
                branchBase: "main"
            )
            context.worktreeTurns = [codex1, claude3, claude4, quiet1]
            context.conversations = [
                ReviewScopeMenuTests.named(ReviewScopeMenuTests.claude, ordinal: 1, unviewed: 1, runningHere: true),
                ReviewScopeMenuTests.named(ReviewScopeMenuTests.codex, ordinal: nil, unviewed: 1),
                ReviewScopeMenuTests.named(ReviewScopeMenuTests.quiet, ordinal: 2, unviewed: 0)
            ]
            context.conversationTurns = [
                ReviewScopeMenuTests.claude: [claude3, claude4],
                ReviewScopeMenuTests.codex: [codex1],
                ReviewScopeMenuTests.quiet: [quiet1]
            ]
            self.context = context
        }

        func open(_ request: ReviewTabRequest) throws -> ReviewTabState {
            try ReviewTabModel.open(request, context, root: ReviewScopeMenuTests.root, agentPaneID: ReviewScopeMenuTests.pane, current: nil)
                .get()
        }
    }

    // MARK: - The scope catalog

    /// A range of one conversation reads through the other conversations'
    /// turns that ran inside it; the file tags read those too.
    @Test func aRange_readsThroughEveryConversationsTurnsBetweenItsEnds() throws {
        let worktree = try Worktree()
        let claudeOnly = try #require(ReviewTurnRange(turns: [worktree.claude3, worktree.claude4]))
        let across = try #require(ReviewTurnRange(turns: [worktree.codex1, worktree.claude3, worktree.claude4]))

        #expect(ReviewScopeCatalog.turnsThrough(claudeOnly, timeline: worktree.timeline).map(\.turnID)
            == [worktree.claude3.turnID, worktree.claude4.turnID])
        #expect(ReviewScopeCatalog.turnsThrough(across, timeline: worktree.timeline).map(\.turnID)
            == [worktree.codex1.turnID, worktree.claude3.turnID, worktree.claude4.turnID])
        #expect(ReviewScopeCatalog.turnsThrough(across, timeline: [worktree.claude4]).isEmpty, "an end off the timeline reads nothing")
    }

    /// The worktree's range is one comparison from the oldest unviewed
    /// begin to the newest unviewed end; one whose record is incomplete
    /// (`ReviewScopeCatalogTests`) says so in the menu and the band.
    @Test func theWorktreesInterval_runsFromTheOldestUnviewedBegin_andAnIncompleteEndIsSaid() throws {
        let worktree = try Worktree()
        let tab = try worktree.open(.worktreeUnviewedTurns)
        guard case let .worktreeUnviewedTurns(.range(range)) = tab.selection else {
            Issue.record("expected the worktree's range, got \(tab.selection)")
            return
        }
        #expect(range.turnIDs == [worktree.codex1.turnID, worktree.claude3.turnID, worktree.claude4.turnID])
        #expect(range.beginTree == worktree.codex1.beginTree?.tree)
        #expect(range.endTree == worktree.claude4.endTree?.tree)

        let incomplete = ReviewUnviewedTurns.incomplete(1...4)
        #expect(ReviewTabText.option(.worktreeUnviewedTurns(incomplete), locale: Self.ja) == "ワークツリーの未確認のターン（記録が不完全）")
        #expect(ReviewTabModel.bandStatus(.worktreeUnviewedTurns(incomplete), fileIDs: [], viewed: []) == .incompleteRecord)
    }

    // MARK: - The menu

    @Test func theMenu_listsTheWorktree_eachConversationUnderItsHeading_foldsTheViewedOnes_andEndsWithTheWorktreesOwn() throws {
        let worktree = try Worktree()
        let tab = try worktree.open(.unviewedTurns)

        let menu = ReviewScopeMenu.make(tab, worktree.context)

        let top = try #require(menu.worktree)
        guard case .worktreeUnviewedTurns(.range) = top.option else {
            Issue.record("the first entry is the worktree's range")
            return
        }
        #expect(top.conversation == nil && !top.isChecked)
        #expect(menu.worktreeCounts?.viewedTurns == 1, "Claude's T3 is viewed, inside the range")
        #expect(menu.sections.map(\.conversation?.conversation) == [Self.claude, Self.codex], "running first, then with turns to read")
        #expect(menu.folded.map(\.conversation?.conversation) == [Self.quiet], "the ended, viewed one folded")
        let own = try #require(menu.sections.first)
        #expect(own.choices.map(\.conversation) == Array(repeating: Self.claude, count: own.choices.count))
        #expect(own.choices.first?.isChecked == true, "the tab's choice, under its own conversation")
        #expect(menu.choices.count { $0.isChecked } == 1, "one checkmark, in one section")
        #expect(menu.tail.map(\.option) == [.uncommitted(includesChangesOutsideTurns: false), .branch(base: "main")])
        #expect(menu.labelConversation?.conversation == Self.claude, "the label names the conversation read")

        // The same unviewed turns of Codex, under Codex's heading.
        let codexSection = try #require(menu.sections.last)
        #expect(codexSection.choices.allSatisfy { !$0.isChecked })
        #expect(ReviewTabText.option(codexSection.choices[0].option, locale: Self.en) == "Unviewed Turns (T1)")
    }

    @Test func theMenu_onTheWorktreesRange_checksItAlone_andTheLabelNamesNoConversation() throws {
        let worktree = try Worktree()
        let tab = try worktree.open(.worktreeUnviewedTurns)

        let menu = ReviewScopeMenu.make(tab, worktree.context)

        #expect(menu.worktree?.isChecked == true)
        #expect(menu.choices.count { $0.isChecked } == 1)
        #expect(menu.labelConversation == nil)
        let counts = menu.counts(of: tab.selection)
        #expect(counts == ReviewScopeCatalog.RangeCounts(unviewedTurns: 2, unviewedConversations: 2, viewedTurns: 1))
        #expect(ReviewTabText.option(tab.selection, counts: counts, locale: Self.en) == "All Unviewed (2 turns · 2 conversations)")
        #expect(
            ReviewTabText.scope(tab.selection, conversation: menu.labelConversation, counts: counts, locale: Self.ja)
                == "すべての未確認（ターン 2 · 会話 2）"
        )
        #expect(ReviewTabText.option(tab.selection, locale: Self.en) == "All Unviewed", "named alone without its counts")
        #expect(ReviewTabText.tabName(tab.selection, locale: Self.en) == "Unviewed Turns")
    }

    /// Fifteen ended conversations of five turns each, every one with turns
    /// to read: each listed conversation puts its unviewed turns at the top
    /// level and its single turns in one submenu; past the limit, newest
    /// first, they fold into one entry each, so the menu stays a few lines
    /// per conversation and the worktree's own comparisons stay in sight.
    @Test func manyConversations_keepTheMenuShort_eachTurnInASubmenu_newestListedWhole() throws {
        let now = Date(timeIntervalSince1970: 1_791_800_000)
        var turns: [ConversationKey: [TurnSummary]] = [:]
        var named: [ConversationChoice] = []
        for index in 1...15 {
            let conversation = Fixture.conversation("c\(index)")
            turns[conversation] = try (1...5).map { number in
                try Self.turn(number, of: conversation, start: index * 2 + number % 2)
            }
            named.append(ConversationChoice(
                conversation: conversation,
                ordinal: index,
                unviewedCount: 5,
                lastActivity: now.addingTimeInterval(TimeInterval(index * 60))
            ))
        }
        let own = Fixture.conversation("c1")
        var context = ReviewTabModel.Context(turns: turns[own] ?? [], conversation: own, isViewed: { _ in false }, branchBase: "main")
        context.conversations = named
        context.conversationTurns = turns
        context.worktreeTurns = WorktreeTimeline.ordered(turns.values.flatMap(\.self))
        let tab = try ReviewTabModel.open(.unviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil).get()

        let menu = ReviewScopeMenu.make(tab, context)

        #expect(menu.sections.count == ReviewScopeMenu.listedLimit)
        #expect(
            menu.sections.map { $0.conversation?.ordinal } == [15, 14, 13, 12, 1],
            "the newest by their latest activity, and the tab's own, whatever its age, in its place"
        )
        #expect(menu.more.count == 10 && menu.folded.isEmpty)
        for section in menu.sections {
            guard case .unviewedTurns? = section.lead?.option else {
                Issue.record("a listed conversation leads with its unviewed turns")
                continue
            }
            #expect(section.turns.count == 5, "its single turns, in the submenu")
        }
        // The top level: the worktree's heading and entry; per listed
        // conversation its heading, unviewed turns, and "Turns ▸"; one
        // heading and one entry per further conversation; the separator
        // and the worktree's own two.
        let topLevel = 2 + menu.sections.count * 3 + 1 + menu.more.count + 1 + menu.tail.count
        #expect(topLevel <= 32, "a few lines per conversation, not one per turn")
        #expect(menu.choices.count == 1 + 15 * 6 + 2, "every choice still reachable")
        #expect(ReviewTabText.turnsSubmenu(locale: Self.ja) == "ターン")
        #expect(ReviewTabText.moreConversationsHeading(locale: Self.ja) == "ほかの会話")
        #expect(ReviewTabText.moreConversationsHeading(locale: Self.en) == "More Conversations")
    }

    /// One conversation: no headings and no worktree entry, the four kinds
    /// of choice it always had.
    @Test func theMenuOfOneConversation_isTheCatalogsChoices() throws {
        let turns = try [Self.turn(3, start: 5), Self.turn(4, start: 10)]
        var context = ReviewTabModel.Context(turns: turns, conversation: Self.claude, isViewed: { _ in false }, branchBase: "main")
        context.conversations = [Self.named(Self.claude, ordinal: nil, unviewed: 2)]
        context.worktreeTurns = turns
        let tab = try ReviewTabModel.open(.unviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil).get()

        let menu = ReviewScopeMenu.make(tab, context)

        #expect(menu.worktree == nil)
        #expect(menu.sections.count == 1 && menu.sections[0].conversation == nil)
        #expect(menu.folded.isEmpty)
        #expect(menu.labelConversation == nil)
        #expect(menu.choices.map(\.option) == ReviewScopeCatalog.options(
            turns: turns,
            isViewed: { _ in false },
            branchBase: "main",
            hasChangesOutsideTurns: false
        ))
    }

    /// A choice under another conversation's heading reads that
    /// conversation's turns, and its comments go to that conversation's
    /// pane, or to none while it has no pane.
    @Test func aChoiceUnderAnotherHeading_takesTheTabToThatConversation_andItsPane() throws {
        let worktree = try Worktree()
        let tab = try worktree.open(.unviewedTurns)
        var codexContext = worktree.context
        codexContext.turns = [worktree.codex1]
        codexContext.conversation = Self.codex
        let codexPane = UUID()
        let option = ReviewScopeOption.unviewedTurns(ReviewScopeCatalog.unviewedTurns(turns: [worktree.codex1]) { _ in false })

        let moved = ReviewTabModel.select(option, conversation: Self.codex, agentPaneID: codexPane, in: tab, codexContext)
        #expect(moved.conversation == Self.codex)
        #expect(moved.destinationPaneID == codexPane)
        #expect(moved.agentPaneID == codexPane)
        #expect(moved.opening == tab.opening, "the same tab")

        let paneless = ReviewTabModel.select(option, conversation: Self.codex, agentPaneID: nil, in: tab, codexContext)
        #expect(paneless.destinationPaneID == nil, "no comment goes into Claude's input")
        #expect(paneless.agentPaneID == Self.pane, "closing returns to the pane it came from")

        var withDestination = tab
        withDestination.destinationPaneID = UUID()
        let same = ReviewTabModel.select(
            .uncommitted(includesChangesOutsideTurns: false),
            conversation: Self.claude,
            agentPaneID: nil,
            in: withDestination,
            worktree.context
        )
        #expect(same.destinationPaneID == withDestination.destinationPaneID, "the same conversation keeps the destination picked")
    }

    // MARK: - File tags

    @Test func theFileTags_nameEachConversationWhoseTurnsChangedTheFile_inTimelineOrder() throws {
        let worktree = try Worktree()
        let turns = [worktree.codex1, worktree.claude3, worktree.claude4]
        let paths: [TurnID: Set<String>] = [
            worktree.codex1.turnID: ["a.swift", "b.swift"],
            worktree.claude3.turnID: ["a.swift"],
            worktree.claude4.turnID: ["a.swift", "c.swift"]
        ]

        let tags = ReviewFileTags.tags(turns: turns, paths: { paths[$0] }, conversations: worktree.context.conversations)

        #expect(tags["a.swift"] == [
            ReviewFileTag(provider: .claude, ordinal: nil, turns: [1]),
            ReviewFileTag(provider: .claude, ordinal: 1, turns: [3, 4])
        ])
        #expect(tags["b.swift"]?.map(\.turns) == [[1]])
        #expect(tags["c.swift"]?.map(\.ordinal) == [1])

        let unread = ReviewFileTags.tags(
            turns: turns,
            paths: { $0 == worktree.codex1.turnID ? nil : paths[$0] },
            conversations: worktree.context.conversations
        )
        #expect(unread["b.swift"] == nil, "a turn whose files are not read yet tags nothing")
        #expect(unread["a.swift"]?.count == 1)

        let alone = ReviewFileTags.tags(turns: turns, paths: { paths[$0] }, conversations: [worktree.context.conversations[0]])
        #expect(alone.isEmpty, "one conversation: no tag would tell anything apart")
    }

    /// A tag carries its conversation's identity color, which its face
    /// shows, and its title, which its tooltip names it by; so does a turn
    /// whose files could not be read.
    @Test func theFileTags_keepEachConversationsIdentity() throws {
        let worktree = try Worktree()
        var conversations = worktree.context.conversations
        conversations[0].identity = 1
        conversations[0].title = "Fix tests"

        let tags = ReviewFileTags.tags(turns: [worktree.claude3], paths: { _ in ["a.swift"] }, conversations: conversations)
        let unreadable = ReviewFileTags.unreadable(turns: [worktree.claude3], isUnreadable: { _ in true }, conversations: conversations)

        #expect(tags["a.swift"]?.map(\.identity) == [1])
        #expect(unreadable.map(\.identity) == [1])
        // The title goes with the tag, so its tooltip and VoiceOver name the
        // conversation as the menus do.
        #expect(tags["a.swift"]?.map(\.title) == ["Fix tests"])
        #expect(unreadable.map(\.title) == ["Fix tests"])
    }

    /// A file five conversations touched shows two tags and "3 more", so its
    /// path keeps the header's room; the tooltip and VoiceOver name every
    /// one, and say when a turn's files could not be read, which a tag may
    /// then lack.
    @Test func aFileOfManyConversations_showsTwoTagsAndHowManyMore_andSaysWhatCouldNotBeRead() throws {
        let tags = (1...5).map { ReviewFileTag(provider: .claude, ordinal: $0, turns: [$0]) }

        let (shown, more) = ReviewFileTags.shown(tags)

        #expect(shown == Array(tags.prefix(2)))
        #expect(more == 3)
        #expect(ReviewFileTags.shown(Array(tags.prefix(2))).more == 0, "two fit whole")
        #expect(ReviewTabText.moreFileTags(3, locale: Self.ja) == "ほか 3 件")
        #expect(ReviewTabText.moreFileTags(3, locale: Self.en) == "3 more")
        let help = try #require(ReviewTabText.fileTagsHelp(tags, unreadable: [], locale: Self.en))
        #expect(help.split(separator: "\n").count == 5, "every tag, the ones left out too")

        let worktree = try Worktree()
        let turns = [worktree.codex1, worktree.claude3, worktree.claude4]
        let unreadable = ReviewFileTags.unreadable(
            turns: turns,
            isUnreadable: { $0 == worktree.claude3.turnID },
            conversations: worktree.context.conversations
        )
        #expect(unreadable == [ReviewFileTag(provider: .claude, ordinal: 1, turns: [3])])
        #expect(ReviewTabText.unreadableNote(unreadable, locale: Self.en)
            == "Couldn’t read the files changed during Claude #1’s T3, so a tag may be missing")
        #expect(ReviewTabText.unreadableNote(unreadable, locale: Self.ja)
            == "Claude #1 の T3 の間に変更されたファイルを読み込めなかったため、タグが欠けていることがあります")
        #expect(ReviewTabText.fileTagsHelp([tags[0]], unreadable: unreadable, locale: Self.en)?
            .hasSuffix("so a tag may be missing") == true)
        #expect(ReviewTabText.unreadableNote([], locale: Self.en) == nil)

        let file = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        var input = ReviewStackBuilder.Input(files: [file], slots: [file.id: 0])
        input.unreadableTags = unreadable
        let stack = ReviewStackBuilder.build(input) { _, _, _ in ReviewStackPiece(rows: []) }
        if let row = stack.headerRow(of: file.id), case let .file(header) = stack.rows[row].kind {
            #expect(header.unreadableTags == unreadable, "every header knows, tagged or not")
        } else {
            Issue.record("the file has a header")
        }
    }

    @Test func aFileHeader_carriesItsTags_besideItsMarks_andStillFolds() {
        let file = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        let tag = ReviewFileTag(provider: .codex, ordinal: nil, turns: [1])
        var input = ReviewStackBuilder.Input(files: [file], slots: [file.id: 0])
        input.viewed = [file.id]
        input.marks = [file.id: [.changedOutsideTurns]]
        input.tags = [file.id: [tag]]

        let stack = ReviewStackBuilder.build(input) { _, _, _ in ReviewStackPiece(rows: []) }
        let row = stack.headerRow(of: file.id)
        var header: ReviewStackHeader?
        if let row, case let .file(found) = stack.rows[row].kind {
            header = found
        }
        #expect(header?.tags == [tag])
        #expect(header?.marks == [.changedOutsideTurns])
        #expect(header?.isFolded == true, "a checked file folds whatever its tags")
    }

    // MARK: - Mark as Viewed

    @Test func markAsViewed_onTheWorktreesRange_movesEveryConversationsLine_asOneMark_withOneUndo() throws {
        let worktree = try Worktree()
        let tab = try worktree.open(.worktreeUnviewedTurns)

        let action = ReviewTabModel.markViewed(tab, worktree.context)
        let claude4 = ReviewTabTurn(id: worktree.claude4.turnID, number: 4)
        let codex1 = ReviewTabTurn(id: worktree.codex1.turnID, number: 1)
        #expect(action == .throughTurns([claude4, codex1]), "each conversation's last turn, the range's last first")
        #expect(try ReviewTabText.markViewedHelp(#require(action), locale: Self.ja) == "すべての会話の確認済みの線をこの範囲の最後まで移動します（⌘⏎）")

        let lines = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let toasts = ToastCenter()
        let window = ProjectWindowState(id: WindowID())
        let actions = ViewedLineActions(
            queue: AttentionQueue(),
            attention: AttentionState(),
            history: [Self.claude: [worktree.claude3, worktree.claude4], Self.codex: [worktree.codex1]],
            lines: lines,
            toasts: toasts,
            window: window
        )
        let moves = actions.markViewed(through: [worktree.claude4, worktree.codex1], source: .review, named: { _ in "Claude #1" })

        #expect(moves.map(\.conversation) == [Self.claude, Self.codex])
        #expect(lines.isViewed(worktree.claude4) && lines.isViewed(worktree.codex1))
        let toast = try #require(toasts.current(in: window.id))
        #expect(toast.message.resolved(in: Self.ja) == "Claude #1 の T4 まで確認済みにしました。ほかの会話 1 件も同じ時点まで確認済みにしました。")
        toast.undo?()
        #expect(!lines.isViewed(worktree.claude4) && !lines.isViewed(worktree.codex1), "one Undo, both lines back")

        // Once every turn of the range is viewed, there is nothing to mark.
        var viewed = worktree.context
        viewed.isViewed = { _ in true }
        #expect(ReviewTabModel.markViewed(tab, viewed) == nil)
        // A conversation's own range keeps its one line.
        let own = try worktree.open(.unviewedTurns)
        #expect(ReviewTabModel.markViewed(own, worktree.context) == .throughTurn(claude4))
    }

    // MARK: - Overlapping turns

    /// Claude's T5 ran 10:00–10:30 and Codex's T1 10:05–10:10, both
    /// unviewed: "Mark as Viewed" on the worktree's range moves both lines,
    /// and the panel's totals compare the same two trees the review reads.
    /// Where the range ends is the range's own rule (`ReviewTurnRangeTests`).
    @Test func theWorktreesRange_endsAtTheTurnThatEndedLast_soALongTurnsLaterPartIsInIt() throws {
        let claude5 = try Self.turn(5, start: 0, end: 30)
        let codex1 = try Self.turn(1, of: Self.codex, start: 5, end: 10)
        let timeline = WorktreeTimeline.listed([codex1, claude5])
        var context = ReviewTabModel.Context(turns: [claude5], conversation: Self.claude, isViewed: { _ in false }, branchBase: nil)
        context.worktreeTurns = timeline

        guard case let .range(range) = ReviewScopeCatalog.unviewedTurns(turns: timeline, isViewed: { _ in false }) else {
            Issue.record("expected a range")
            return
        }

        let tab = try ReviewTabModel.open(.worktreeUnviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil).get()
        #expect(ReviewTabModel.markViewed(tab, context) == .throughTurns([
            ReviewTabTurn(id: claude5.turnID, number: 5),
            ReviewTabTurn(id: codex1.turnID, number: 1)
        ]))

        let input = ChangesPanelModel.Input(
            agents: [Self.claude, Self.codex].map { conversation in
                ChangesPanelModel.Agent(conversation: conversation, turns: timeline.filter { $0.conversation == conversation })
            },
            line: { _ in nil }
        )
        #expect(
            ChangesPanelModel.totalsComparison(input) == ChangesPanelModel.comparison(range),
            "the panel's totals and the review read one interval"
        )
    }

    /// A turn nested inside a long one, a viewed one between, and the
    /// range still ends at the long turn's end; the viewed one is counted.
    @Test func aNestedTurn_staysInsideTheLongTurnsRange_withTheViewedOneBetween() throws {
        let claude5 = try Self.turn(5, start: 0, end: 30)
        let codex1 = try Self.turn(1, of: Self.codex, start: 5, end: 10)
        let codex2 = try Self.turn(2, of: Self.codex, start: 12, end: 20)
        let timeline = WorktreeTimeline.listed([claude5, codex1, codex2])
        let isViewed = { (turn: TurnSummary) in turn.turnID == codex1.turnID }

        guard case let .range(range) = ReviewScopeCatalog.unviewedTurns(turns: timeline, isViewed: isViewed) else {
            Issue.record("expected a range")
            return
        }
        #expect(range.turnIDs == [claude5.turnID, codex1.turnID, codex2.turnID])
        #expect(range.endTree == claude5.endTree?.tree)
        #expect(ReviewScopeCatalog.counts(in: range, timeline: timeline, isViewed: isViewed).viewedTurns == 1)
    }

    /// A turn still running is no turn of the range and never its end; a
    /// turn that started inside it and ended after it is not one either.
    @Test func aRunningTurn_andOneThatEndsAfter_areNoneOfTheRanges() throws {
        let claude5 = try Self.turn(5, start: 0, end: 10)
        let running = try Fixture.turn(
            "codex-T1",
            phase: "started",
            changes: Fixture.changedFiles,
            number: 1,
            extras: {
                var extras = Fixture.Extras()
                extras.conversationID = Self.codex.conversationID
                extras.startedAt = "2026-10-12T10:05:00Z"
                return extras
            }()
        )
        let viewedLater = try Self.turn(1, of: Self.quiet, start: 8, end: 40)
        let timeline = WorktreeTimeline.listed([claude5, running, viewedLater])

        let found = ReviewScopeCatalog.unviewedTurns(turns: timeline) { $0.turnID == viewedLater.turnID }
        guard case let .range(range) = found else {
            Issue.record("expected a range, got \(found)")
            return
        }
        #expect(range.turnIDs == [claude5.turnID])
        #expect(range.endTree == claude5.endTree?.tree)
    }

    // MARK: - File tags by time

    /// Codex's T1 started and ended inside Claude's T5: a range of T5
    /// alone reads through it, so its file is tagged.
    @Test func aSingleTurnsRange_readsThroughATurnThatRanInsideIt() throws {
        let claude5 = try Self.turn(5, start: 0, end: 30)
        let codex1 = try Self.turn(1, of: Self.codex, start: 5, end: 10)
        let codex2 = try Self.turn(2, of: Self.codex, start: 25, end: 40)
        let timeline = WorktreeTimeline.listed([claude5, codex1, codex2])
        let range = try #require(ReviewTurnRange(turns: [claude5]))

        #expect(ReviewScopeCatalog.turnsThrough(range, timeline: timeline).map(\.turnID) == [claude5.turnID, codex1.turnID])
        let tags = ReviewFileTags.tags(
            turns: ReviewScopeCatalog.turnsThrough(range, timeline: timeline),
            paths: { $0 == codex1.turnID ? ["a.swift"] : ["b.swift"] },
            conversations: [Self.named(Self.claude, ordinal: nil, unviewed: 1), Self.named(Self.codex, ordinal: nil, unviewed: 1)]
        )
        #expect(tags["a.swift"]?.map(\.turns) == [[1]], "Codex's T1 is tagged")
    }

    // MARK: - Add to Scope on the worktree's range

    @Test func addToScope_carriesAWorktreeRangeOfOneConversation() throws {
        let claude3 = try Self.turn(3, start: 0)
        let claude4 = try Self.turn(4, start: 10)
        var context = ReviewTabModel.Context(turns: [claude3], conversation: Self.claude, isViewed: { _ in false }, branchBase: nil)
        context.worktreeTurns = [claude3]
        let tab = try ReviewTabModel.open(.worktreeUnviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil).get()

        context.turns = [claude3, claude4]
        context.worktreeTurns = [claude3, claude4]
        #expect(ReviewTabModel.followingTurns(tab, context).map(\.turnID) == [claude4.turnID])
        let carried = try #require(ReviewTabModel.addFollowingTurns(tab, context))

        guard case let .worktreeUnviewedTurns(.range(range)) = carried.tab.selection else {
            Issue.record("expected the worktree's range carried on, got \(carried.tab.selection)")
            return
        }
        #expect(range.turnIDs == [claude3.turnID, claude4.turnID])
        #expect(range.endTree == claude4.endTree?.tree)
        #expect(carried.tab.scope != tab.scope, "a new comparison, which the review carries its comments into")
    }

    // MARK: - The draft

    /// A draft that holds a range across conversations reads back as it was
    /// written; one an earlier build wrote, whose ranges have only the old
    /// keys, still reads, with the file it had open.
    @Test func aDraft_withARangeAcrossConversations_roundTrips_andAnOldDraftStillReads() throws {
        let worktree = try Worktree()
        let across = try #require(ReviewTurnRange(turns: [worktree.codex1, worktree.claude3, worktree.claude4]))
        let own = try #require(ReviewTurnRange(turns: [worktree.claude4]))
        var draft = ReviewDraft()
        draft.ranges = [across, own]
        draft.lastFileID = [across.scopeID: "a.swift"]

        let data = try JSONEncoder().encode(draft)
        let back = try JSONDecoder().decode(ReviewDraft.self, from: data)
        #expect(back.ranges == [across, own])
        #expect(back.lastFileID == [across.scopeID: "a.swift"])

        // The draft as a build before `conversations` wrote it.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ranges = try #require(object["ranges"] as? [[String: Any]])
        ranges = ranges.map { range in
            var range = range
            range.removeValue(forKey: "conversations")
            return range
        }
        object["ranges"] = [ranges[1]]
        let old = try JSONDecoder().decode(ReviewDraft.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.ranges == [own])
        #expect(old.lastFileID == [across.scopeID: "a.swift"])
    }

    @Test func theTopEdgesNotes_sayTheViewedTurnsRead_andWhatATurnsDiffIs_onlyForTurns() throws {
        let worktree = try Worktree()
        let across = try worktree.open(.worktreeUnviewedTurns)

        #expect(ReviewTabScopeNotes.make(across, worktree.context, locale: Self.ja) == [
            "範囲に確認済みのターン 1 を含む",
            "ターンの差分は、そのターンの間にワークツリーで起きた変更です。"
        ])
        let uncommitted = try worktree.open(.uncommitted)
        #expect(ReviewTabScopeNotes.make(uncommitted, worktree.context, locale: Self.en).isEmpty, "not a turn's diff")

        var alone = worktree.context
        alone.conversations = [worktree.context.conversations[0]]
        let own = try worktree.open(.unviewedTurns)
        #expect(ReviewTabScopeNotes.make(own, alone, locale: Self.en).isEmpty, "one conversation: nothing else falls inside a turn")
    }

    // MARK: - The worktree's entry, and a range's ends

    /// The worktree's entry counts the unviewed turns and their
    /// conversations, not every turn and conversation its range reads
    /// through, and says the rest as the viewed turns it includes: those
    /// above their line and those with nothing to read (an answer that
    /// changed no file, read by sight), so the unviewed and viewed turns add
    /// up to the range's turns. The top edge says the same viewed count.
    @Test func theWorktreesEntry_countsItsUnviewedTurns_andTheRestAsViewed() throws {
        let codex1 = try Self.turn(1, of: Self.codex, start: 0, end: 2)
        let quiet1 = try Self.turn(1, of: Self.quiet, start: 3, end: 4)
        let answer = try Self.turn(1, of: Fixture.conversation("answer"), start: 5, end: 6, changes: #"{"kind":"unchanged"}"#)
        let claude3 = try Self.turn(3, start: 7, end: 8)
        let claude4 = try Self.turn(4, start: 10, end: 12)
        let viewed: Set<TurnID> = [quiet1.turnID, claude3.turnID]
        var context = ReviewTabModel.Context(
            turns: [claude3, claude4],
            conversation: Self.claude,
            isViewed: { viewed.contains($0.turnID) },
            branchBase: nil
        )
        context.worktreeTurns = WorktreeTimeline.listed([codex1, quiet1, answer, claude3, claude4])
        context.conversations = [
            Self.named(Self.claude, ordinal: 1, unviewed: 1, runningHere: true),
            Self.named(Self.codex, ordinal: nil, unviewed: 1),
            Self.named(Self.quiet, ordinal: 2, unviewed: 0),
            Self.named(Fixture.conversation("answer"), ordinal: 3, unviewed: 0)
        ]
        let tab = try ReviewTabModel.open(.unviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil).get()

        let menu = ReviewScopeMenu.make(tab, context)

        let worktree = try #require(menu.worktree)
        guard case let .worktreeUnviewedTurns(.range(range)) = worktree.option else {
            Issue.record("expected the worktree's range, got \(worktree.option)")
            return
        }
        #expect(range.turnIDs.count == 5 && range.conversations.count == 4, "the range reads through every turn")
        let counts = try #require(menu.worktreeCounts)
        #expect(counts == ReviewScopeCatalog.RangeCounts(unviewedTurns: 2, unviewedConversations: 2, viewedTurns: 3))
        #expect(counts.unviewedTurns + counts.viewedTurns == range.turnIDs.count)
        #expect(ReviewTabText.option(worktree.option, counts: counts, locale: Self.ja) == "すべての未確認（ターン 2 · 会話 2）")
        #expect(ReviewTabText.option(worktree.option, counts: counts, locale: Self.en) == "All Unviewed (2 turns · 2 conversations)")
        #expect(ReviewTabText.includesViewedTurns(counts.viewedTurns, locale: Self.ja) == "範囲に確認済みのターン 3 を含む")

        let opened = try ReviewTabModel.open(.worktreeUnviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil).get()
        #expect(ReviewTabScopeNotes.make(opened, context, locale: Self.ja).first == "範囲に確認済みのターン 3 を含む")
    }

    /// Claude's T2 started and ended in the second T1 ended (the record
    /// keeps seconds): by time alone it reads as inside a range of T1, but
    /// it is numbered after T1's end in the same conversation, so it is
    /// not, and its files are not tagged. Likewise a T0 that ended in the
    /// second a range of T1 begins is before it.
    @Test func aSingleTurnsRange_leavesOutItsConversationsTurnsTiedAtItsEnds() throws {
        let claude0 = try Self.turn(0, start: 0, end: 0)
        let claude1 = try Self.turn(1, start: 0, end: 10)
        let claude2 = try Self.turn(2, start: 10, end: 10)
        let codex1 = try Self.turn(1, of: Self.codex, start: 2, end: 10)
        let timeline = WorktreeTimeline.listed([claude0, claude1, claude2, codex1])
        let range = try #require(ReviewTurnRange(turns: [claude1]))

        #expect(ReviewScopeCatalog.turnsThrough(range, timeline: timeline).map(\.turnID) == [claude1.turnID, codex1.turnID])
        let tags = ReviewFileTags.tags(
            turns: ReviewScopeCatalog.turnsThrough(range, timeline: timeline),
            paths: { $0 == claude2.turnID ? ["b.swift"] : ["a.swift"] },
            conversations: [Self.named(Self.claude, ordinal: nil, unviewed: 1), Self.named(Self.codex, ordinal: nil, unviewed: 1)]
        )
        #expect(tags["b.swift"] == nil, "Claude's T2 is no turn of the range")
    }

    // MARK: - Mark as Viewed on another conversation's range

    /// Claude's review, every Claude turn viewed: the worktree's range holds
    /// Codex's turn alone. "Mark as Viewed" still goes through the
    /// worktree's history, which has Codex's turn, not through the tab's
    /// conversation's, which does not, where it would move nothing.
    @Test func markAsViewed_onTheWorktreesRange_ofAnotherConversationAlone_goesThroughTheWorktreesHistory() throws {
        let worktree = try Worktree()
        var context = worktree.context
        let codexOnly: Set<TurnID> = [worktree.codex1.turnID]
        context.isViewed = { !codexOnly.contains($0.turnID) }
        let tab = try ReviewTabModel.open(.worktreeUnviewedTurns, context, root: Self.root, agentPaneID: Self.pane, current: nil)
            .get()

        let codex1 = ReviewTabTurn(id: worktree.codex1.turnID, number: 1)
        let action = ReviewTabModel.markViewed(tab, context)
        #expect(action == .throughTurns([codex1]))
        #expect(try ReviewTabText.markViewedHelp(#require(action), locale: Self.en)
            == "Moves the viewed line to the end of this scope (⌘⏎)")
    }
}
