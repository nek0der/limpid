// NotificationHistoryListTests.swift
// Weir — the notification history by day and source: the order, what folds, which source a row is, and its heading.

import Foundation
import Testing
@testable import Weir

struct NotificationHistoryListTests {
    private typealias List = NotificationHistoryList
    private typealias Place = NotificationHistoryRowText.Place

    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// Noon, so an hour either way stays on the same day.
    private static let now = Date(timeIntervalSince1970: TimeInterval(1_790_000_000 / 86400 * 86400 + 43200))

    private func entry(
        _ kind: NotificationEntry.Kind = .agentFinished,
        minutesAgo: Double,
        pane: UUID? = nil,
        containerID: ContainerID? = nil,
        containerLabel: String? = nil,
        tab: String? = nil,
        isRead: Bool = true,
        agent: AgentKind? = .claude
    ) -> NotificationEntry {
        NotificationEntry.test(
            kind: kind,
            timestamp: Self.now.addingTimeInterval(-minutesAgo * 60),
            paneID: pane,
            tabTitleSnapshot: tab,
            containerLabel: containerLabel,
            containerID: containerID,
            title: "t",
            body: "b",
            isRead: isRead,
            event: kind.isFromACommand ? nil : agent.map { .stopped(agent: $0, reason: nil) }
        )
    }

    private func list(
        _ entries: [NotificationEntry],
        expanded: Set<List.SourceID> = [],
        liveStatus: @escaping (NotificationEntry) -> NotificationLiveStatus? = { _ in nil },
        canOpen: @escaping (NotificationEntry) -> Bool = { _ in true },
        place: @escaping (NotificationEntry) -> Place? = { _ in Place(name: "alpha", projectID: nil) },
        projectsInOtherWindows: Set<UUID> = []
    ) -> List {
        List(
            entries: entries,
            now: Self.now,
            calendar: Self.calendar,
            expanded: expanded,
            liveStatus: liveStatus,
            canOpen: canOpen,
            place: place,
            projectsInOtherWindows: projectsInOtherWindows
        )
    }

    private func isFold(_ item: List.Item) -> Bool {
        if case .fold = item {
            true
        } else {
            false
        }
    }

    // MARK: - Order

