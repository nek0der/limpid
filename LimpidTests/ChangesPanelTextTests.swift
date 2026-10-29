// ChangesPanelTextTests.swift
// Limpid — how conversations are named and counted in words: the filter, the rows' badges, the review tab's scope menu, and the
// rail's tooltip.

import Foundation
import Testing
@testable import Limpid

@Suite("Changes panel text")
struct ChangesPanelTextTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    private static let first = ConversationChoice(
        conversation: TurnSummaryFixture.conversation,
        ordinal: 1,
        unviewedCount: 1,
        liveTab: ConversationChoice.LiveTab(title: "claude", isInSession: true)
    )
    private static let second = ConversationChoice(
        conversation: TurnSummaryFixture.conversation("s2"),
        ordinal: 2,
        unviewedCount: 2
    )
    private static let codex = ConversationChoice(
        conversation: TurnSummaryFixture.conversation("c1", provider: .codex),
        ordinal: nil,
        unviewedCount: 0
    )
    private static let untitled = ConversationChoice(
        conversation: TurnSummaryFixture.conversation("s3"),
        ordinal: 3,
        unviewedCount: 0,
        liveTab: ConversationChoice.LiveTab(title: "", isInSession: true)
    )

    @Test func aNumberedConversation_isMarkedApartFromItsCount() {
        #expect(ConversationText.name(Self.second, locale: Self.english) == "Claude #2", "not Claude 2 beside its 2")
        #expect(ConversationText.name(Self.second, locale: Self.japanese) == "Claude #2")
        #expect(ConversationText.name(Self.codex, locale: Self.english) == "Codex", "the kind alone names it")
    }

    @Test func eachConversation_saysWhereItRuns() {
        #expect(ConversationText.state(Self.first, locale: Self.english) == "Running in the “claude” tab")
        #expect(ConversationText.state(Self.first, locale: Self.japanese) == "「claude」タブで実行中")
        #expect(ConversationText.state(Self.second, locale: Self.english) == "Ended")
        #expect(ConversationText.state(Self.second, locale: Self.japanese) == "終了", "a label, not a sentence")
        #expect(ConversationText.state(Self.untitled, locale: Self.english) == "Running", "no empty quotes")
        #expect(ConversationText.state(Self.untitled, locale: Self.japanese) == "実行中")
    }

    @Test func aConversationRunInAnotherWorkspace_saysWhere() {
        func run(in place: CheckoutName.Place?) -> ConversationChoice {
            ConversationChoice(
                conversation: TurnSummaryFixture.conversation("away"),
                ordinal: 4,
                unviewedCount: 0,
                liveTab: ConversationChoice.LiveTab(title: "claude", isInSession: false, checkoutPlace: place)
            )
        }

        #expect(ConversationText.state(run(in: .scratch), locale: Self.english) == "Running in the “claude” tab in Scratch")
        #expect(ConversationText.state(run(in: .scratch), locale: Self.japanese) == "スクラッチの「claude」タブで実行中")
        #expect(ConversationText.state(run(in: .named("beta")), locale: Self.english) == "Running in the “claude” tab in beta")
        #expect(ConversationText.state(run(in: .named("beta")), locale: Self.japanese) == "beta の「claude」タブで実行中")
        #expect(
            ConversationText.state(run(in: nil), locale: Self.japanese) == "「claude」タブで実行中",
            "a workspace whose project is gone is not said to be the scratch tabs"
        )
        #expect(
            ConversationText.detail(run(in: .scratch), locale: Self.japanese) == "スクラッチの「claude」タブで実行中",
            "the menus say where it runs; under Viewed, where a run elsewhere is listed, the heading says the count"
        )
    }

    /// VoiceOver reads the filter's trigger as its menu item reads: a
    /// titled conversation with its agent, so a Claude and a Codex
    /// conversation of one title read apart.
    @Test func theFilter_spokenLabel_namesATitledConversationWithItsAgent() {
        var titled = Self.codex
        titled.title = "Fix tests"
        let conversations = [Self.first, titled]

        #expect(ChangesPanelText.filterLabel(titled.conversation, among: conversations, locale: Self.english) == "Fix tests")
        #expect(ChangesPanelText.filterSpokenLabel(titled.conversation, among: conversations, locale: Self.english) == "Codex, Fix tests")
        #expect(ChangesPanelText.filterSpokenLabel(titled.conversation, among: conversations, locale: Self.japanese) == "Codex、Fix tests")
        #expect(ChangesPanelText.filterSpokenLabel(Self.first.conversation, among: conversations, locale: Self.english) == "Claude #1")
        #expect(ChangesPanelText.filterSpokenLabel(nil, among: conversations, locale: Self.english) == "All")
    }

    /// A section heading says whether it is folded and its conversation's
    /// facts in its value, which VoiceOver always reads, not in a hint.
    @Test func theSectionValue_saysTheFoldAndTheCount() {
        #expect(
            ConversationText.sectionValue(Self.first, isCollapsed: true, locale: Self.english)
                == "Collapsed, 1 unviewed turn, Running in the “claude” tab"
        )
        #expect(ConversationText.sectionValue(Self.second, isCollapsed: false, locale: Self.japanese) == "展開済み、未確認のターン 2、終了")
    }

    @Test func theTooltip_countsAsTheRailDoes_andVoiceOverReadsTheTurns() {
        #expect(ConversationText.help(Self.first, locale: Self.english) == "Claude #1 · 1 unviewed · Running in the “claude” tab")
        #expect(ConversationText.help(Self.second, locale: Self.japanese) == "Claude #2 · 未確認 2 · 終了")
        #expect(ConversationText.value(Self.first, locale: Self.english) == "1 unviewed turn, Running in the “claude” tab")
        #expect(ConversationText.value(Self.second, locale: Self.japanese) == "未確認のターン 2、終了")
    }

    // MARK: - The filter and the rows

    @Test func theFilter_namesItsHeading_itsDefault_andTheConversationShown() {
        let conversations = [Self.first, Self.second, Self.codex]

        #expect(ChangesPanelText.filterHeading(locale: Self.english) == "Conversation")
        #expect(ChangesPanelText.filterHeading(locale: Self.japanese) == "会話")
        #expect(ChangesPanelText.filterLabel(nil, among: conversations, locale: Self.english) == "All")
        #expect(ChangesPanelText.filterLabel(nil, among: conversations, locale: Self.japanese) == "すべて")
        #expect(ChangesPanelText.filterLabel(Self.second.conversation, among: conversations, locale: Self.english) == "Claude #2")
        #expect(ChangesPanelText.filterHelp(nil, among: conversations, locale: Self.japanese) == "すべての会話のターンを表示します")
        #expect(ChangesPanelText.filterHelp(nil, among: conversations, locale: Self.english) == "Shows every conversation’s turns")
        #expect(
            ChangesPanelText.filterHelp(Self.first.conversation, among: conversations, locale: Self.english)
                == "Claude #1 · 1 unviewed · Running in the “claude” tab"
        )
        #expect(ConversationText.section(.running, locale: Self.japanese) == "実行中")
        #expect(ConversationText.section(.unviewed, locale: Self.japanese) == "未確認")
        #expect(ConversationText.section(.viewed, locale: Self.japanese) == "確認済み")
        #expect(ConversationText.section(.unviewed, locale: Self.english) == "Unviewed")
        // The menu's second line is the count with its unit, after the tab
        // where it has one to say. A tab with no place says nothing of it.
        #expect(ConversationText.detail(Self.first, locale: Self.japanese) == "未確認 1")
        #expect(ConversationText.detail(Self.second, locale: Self.english) == "No tab · 2 unviewed")
        #expect(ConversationText.detail(Self.untitled, locale: Self.japanese).isEmpty, "no 未確認 0, no 実行中 under 実行中")
    }

    /// 2026-10-12 21:06 UTC, and a minute later.
    private static let evening = Date(timeIntervalSince1970: 1_791_839_160)
    private static let utc = TimeZone(identifier: "UTC") ?? .current

    /// A conversation this session runs leads with its tab's place, as the
    /// pane strip counts the tabs, so the menu says which tab to look in.
    @Test func detail_liveTabInSession_leadsWithTabPosition() {
        let choice = ConversationChoice(
            conversation: TurnSummaryFixture.conversation,
            title: "Review the fork",
            ordinal: nil,
            unviewedCount: 3,
            liveTab: ConversationChoice.LiveTab(title: "claude", isInSession: true, position: 3),
            lastActivity: Self.evening
        )
        let now = Self.evening.addingTimeInterval(60)

        #expect(
            ChangesPanelFixture.plainSpaces(ConversationText.detail(choice, now: now, locale: Self.english, timeZone: Self.utc))
                == "Tab 3 · 9:06 PM · 3 unviewed"
        )
        #expect(ConversationText.detail(choice, now: now, locale: Self.japanese, timeZone: Self.utc) == "タブ 3 · 21:06 · 未確認 3")
    }

    /// One no pane runs any more has no tab to name, and says so first; one
    /// run in another workspace names where, as the tooltip does.
    @Test func detail_endedConversation_saysNoTab() {
        let ended = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("s2"),
            title: "Fix tests",
            ordinal: nil,
            unviewedCount: 0,
            lastActivity: Self.evening
        )
        let now = Self.evening.addingTimeInterval(60)
        var away = ended
        away.liveTab = ConversationChoice.LiveTab(title: "claude", isInSession: false, checkoutPlace: .named("beta"))

        #expect(
            ChangesPanelFixture.plainSpaces(ConversationText.detail(ended, now: now, locale: Self.english, timeZone: Self.utc))
                == "No tab · 9:06 PM",
            "no 0 unviewed"
        )
        #expect(ConversationText.detail(ended, now: now, locale: Self.japanese, timeZone: Self.utc) == "タブなし · 21:06")
        #expect(
            ConversationText.detail(away, now: now, locale: Self.japanese, timeZone: Self.utc) == "beta の「claude」タブで実行中 · 21:06"
        )
    }

    /// The card's tooltip names its conversation as the menus do, and
    /// VoiceOver says the kind before the title, which the badge shows.
    @Test func turnHelp_titledConversation_namesItByTitle() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = "s2"
        extras.promptHead = "Save the order setting"
        let turn = try TurnSummaryFixture.turn("T4-s2", changes: TurnSummaryFixture.changedFiles, number: 4, extras: extras)
        var row = ChangesPanelModel.Row(turn: turn, status: .unviewed, isViewed: false, isSelectable: true, action: .markViewedThrough)
        row.conversation = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("s2"),
            title: "Review the fork",
            ordinal: nil,
            unviewedCount: 1
        )

        #expect(ChangesPanelText.help(row, locale: Self.english, timeZone: Self.utc).contains("\nTurn of Review the fork\n"))
        #expect(ChangesPanelText.help(row, locale: Self.japanese, timeZone: Self.utc).contains("\nReview the fork のターン\n"))
        #expect(ChangesPanelText.rowSpoken(row, locale: Self.english, timeZone: Self.utc).hasPrefix("Turn 4 of Claude, Review the fork, "))
        #expect(ChangesPanelText.rowSpoken(row, locale: Self.japanese, timeZone: Self.utc).hasPrefix("Claude、Review the fork のターン 4、"))
    }

    /// Fourteen ended conversations list the newest first, each line
    /// saying it has no tab, when it last did something, and its count;
    /// the same line heads each in the review's scope menu.
    @Test func manyConversations_listNewestFirst_eachSayingWhenItLastWorked() {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let now = Date(timeIntervalSince1970: 1_791_800_000) // 2026-10-12 10:13:20 UTC
        let conversations = (1...14).map { number in
            ConversationChoice(
                conversation: TurnSummaryFixture.conversation("s\(number)"),
                ordinal: number,
                unviewedCount: number % 3,
                latestPrompt: TurnPrompt(head: "Save the order setting for list \(number)"),
                lastActivity: now.addingTimeInterval(TimeInterval(-60 * ((number * 5) % 14)))
            )
        }

        let ordered = ConversationChoice.byLatestActivity(conversations)
        #expect(ordered.map(\.lastActivity) == conversations.map(\.lastActivity).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
        #expect(ordered.first?.ordinal == 14, "the latest activity first, whatever its number")

        let line = ConversationText.detail(conversations[3], now: now, locale: Self.japanese, timeZone: utc)
        #expect(line == "タブなし · 10:07 · 未確認 1", "no tab, when, and its count with its unit")
        #expect(!line.contains("終了"), "an ended conversation's section says it ended")
        // Under "Viewed" the heading says the count: the line does not.
        #expect(conversations[2].section == .viewed)
        #expect(
            ConversationText.detail(conversations[2], now: now, locale: Self.japanese, timeZone: utc) == "タブなし · 10:12",
            "no 未確認 0 under 確認済み"
        )
        let yesterday = ConversationText.activityTime(now.addingTimeInterval(-86400), now: now, locale: Self.english, timeZone: utc)
        #expect(yesterday.contains("Oct 11"), "another day says its date")
        #expect(
            ConversationText.value(conversations[3], now: now, locale: Self.japanese, timeZone: utc)
                == "Save the order setting for list 4、10:07、未確認のターン 1、終了",
            "VoiceOver hears the prompt whole"
        )
    }

    @Test func aRowsBadge_namesWhoseTurnItIs_withoutSayingWhoWroteIt() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = "s2"
        extras.promptHead = "Save the order setting"
        extras.finishedAt = "2026-10-12T00:03:05Z"
        let turn = try TurnSummaryFixture.turn("T4-s2", changes: TurnSummaryFixture.changedFiles, number: 4, extras: extras)
        var row = ChangesPanelModel.Row(turn: turn, status: .unviewed, isViewed: false, isSelectable: true, action: .markViewedThrough)
        row.conversation = Self.second
        let utc = try #require(TimeZone(identifier: "UTC"))

        #expect(ChangesPanelText.turnOf(Self.second, locale: Self.english) == "Turn of Claude #2")
        #expect(ChangesPanelText.turnOf(Self.second, locale: Self.japanese) == "Claude #2 のターン")
        #expect(ChangesPanelText.help(row, locale: Self.japanese, timeZone: utc)
            == "T4 をレビューで開く\nClaude #2 のターン\nSave the order setting\n2 ファイル +3 −1\n開始 0:00 · 終了 0:03")
        #expect(ChangesPanelText.rowSpoken(row, locale: Self.japanese, timeZone: utc)
            == "Claude #2 のターン 4、Save the order setting、未確認、2 ファイル +3 −1、0:00")
        #expect(ChangesPanelFixture.plainSpaces(ChangesPanelText.rowSpoken(row, locale: Self.english, timeZone: utc))
            == "Turn 4 of Claude #2, Save the order setting, Unviewed, 2 files +3 −1, 12:00 AM")
    }

    @Test func aRowsReply_endsItsTooltipAndItsSentence() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.promptHead = "Add the tests"
        extras.replyHead = "Added two tests."
        extras.finishedAt = "2026-10-12T00:03:05Z"
        let turn = try TurnSummaryFixture.turn("T4", number: 4, extras: extras)
        let row = ChangesPanelModel.Row(turn: turn, status: .viewed, isViewed: true, isSelectable: true, action: .markUnviewedFrom)
        let utc = try #require(TimeZone(identifier: "UTC"))

        #expect(ChangesPanelText.help(row, locale: Self.japanese, timeZone: utc).hasSuffix("終了 0:03\n\n返答：Added two tests."))
        #expect(ChangesPanelFixture.plainSpaces(ChangesPanelText.rowSpoken(row, locale: Self.english, timeZone: utc))?
            .hasSuffix("12:00 AM, Reply: Added two tests.") == true)
    }

    @Test func theFoldAndTheMoves_sayWhatTheyDo() {
        let fold = ChangesPanelModel.Fold(count: 12)

        #expect(ChangesPanelText.fold(fold, isUnfolded: false, locale: Self.english) == "Show 12 viewed turns")
        #expect(ChangesPanelText.fold(ChangesPanelModel.Fold(count: 1), isUnfolded: false, locale: Self.english) == "Show 1 viewed turn")
        #expect(ChangesPanelText.fold(fold, isUnfolded: false, locale: Self.japanese) == "確認済み 12 ターンを表示")
        #expect(ChangesPanelText.fold(fold, isUnfolded: true, locale: Self.english) == "Hide viewed turns")
        #expect(ChangesPanelText.fold(fold, isUnfolded: true, locale: Self.japanese) == "確認済みのターンを非表示にする")
        #expect(ChangesPanelText.moveAcrossHelp(.markViewedThrough, locale: Self.japanese) == "ほかの会話の、このターンまでに終了したターンも確認済みにします")
        #expect(ChangesPanelText.moveAcrossHelp(.markViewedThrough, locale: Self.english)
            == "Also marks the other conversations’ turns that ended by the time this one did as viewed")
        #expect(ChangesPanelText.moveAcrossHelp(.markUnviewedFrom, locale: Self.japanese) == "ほかの会話の、この時点以降のターンも未確認にします")
        #expect(
            ChangesPanelText.action(.markViewedThrough, locale: Self.english) == "Mark as Viewed up to Here",
            "one line: the short label"
        )
        #expect(ChangesPanelText.action(.markViewedThrough, movesOtherLines: true, locale: Self.english)
            == "Mark All Conversations as Viewed up to Here")
        // One conversation: the decision bar's name, as the two read the
        // same turns. Two or more: the panel's says it reads all of them.
        #expect(ChangesPanelText.reviewUnviewed(isAcrossConversations: false, locale: Self.english) == "Review Unviewed")
        #expect(ChangesPanelText.reviewUnviewed(isAcrossConversations: false, locale: Self.japanese) == "未確認をレビュー")
        #expect(ChangesPanelText.reviewUnviewed(isAcrossConversations: true, locale: Self.english) == "Review All Unviewed")
        #expect(ChangesPanelText.reviewUnviewed(isAcrossConversations: true, locale: Self.japanese) == "すべての未確認をレビュー")
        #expect(ChangesPanelText.reviewUnviewedHelp(locale: Self.japanese) == "ワークツリーの未確認のターンをレビューで開きます")
        #expect(ToastKind.markedViewedInConversations(through: 4, conversation: "Claude #4", others: 1).offersUndo)
    }

    @Test func theRailsTooltip_breaksItsTotalDownByConversation() {
        let agents = [Self.first, Self.second, Self.codex]

        #expect(
            ChangesPanelText.railHelp(shortcut: "⌥⌘I", unviewed: 3, agents: agents, locale: Self.english)
                == "Changes (⌥⌘I) · 3 unviewed\nClaude #1 · 1 unviewed\nClaude #2 · 2 unviewed\nCodex · 0 unviewed"
        )
        #expect(
            ChangesPanelText.railHelp(shortcut: nil, unviewed: 3, agents: agents, locale: Self.japanese)
                == "変更 · 未確認 3\nClaude #1 · 未確認 1\nClaude #2 · 未確認 2\nCodex · 未確認 0",
            "an agent with none keeps its line"
        )
        #expect(
            ChangesPanelText.railHelp(shortcut: "⌥⌘I", unviewed: 1, agents: [], locale: Self.english) == "Changes (⌥⌘I) · 1 unviewed",
            "one agent's count is the total"
        )
        #expect(ChangesPanelText.railHelp(shortcut: "⌥⌘I", unviewed: 0, agents: agents, locale: Self.english) == "Changes (⌥⌘I)")
    }

    @Test func groupingLabels_areLocalized() {
        #expect(ChangesPanelText.grouping(.timeline, locale: Self.english) == "Timeline")
        #expect(ChangesPanelText.grouping(.byConversation, locale: Self.english) == "By Conversation")
        #expect(ChangesPanelText.grouping(.timeline, locale: Self.japanese) == "時系列")
        #expect(ChangesPanelText.grouping(.byConversation, locale: Self.japanese) == "会話別")
        #expect(ChangesPanelText.groupingLabel(locale: Self.english) == "Arrange Turns")
        #expect(ChangesPanelText.groupingLabel(locale: Self.japanese) == "ターンの並べ方")
    }
}