    @Test func sources_comeInTheOrderOfTheirNewestRow_andTheirRowsNewestFirst() {
        let alpha = UUID()
        let beta = UUID()
        let a1 = entry(minutesAgo: 1, pane: alpha)
        let b1 = entry(minutesAgo: 2, pane: beta)
        let a2 = entry(minutesAgo: 3, pane: alpha)
        // Given out of order: the list sorts them.
        let model = list([a2, b1, a1])
        #expect(model.sources.map(\.id.key.place) == [.pane(alpha), .pane(beta)])
        #expect(model.sources.first?.entries.map(\.id) == [a1.id, a2.id])
        #expect(model.items.map(\.id) == [
            .day(.today),
            .heading(model.sources[0].id), .row(a1.id), .row(a2.id),
            .heading(model.sources[1].id), .row(b1.id)
        ])
    }

    @Test func aSourceOnTwoDays_hasAHeadingOnEach() {
        let pane = UUID()
        let model = list([
            entry(minutesAgo: 10, pane: pane),
            entry(minutesAgo: 60 * 24, pane: pane),
            entry(minutesAgo: 60 * 24 * 5, pane: pane)
        ])
        #expect(model.sources.map(\.id.day) == [.today, .yesterday, .earlier])
        let days: [NotificationHistoryDay] = model.items.compactMap { item in
            if case let .day(day, _) = item {
                day
            } else {
                nil
            }
        }
        #expect(days == [.today, .yesterday, .earlier])
        let headings = model.items.compactMap {
            if case let .heading(_, isFirstOfDay) = $0 {
                isFirstOfDay
            } else {
                nil
            }
        }
        #expect(headings == [true, true, true])
    }

    @Test func aRowFromTheFuture_isPlacedAsIfItCameNow() {
        let pane = UUID()
        let future = entry(minutesAgo: -60 * 24 * 3, pane: UUID())
        let recent = entry(minutesAgo: 1, pane: pane)
        let model = list([recent, future])
        // Today, as the newest row: not on a day after today.
        #expect(model.sources.map(\.id.day) == [.today, .today])
        #expect(model.sources.first?.newest?.id == future.id)
        #expect(model.sources.last?.newest?.id == recent.id)
    }

    // MARK: - Source

    @Test func anAgentAndAShell_inOnePane_areTwoSources() {
        let pane = UUID()
        let agent = entry(.agentNeedsInput, minutesAgo: 1, pane: pane)
        let command = entry(.commandFinished, minutesAgo: 2, pane: pane)
        let alert = entry(.desktop, minutesAgo: 3, pane: pane)
        let model = list([agent, command, alert])
        #expect(model.sources.map(\.id.key) == [NotificationSourceKey(agent), NotificationSourceKey(command)])
        #expect(NotificationSourceKey(agent).speaker == .agent)
        #expect(NotificationSourceKey(command).speaker == .shell)
        #expect(model.sources[1].entries.map(\.id) == [command.id, alert.id])
        #expect(model.sources.map(\.heading.badge) == [.agent(.claude), .shell])
    }

    @Test func aRowWithNoPane_isPlacedByItsContainer_thenItsLabel() {
        let project = UUID()
        #expect(NotificationSourceKey(entry(minutesAgo: 1, containerID: .project(project), containerLabel: "app")).place
            == .container(.project(project)))
        #expect(NotificationSourceKey(entry(minutesAgo: 1, containerLabel: "app / main")).place == .label("app / main"))
        #expect(NotificationSourceKey(entry(minutesAgo: 1, containerLabel: "")).place == .none)
        // Rows of one container, no pane named, gather.
        #expect(list([entry(minutesAgo: 1, containerID: .loose), entry(minutesAgo: 2, containerID: .loose)]).sources.count == 1)
    }

    // MARK: - Heading

    @Test func aClosedPane_isSaidOnTheHeading_andItsRowsRest() throws {
        let pane = UUID()
        let rows = [entry(minutesAgo: 1, pane: pane), entry(minutesAgo: 2, pane: pane)]
        let model = list(rows, canOpen: { _ in false })
        let source = try #require(model.sources.first)
        #expect(source.heading.note == .paneClosed)
        let isClosed = source.heading.isClosed
        let areRowsClosed = source.shown.allSatisfy(\.isClosed)
        #expect(isClosed)
        #expect(areRowsClosed)
        let opensNoPane = source.shown.allSatisfy { !$0.opensPane }
        #expect(opensNoPane)
        let open = try #require(list(rows).sources.first)
        let opensPanes = open.shown.allSatisfy(\.opensPane)
        #expect(opensPanes)
        #expect(source.heading.words(locale: ja).note == "閉じたペイン")
    }

    @Test func aSourceWithNoPane_isNeverSaidToBeClosed() throws {
        for placed in [
            entry(minutesAgo: 1, containerID: .loose),
            entry(minutesAgo: 1, containerLabel: "app / main"),
            entry(minutesAgo: 1)
        ] {
            let source = try #require(list([placed], canOpen: { _ in false }).sources.first)
            #expect(source.heading.note == nil)
            #expect(!source.heading.isClosed)
        }
    }

    /// A closed pane's heading whose newest row was written before events
    /// still wears the badge an older row of it names; with no row naming
    /// it, the run's ID does.
    @Test func aHeadingsBadge_comesFromAnyRowThatNamesTheAgent() throws {
        let pane = UUID()
        let older = entry(minutesAgo: 2, pane: pane, agent: .codex)
        let newest = entry(minutesAgo: 1, pane: pane, agent: nil)
        let closed = try #require(list([newest, older], canOpen: { _ in false }).sources.first)
        #expect(closed.heading.badge == .agent(.codex))
        #expect(closed.heading.isClosed)

        let byRun = NotificationEntry.test(
            kind: .agentFinished,
            timestamp: Self.now,
            paneID: UUID(),
            title: "t",
            body: "b",
            runtimeID: "claude:\(UUID().uuidString)"
        )
        #expect(try #require(list([byRun]).sources.first).heading.badge == .agent(.claude))
        #expect(List.agent(inRuntimeID: "codex:run-1") == .codex)
        #expect(List.agent(inRuntimeID: "gemini:run-1") == nil)
        #expect(List.agent(inRuntimeID: "") == nil)
    }

    @Test func anotherWindowsProject_isNoted_unlessThePaneIsGone() throws {
        let project = UUID()
        let shownElsewhere: (NotificationEntry) -> Place? = { _ in Place(name: "api", projectID: project) }
        let open = try #require(list([entry(minutesAgo: 1, pane: UUID())], place: shownElsewhere, projectsInOtherWindows: [project])
            .sources.first)
        #expect(open.heading.note == .otherWindow)
        #expect(open.heading.words(locale: ja).note == "別のウインドウ")
        // Closed says more than which window.
        let closed = try #require(list(
            [entry(minutesAgo: 1, pane: UUID())],
            canOpen: { _ in false },
            place: shownElsewhere,
            projectsInOtherWindows: [project]
        ).sources.first)
        #expect(closed.heading.note == .paneClosed)
    }

    @Test func anAgentsHeading_namesItsTab_onlyBesideAnotherOfTheSameAgentAndPlace() {
        let first = entry(minutesAgo: 1, pane: UUID(), tab: "claude 1")
        let second = entry(minutesAgo: 2, pane: UUID(), tab: "claude 2")
        let codex = entry(minutesAgo: 3, pane: UUID(), tab: "codex", agent: .codex)
        let shell = entry(.commandFinished, minutesAgo: 4, pane: UUID(), tab: "zsh")
        let all = [first, second, codex, shell]
        #expect(list(all).sources.map { $0.heading.words(locale: en).tab } == ["claude 1", "claude 2", nil, "zsh"])
        let apart: (NotificationEntry) -> Place? = { Place(name: $0.id == first.id ? "alpha" : "beta", projectID: nil) }
        #expect(list(all, place: apart).sources.map { $0.heading.words(locale: en).tab } == [nil, nil, nil, "zsh"])
    }

    @Test func aHeadingWithNoPlace_isNamedByItsTab_withNoSeparatorBeforeIt() throws {
        let noPlace: (NotificationEntry) -> Place? = { _ in nil }
        let tabbed = try #require(list([entry(minutesAgo: 1, pane: UUID(), tab: "## Memory Writing Agent: Phase 2")], place: noPlace)
            .sources.first)
        #expect(tabbed.heading.words(locale: en) == .init(title: "## Memory Writing Agent: Phase 2", tab: nil, note: nil))
        // Neither a place nor a tab: the agent, the shell, or that the place
        // is not known.
        let agent = try #require(list([entry(minutesAgo: 1, pane: UUID())], place: noPlace).sources.first)
        #expect(agent.heading.words(locale: en).title == "Claude")
        #expect(agent.heading.spokenLabel(locale: en) == "Claude")
        let shell = try #require(list([entry(.commandFinished, minutesAgo: 1, pane: UUID())], place: noPlace).sources.first)
        #expect(shell.heading.words(locale: ja).title == "シェル")
        let unknown = try #require(list([entry(minutesAgo: 1, pane: UUID(), agent: nil)], place: noPlace).sources.first)
        #expect(unknown.heading.badge == .none)
        #expect(unknown.heading.words(locale: ja).title == "不明な場所")
        #expect(unknown.heading.words(locale: en).title == "Unknown place")
    }

    /// The shape that drew a heading as "· ## Memory Writing Agent: …": two
    /// finished turns recorded before events (no agent known) in two closed
    /// panes of one worktree, the second titled by Codex with its whole
    /// harness prompt. The tab, offered whole, took the line and left the
    /// place no width.
    @Test func aTabTitledWithAWholePrompt_isCut_andThePlaceStays() throws {
        let prompt = "## Memory Writing Agent: Phase 2 (Consolidation) You are a Memory Writing Agent. "
            + String(repeating: "Your job: consolidate raw memories and rollout summaries. ", count: 80)
        let rows = [
            entry(minutesAgo: 60 * 24, pane: UUID(), containerLabel: "weir / task/1017-1", tab: "こんにちは", agent: nil),
            entry(minutesAgo: 60 * 24 + 1, pane: UUID(), containerLabel: "weir / task/1017-1", tab: prompt, agent: nil)
        ]
        let worktree: (NotificationEntry) -> Place? = { _ in Place(name: "weir / task/1017-1", projectID: nil) }
        let model = list(rows, canOpen: { _ in false }, place: worktree)
        #expect(model.sources.count == 2)
        let words = model.sources.map { $0.heading.words(locale: ja) }
        #expect(words.map(\.title) == ["weir / task/1017-1", "weir / task/1017-1"])
        // A place keeps its project and its branch's end.
        #expect(words.allSatisfy { $0.titleTruncation == .branch })
        #expect(words.first?.tab == "こんにちは")
        let cut = try #require(words.last?.tab)
        #expect(cut.count == List.Heading.tabTitleLimit)
        #expect(cut.hasPrefix("## Memory Writing Agent: Phase 2"))
        #expect(cut.hasSuffix("…"))
        #expect(words.allSatisfy { $0.note == "閉じたペイン" })
        #expect(model.sources.map(\.heading.badge) == [.none, .none])
        // A title of only spaces and line breaks is no tab.
        #expect(List.Heading.shortTab(" \n\t ") == nil)
        #expect(List.Heading.shortTab("zsh\n") == "zsh")
    }

    @Test func aLongTabTitleThatIsAPath_keepsItsEnd() throws {
        let path = "…/sample-reviews/supervision-ui/demo-repos/alpha-worktree-long"
        let cut = try #require(List.Heading.shortTab(path))
        #expect(cut.count == List.Heading.tabTitleLimit)
        #expect(cut.hasPrefix("…"))
        #expect(cut.hasSuffix("alpha-worktree-long"))
        // A short one is left whole.
        #expect(List.Heading.shortTab("~/notes") == "~/notes")
    }

    /// The tab is cut where the strip cuts it, judged on its whole title:
    /// what `shortTab` leaves of a long path ("…ision-ui/…") no longer
    /// starts like one.
    @Test func aHeadingsTab_isCutAsItsWholeTitleReads() throws {
        let path = "…/sample-reviews/supervision-ui/demo-repos/alpha-worktree-long"
        let shell = List.Heading(badge: .none, place: "alpha", tabTitle: path, namesTab: true, note: nil).words(locale: ja)
        let tab = try #require(shell.tab)
        #expect(!SupervisionTruncation.isPathTitle(tab))
        #expect(shell.tabTruncation == .pathTitle)
        #expect(shell.titleTruncation == .branch)
        // With no place, the tab is the title, cut the same way.
        let placeless = List.Heading(badge: .none, place: "", tabTitle: path, namesTab: false, note: nil).words(locale: ja)
        #expect(placeless.titleTruncation == .pathTitle)
        let command = List.Heading(badge: .none, place: "alpha", tabTitle: "/review-pr 123 fix", namesTab: true, note: nil)
        #expect(command.words(locale: ja).tabTruncation == .name)
    }

    @Test func aHeading_isSpokenAsItsPlace_agent_tab_andNote() throws {
        let pane = UUID()
        let source = try #require(list([entry(minutesAgo: 1, pane: pane)], canOpen: { _ in false }).sources.first)
        #expect(source.heading.spokenLabel(locale: en) == "alpha, Claude, Closed Pane")
        let placed = try #require(list(
            [entry(minutesAgo: 1, pane: pane)],
            canOpen: { _ in false },
            place: { _ in Place(name: "alpha / feat/login", projectID: nil) }
        ).sources.first)
        #expect(
            placed.heading.spokenLabel(locale: en).hasPrefix("alpha, feat/login, "),
            "the place’s spaced slash is read as a list; the branch keeps its own"
        )
    }

    // MARK: - Folding

    @Test func readRows_pastThree_fold() throws {
        let pane = UUID()
        let rows = (0..<7).map { entry(minutesAgo: Double($0), pane: pane) }
        let model = list(rows)
        let source = try #require(model.sources.first)
        #expect(source.shown.map(\.entry.id) == rows.prefix(3).map(\.id))
        #expect(source.foldableCount == 4)
        #expect(model.items.last == .fold(source, count: 4, isExpanded: false))
        // Three or fewer: nothing folds.
        #expect(!list(Array(rows.prefix(3))).items.contains(where: isFold))
    }

    @Test func choosingTheFold_opensItsSource_andShowLessFoldsItAgain() throws {
        let pane = UUID()
        let other = UUID()
        let rows = (0..<19).map { entry(minutesAgo: Double($0), pane: pane) } + (20..<25).map { entry(minutesAgo: Double($0), pane: other) }
        let folded = list(rows)
        let source = try #require(folded.sources.first)
        #expect(source.foldableCount == 16)
        // Opened: every row of that source, and its fold says Show Less.
        let expanded = List.toggled(source.id, in: [])
        let open = list(rows, expanded: expanded)
        let opened = try #require(open.sources.first)
        #expect(opened.shown.count == 19)
        #expect(open.items.contains(.fold(opened, count: 16, isExpanded: true)))
        // The other source stays folded.
        #expect(open.sources[1].isExpanded == false)
        #expect(open.sources[1].shown.count == 3)
        // Show Less: folded again.
        let closed = list(rows, expanded: List.toggled(source.id, in: expanded))
        #expect(closed.sources.first?.shown.count == 3)
        #expect(try closed.items.contains(.fold(#require(closed.sources.first), count: 16, isExpanded: false)))
    }

    @Test func unreadRows_neverFold_andReadRowsFillUpToThree() throws {
        let pane = UUID()
        let read1 = entry(minutesAgo: 1, pane: pane)
        let unread1 = entry(minutesAgo: 2, pane: pane, isRead: false)
        let read2 = entry(minutesAgo: 3, pane: pane)
        let read3 = entry(minutesAgo: 4, pane: pane)
        let unread2 = entry(minutesAgo: 5, pane: pane, isRead: false)
        let source = try #require(list([read1, unread1, read2, read3, unread2]).sources.first)
        // Two unread leave room for one read row, the newest.
        #expect(source.shown.map(\.entry.id) == [read1.id, unread1.id, unread2.id])
        #expect(source.foldableCount == 2)
        // Four unread: all of them, and no read row.
        let many = (0..<4).map { entry(minutesAgo: Double($0), pane: pane, isRead: false) } + [read1]
        let crowded = try #require(list(many).sources.first)
        #expect(crowded.shown.count == 4)
        #expect(crowded.foldableCount == 1)
    }

    @Test func aRowTheAgentStillWaitsOn_neverFolds_evenRead() throws {
        let pane = UUID()
        let rows = (0..<5).map { entry(.agentNeedsInput, minutesAgo: Double($0), pane: pane) }
        let waiting = rows[4].id
        let source = try #require(list(rows, liveStatus: { $0.id == waiting ? .stillWaiting : .resolved }).sources.first)
        #expect(source.shown.map(\.entry.id) == [rows[0].id, rows[1].id, waiting])
        #expect(source.shown.last?.liveStatus == .stillWaiting)
        #expect(source.foldableCount == 2)
    }

    @Test func theKeyboard_stopsOnRowsAndFolds_notHeadings() throws {
        let pane = UUID()
        let rows = (0..<5).map { entry(minutesAgo: Double($0), pane: pane) }
        let model = list(rows)
        let source = try #require(model.sources.first)
        #expect(model.selectableIDs == rows.prefix(3).map { .row($0.id) } + [.fold(source.id)])
    }

    @Test func aSourcesGroup_opensOnItsFirstRow_andClosesOnItsLastUnlessAFoldDoes() throws {
        let pane = UUID()
        let folded = try #require(list((0..<5).map { entry(minutesAgo: Double($0), pane: pane) }).sources.first)
        #expect(folded.shown.map(\.isFirstOfSource) == [true, false, false])
        // The fold closes the group, so no row does.
        #expect(folded.shown.map(\.isLastOfSource) == [false, false, false])
        let whole = try #require(list((0..<2).map { entry(minutesAgo: Double($0), pane: UUID()) }).sources.first)
        #expect(whole.shown.map(\.isFirstOfSource) == [true])
        #expect(whole.shown.map(\.isLastOfSource) == [true])
    }

    @Test func aTabLeadsItsHeading_onlyWhenItIsNoLongerThanThePlace() {
        typealias Words = NotificationHistoryList.Heading.Words
        #expect(Words(title: "weir / feat-x", tab: "zsh", note: nil).isTabLeading)
        #expect(!Words(title: "weir", tab: "Use the Write tool to create a file", note: nil).isTabLeading)
        #expect(!Words(title: "weir", tab: nil, note: nil).isTabLeading)
    }

    @Test func aFold_isSpokenWithItsSource_andAShellsTab() throws {
        let shell = try #require(list([entry(.commandFinished, minutesAgo: 1, pane: UUID(), tab: "zsh")]).sources.first)
        #expect(shell.heading.foldName(locale: en) == "alpha, zsh")
        let agent = try #require(list([entry(minutesAgo: 1, pane: UUID(), tab: "claude")]).sources.first)
        #expect(agent.heading.foldName(locale: en) == "alpha")
    }

    @Test func aCommandsRow_knowsTheTabItsHeadingNames() throws {
        let pane = UUID()
        let newest = entry(.commandFinished, minutesAgo: 1, pane: pane, tab: "zsh")
        let older = entry(.commandFinished, minutesAgo: 2, pane: pane, tab: "server")
        let source = try #require(list([newest, older]).sources.first)
        #expect(source.shown.map(\.headingTab) == ["zsh", "zsh"])
        let agent = try #require(list([entry(minutesAgo: 1, pane: UUID(), tab: "claude")]).sources.first)
        #expect(agent.shown.first?.headingTab == nil)
    }
}
