// ChangesPanelView.swift
// Weir — the changes panel: the worktree's turns as one timeline, with each row's viewed state, beside the terminal.

import SwiftUI

/// The changes panel: the window's session read as a table of contents.
/// Its head counts the worktree's turns and opens the unviewed ones in the
/// review; its filter narrows the timeline to one conversation; each row is
/// one turn, with its conversation's badge, opening it there; the lines
/// move only from the rows' own buttons, the decision bar, and the review's
/// band. It shows no diff.
struct ChangesPanelView: View {
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(\.restoreHandler) private var restore
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let content = ChangesPanelActions.content(window: window, stores: state.changesPanelStores)
        // No fill of its own: it stands on the window's surface for the
        // panel, which fills it as it does the sidebar and the session.
        VStack(alignment: .leading, spacing: 0) {
            // No rule under the head, as there is none under the sidebar's
            // heading or the session header: a surface's rules close what
            // stands at its foot, not its heading.
            head(content)
            // Shown until the restore is undone or work goes on from it,
            // wherever the person was when it ran.
            if let restore, let journal = ChangesPanelActions.restoreRecord(window: window, stores: state.changesPanelStores) {
                RestoreRecordBox(journal: journal, handler: restore)
            }
            if let empty = ChangesPanelText.empty(content) {
                // Centered in the room the turns would take, over Commit
                // & PR, which keeps its place at the foot.
                SupervisionEmptyState(empty, size: .regular)
            } else if case let .turns(list) = content {
                // We keep one list per worktree: another worktree of the
                // project is another list, which folds again and opens on its
                // own unviewed turns, even where the filter (All) is the same.
                // So is the other grouping, chosen by the person, whose
                // sections open again as it is drawn anew. Keyed on that
                // choice, not on whether the model made sections: a second
                // conversation's first turn adds sections within the same
                // list rather than resetting its place and folds.
                ChangesTurnList(list: list, state: state)
                    .id(ListIdentity(container: window.selection.activeContainerID, grouping: window.selection.changesPanelGrouping))
            }
            // Below the turns, where the work ends; only for a Git
            // work tree, which is all it can speak of.
            if ChangesPanelActions.root(window: window, stores: state.changesPanelStores) != nil {
                rule
                CommitAndPRSection(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Counted again when a turn starts or ends or is deleted, when a
        // mark moves the unviewed range the totals count, as Weir
        // comes to the front, and every 10 seconds while the panel shows:
        // a person's edit since the last turn is news no record announces.
        .task(id: RefreshKey(
            folder: ChangesPanelActions.folder(window: window, stores: state.changesPanelStores),
            turns: ChangesPanelActions.turnsKey(window: window, stores: state.changesPanelStores),
            deleted: state.viewedLines.deletedTurns,
            totals: ChangesPanelActions.totalsComparison(window: window, stores: state.changesPanelStores),
            isWatching: ChangesPanelActions.isWatching(window: window, stores: state.changesPanelStores)
        )) {
            guard ChangesPanelActions.isWatching(window: window, stores: state.changesPanelStores) else { return }
            var isFirst = true
            while !Task.isCancelled {
                await ChangesPanelActions.refresh(window: window, stores: state.changesPanelStores, isRefreshing: isFirst)
                isFirst = false
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Changes"))
    }

    private struct ListIdentity: Hashable {
        let container: ContainerID
        let grouping: ChangesPanelGrouping
    }

    private struct RefreshKey: Equatable {
        let folder: URL?
        let turns: [ChangesPanelActions.TurnsKey]
        let deleted: [String: [DateInterval]]
        /// The unviewed range the totals count, which a mark moves.
        let totals: WorktreeChanges.Comparison?
        let isWatching: Bool
    }

    private var rule: some View {
        SupervisionTokens.line.color
            .frame(height: Layout.changesPanelRuleWidth)
            .accessibilityHidden(true)
    }

    private func head(_ content: ChangesPanelModel.Content) -> some View {
        // No counts without a worktree, nor without an agent.
        let listed: ChangesPanelModel.TurnList? = if case let .turns(list) = content, list.hasAgents {
            list
        } else {
            nil
        }
        let summary = listed.map { ChangesPanelText.headSummary($0, locale: locale) }
        let spokenSummary = listed.map { ChangesPanelText.spokenHeadSummary($0, locale: locale) }
        let conversations: [ConversationChoice] = if case let .turns(list) = content {
            list.conversations
        } else {
            []
        }
        return VStack(alignment: .leading, spacing: Layout.changesHeadSpacing) {
            ChangesPanelHeadLayout(
                summary: summary,
                spokenSummary: spokenSummary,
                usage: listed?.usage,
                hasFilter: !conversations.isEmpty
            ) {
                title
            } buttons: {
                headButtons(content)
            } filter: {
                if case let .turns(list) = content {
                    ChangesConversationFilter(filter: list.filter, conversations: conversations) { conversation in
                        ChangesPanelActions.select(conversation, window: window, session: state.session)
                    }
                    // Only where the model would make sections: the
                    // switch must change the list it offers to change.
                    if list.canGroup {
                        groupingSwitch
                    }
                }
            }
            if case let .turns(list) = content {
                if list.showsTotals {
                    // One fact to a line, each kept to it; a narrower
                    // panel cuts a line's end rather than wrap it.
                    VStack(alignment: .leading, spacing: Layout.changesTotalsLineSpacing) {
                        ForEach(Array(ChangesPanelText.totalsLines(list, locale: locale).enumerated()), id: \.offset) { _, line in
                            ReceiptRunsText(runs: line, size: .row)
                                .lineLimit(1)
                        }
                    }
                    // Read as one, as it was one line.
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(Layout.changesHeadInsets)
    }

    /// "Timeline | By Conversation": how the window lists the turns.
    private var groupingSwitch: some View {
        let binding = Binding(
            get: { window.selection.changesPanelGrouping },
            set: { ChangesPanelActions.setGrouping($0, window: window, session: state.session) }
        )
        let label = ChangesPanelText.groupingLabel(locale: locale)
        return SupervisionSegmentedPicker(
            Text(verbatim: label),
            selection: binding,
            options: [ChangesPanelGrouping.timeline, .byConversation].map { grouping in
                .init(grouping, Text(verbatim: ChangesPanelText.grouping(grouping, locale: locale)))
            },
            isCompact: true
        )
        .fixedSize()
        .help(Text(verbatim: label))
    }

    private var title: some View {
        Text("Changes")
            .font(WeirFont.Supervision.surfaceHeading)
            .foregroundStyle(SupervisionTokens.text.color)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func headButtons(_ content: ChangesPanelModel.Content) -> some View {
        if case let .turns(list) = content, list.hasAgents {
            // The worktree's unviewed turns, every conversation's as one
            // comparison: on whenever any conversation has one.
            let name = ChangesPanelText.reviewUnviewed(isAcrossConversations: list.conversations.count > 1, locale: locale)
            Button(name) {
                ChangesPanelActions.reviewUnviewed(window: window, stores: state.changesPanelStores)
            }
            .buttonStyle(.supervisionSecondary(size: .compact))
            .disabled(list.unviewedCount == 0)
            .help(Text(verbatim: ChangesPanelText.reviewUnviewedHelp(locale: locale)))
            .accessibilityLabel(Text(verbatim: name))
        }
        Button {
            ChangesPanelActions.toggle(window, session: state.session)
        } label: {
            DismissGlyph(size: .micro, weight: .semibold)
                .frame(height: Layout.secondaryButtonCompactHeight)
        }
        .buttonStyle(.supervisionIcon)
        .help(Text(verbatim: ShortcutHelpText.make(
            name: "Close Changes",
            shortcut: settings.settings.keyboard.shortcut(for: .toggleChangesPanel)?.displayString,
            locale: locale
        )))
        .accessibilityLabel(Text("Close Changes"))
    }
}

/// Where the panel's head puts the counts ("14 turns · 10 unviewed"). A
/// pure function of whether the filter is there, and of nothing the
/// counts say.
enum ChangesSummaryPlacement: Equatable {
    /// Beside the title while they fit whole; else on a
    /// line of their own, since the unviewed count is what the head is
    /// for and is never cut.
    case besideWhileItFits
    /// On a line of their own whatever their length: the counts change
    /// as turns end ("12 turns · 3 unviewed", "13 turns · 4 unviewed");
    /// near the panel's narrowest that moved them on and off the title's
    /// line, and the filter under them moved a line up or down under the
    /// pointer.
    case ownLine

    static func placement(hasFilter: Bool) -> Self {
        hasFilter ? .ownLine : .besideWhileItFits
    }
}

/// The changes panel's head laid out from its parts: the title with the
/// buttons, the counts where `ChangesSummaryPlacement` puts them, and the
/// conversation filter under them when there is one.
struct ChangesPanelHeadLayout<Title: View, Buttons: View, Filter: View>: View {
    /// `nil` without a worktree or without an agent, where there are no counts.
    let summary: String?
    /// `summary` as VoiceOver says it; `nil` to say `summary` as it reads.
    var spokenSummary: String?
    /// What the turns used, for the tooltip.
    var usage: TurnUsage?
    let hasFilter: Bool
    @ViewBuilder var title: () -> Title
    @ViewBuilder var buttons: () -> Buttons
    @ViewBuilder var filter: () -> Filter
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.changesHeadSpacing) {
            switch ChangesSummaryPlacement.placement(hasFilter: hasFilter) {
            case .besideWhileItFits:
                ViewThatFits(in: .horizontal) {
                    titleLine {
                        title()
                        summaryText
                        Spacer(minLength: WeirLayout.Supervision.spaceS)
                        buttons()
                    }
                    titleOverSummary
                }
            case .ownLine:
                titleOverSummary
            }
            if hasFilter {
                filter()
            }
        }
    }

    /// The title's line: the surfaces' heading line, run out past the
    /// head's inset on its trailing side by the × button's own room, so the
    /// ×'s glyph ends where the sidebar's ＋ does
    /// (`surfaceHeadingButtonTrailingInset`). The lines under it keep the
    /// head's inset.
    private func titleLine(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: WeirLayout.Supervision.spaceS, content: content)
            .frame(height: Layout.surfaceHeadingLineHeight)
            .padding(.trailing, Layout.surfaceHeadingButtonTrailingInset - Layout.changesHeadInsets.trailing)
    }

    private var titleOverSummary: some View {
        VStack(alignment: .leading, spacing: Layout.changesHeadSpacing) {
            titleLine {
                title()
                Spacer(minLength: WeirLayout.Supervision.spaceS)
                buttons()
            }
            summaryText
        }
    }

    @ViewBuilder
    private var summaryText: some View {
        if let summary {
            Text(verbatim: summary)
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize()
                .help(Text(verbatim: ChangesPanelText.summaryHelp(usage: usage, locale: locale)))
                .accessibilityLabel(Text(verbatim: spokenSummary ?? AgentStatusText.spoken(summary, locale: locale)))
        }
    }
}

/// "Conversation [All ⌄]": the filter that narrows the timeline to one
/// conversation, when the worktree has two or more. One pop-up
/// whatever the panel's width: its menu lists every conversation on two
/// lines, the name over its count and where it runs, under the headings
/// Running, Unviewed, and Viewed, so a worktree of many conversations
/// reads the same at 300pt as at 520pt. An AppKit menu
/// (`PopUpMenuButton`), whose trigger shows a tooltip and whose items
/// carry a second line.
struct ChangesConversationFilter: View {
    /// The conversation shown, `nil` for all.
    let filter: ConversationKey?
    let conversations: [ConversationChoice]
    let onSelect: (ConversationKey?) -> Void
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let shown = conversations.first { $0.conversation == filter }
        let label = ChangesPanelText.filterLabel(filter, among: conversations, locale: locale)
        HStack(spacing: WeirLayout.Supervision.spaceS) {
            // The one heading a menu has, beside it rather than in
            // the label, so the label is the choice alone.
            Text(verbatim: ChangesPanelText.filterHeading(locale: locale))
                .font(.supervision(.caption))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize()
                .accessibilityHidden(true)
            PopUpMenuButton(
                verbatim: ChangesPanelText.filterHeading(locale: locale),
                help: ChangesPanelText.filterHelp(filter, among: conversations, locale: locale),
                value: ChangesPanelText.filterSpokenLabel(filter, among: conversations, locale: locale)
            ) {
                entries
            } label: {
                BorderedMenuTriggerLabel {
                    if let shown {
                        let badge = SessionRowFact.Badge.agent(shown.conversation.provider)
                        ConversationIdentityLead(identity: shown.identity) {
                            SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .regular)
                        }
                    }
                    Text(verbatim: label)
                        .font(.supervision(.row, weight: .medium))
                        .foregroundStyle(SupervisionTokens.text.color)
                        .lineLimit(1)
                        .supervisionTruncation(.name)
                }
            }
            // Its height only: a title has no length cap, so the label is
            // offered what the panel's line has left and cuts the name at
            // its end, never running past the panel's edge. The tooltip
            // and VoiceOver say it whole.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "All", then each section's heading and its conversations, the
    /// latest activity first within each, each with its badge before
    /// its name, as the rows and the review's scope menu show it.
    private var entries: [PopUpMenuEntry] {
        let locale = locale
        var entries: [PopUpMenuEntry] = [
            .item(PopUpMenuItem(verbatim: ChangesPanelText.filterAll(locale: locale), isChecked: filter == nil) {
                onSelect(nil)
            })
        ]
        for section in ConversationChoice.Section.allCases {
            let members = ConversationChoice.byLatestActivity(conversations.filter { $0.section == section })
            guard !members.isEmpty else { continue }
            entries.append(.header(ConversationText.section(section, locale: locale)))
            for choice in members {
                entries.append(.item(ConversationMenuItem.make(
                    choice: choice,
                    isChecked: choice.conversation == filter,
                    locale: locale
                ) {
                    onSelect(choice.conversation)
                }))
            }
        }
        return entries
    }
}

/// The turns, oldest at the top as in the terminal, the viewed ones at the
/// top folded, and "Viewed up to here" under the last once every row is
/// viewed; or, grouped by conversation, a section per conversation, each
/// with its own fold and line (`ChangesTurnSection`). Opens on the latest
/// unviewed turn.
private struct ChangesTurnList: View {
    let list: ChangesPanelModel.TurnList
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// This is true once the person opened the fold, which then leaves
    /// the list: there is no line to fold it again. The list folds again
    /// as it is drawn anew (another worktree, which the panel gives a list
    /// of its own, the other grouping chosen, or the panel opened again).
    @State private var isUnfolded = false
    /// The sections the person closed, and those whose fold they opened, in
    /// the list grouped by conversation. Never saved: like the fold, they
    /// are reset as the list is drawn anew.
    @State private var collapsedSections: Set<ConversationKey> = []
    @State private var unfoldedSections: Set<ConversationKey> = []
    /// The card that takes the keyboard and VoiceOver as it appears: the
    /// first a fold opened from the keyboard or VoiceOver showed, since the
    /// fold's line, which had them, leaves the list. Cleared once taken.
    @State private var focusOnAppear: TurnID?

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let shownInReview = ChangesPanelModel.turnsShownInReview(window.review)
        let selected = ProjectScrollMemory.selectedTurn(
            rows: list.rows.map(\.id),
            shownInReview: shownInReview,
            opensOn: list.scrollTarget
        )
        // The rows in the order drawn, the sections one after another, less
        // what a fold or a closed section hides: what the list remembers
        // its place among, and what the keyboard moves through.
        let hidden = if let sections = list.sections {
            ChangesPanelModel.hiddenRows(
                sections: sections,
                collapsed: collapsedSections,
                unfolded: unfoldedSections,
                shownInReview: shownInReview
            )
        } else {
            ChangesPanelModel.hiddenRows(
                fold: list.fold,
                isUnfolded: isUnfolded,
                shownInReview: shownInReview,
                rows: list.rows
            )
        }
        let drawn = ChangesPanelModel.drawnRows(list.rows, hidden: hidden)
        // Once for the list: each card reading the panes itself would redraw
        // every card on any change to the session's panes.
        let withTab = ChangesPanelActions.conversationsWithTab(window: window, stores: state.changesPanelStores)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // The list's very top, above its inset, which a list put
                    // back on its first turn goes to.
                    Color.clear
                        .frame(height: 0)
                        .id(ListTop.mark)
                        .accessibilityHidden(true)
                    LazyVStack(alignment: .leading, spacing: Layout.turnCardSpacing) {
                        if let sections = list.sections {
                            ForEach(sections) { section in
                                sectionRows(
                                    section,
                                    isFirst: section.id == sections.first?.id,
                                    hidden: hidden,
                                    shownInReview: shownInReview,
                                    withTab: withTab
                                )
                            }
                        } else {
                            timelineRows(hidden: hidden, shownInReview: shownInReview, withTab: withTab)
                        }
                    }
                    // The turns are what the list reports its place by.
                    .scrollTargetLayout()
                    .modifier(SharedTurnFactColumns())
                    .environment(\.turnNumberDigits, list.turnNumberDigits)
                    .padding(.horizontal, Layout.changesListInset)
                    .padding(.bottom, Layout.changesListInset)
                    .padding(.top, Layout.changesListTopInset)
                }
            }
            .onAppear {
                guard !restoreScroll(selected: selected, drawn: drawn, proxy: proxy), let target = list.scrollTarget else { return }
                proxy.scrollTo(target, anchor: .bottom)
            }
            // Another conversation's rows are another list; it opens where
            // that one has its own unviewed turns. The window switching to
            // its project brings the list back instead, the filter with it,
            // in the one handler, so the two never take turns at the list.
            .onChange(of: Place(conversation: list.filter, restore: window.scrollRestore?.id)) { old, new in
                guard !restoreScroll(selected: selected, drawn: drawn, proxy: proxy), old.conversation != new.conversation,
                      let target = list.scrollTarget
                else { return }
                proxy.scrollTo(target, anchor: .bottom)
            }
            // Where the list stands, kept beside the window so its project
            // keeps it as the window leaves (`WindowRegistry.scrollMemories`):
            // the turn at the top, reported to the window rather than held
            // in the view, whose body would build every row again each time
            // a turn passed the top; and the selected turn, which can change
            // without a scroll.
            .onScrollTargetVisibilityChange(idType: TurnID.self) { visible in
                let shown = Set(visible)
                report(top: list.rows.first { shown.contains($0.id) }?.id, selected: selected)
            }
            .onChange(of: selected) { _, selected in
                window.scrollPlace.changesSelected = selected
            }
        }
    }

    private struct Place: Equatable {
        let conversation: ConversationKey?
        let restore: UUID?
    }

    /// One conversation's section of the list grouped by conversation.
    private func sectionRows(
        _ section: ChangesPanelModel.Section,
        isFirst: Bool,
        hidden: Set<TurnID>,
        shownInReview: Set<TurnID>,
        withTab: Set<ConversationKey>
    ) -> some View {
        ChangesTurnSection(
            section: section,
            isFirst: isFirst,
            isCollapsed: collapsedSections.contains(section.id),
            hidden: hidden,
            shownInReview: shownInReview,
            offersShowTab: withTab.contains(section.id),
            conversations: list.conversations,
            state: state,
            focusOnAppear: focusOnAppear,
            tookFocus: { focusOnAppear = nil },
            toggleCollapse: { toggle(section.id, in: $collapsedSections) },
            openFold: { hadFocus in
                open(revealing: section.rows.first?.id, hadFocus: hadFocus) {
                    _ = unfoldedSections.insert(section.id)
                }
            }
        )
    }

    /// The timeline's fold, its cards, and its line.
    @ViewBuilder
    private func timelineRows(hidden: Set<TurnID>, shownInReview: Set<TurnID>, withTab: Set<ConversationKey>) -> some View {
        if let fold = ChangesPanelModel.foldLine(list.fold, rows: list.rows, hidden: hidden) {
            ChangesFoldLine(title: ChangesPanelText.fold(fold, locale: locale)) { hadFocus in
                open(revealing: list.rows.first?.id, hadFocus: hadFocus) {
                    isUnfolded = true
                }
            }
        }
        ForEach(list.rows) { row in
            if !hidden.contains(row.id) {
                ChangesTurnRow(
                    row: row,
                    conversations: list.conversations,
                    isShownInReview: shownInReview.contains(row.id),
                    offersShowTab: withTab.contains(row.turn.conversation),
                    showsConversation: true,
                    state: state,
                    takesFocus: focusOnAppear == row.id,
                    tookFocus: { focusOnAppear = nil }
                )
                .id(row.id)
            }
        }
        ViewedLineRow(line: list.line, state: state)
    }

    /// Opens a fold (`unfold`), and where its line had the keyboard or
    /// VoiceOver, hands them to the first card it shows (`revealing`).
    private func open(revealing first: TurnID?, hadFocus: Bool, unfold: () -> Void) {
        if hadFocus {
            focusOnAppear = first
        }
        withAnimation(reduceMotion ? nil : WeirMotion.changesFold) {
            unfold()
        }
    }

    /// Opens or closes a section, animated as a fold opening is.
    private func toggle(_ conversation: ConversationKey, in set: Binding<Set<ConversationKey>>) {
        withAnimation(reduceMotion ? nil : WeirMotion.changesFold) {
            if set.wrappedValue.contains(conversation) {
                set.wrappedValue.remove(conversation)
            } else {
                set.wrappedValue.insert(conversation)
            }
        }
    }

    /// The id of the list's very top (`ProjectScrollMemory.goesToTop`).
    private enum ListTop: Hashable {
        case mark
    }

    private func report(top: TurnID?, selected: TurnID?) {
        window.scrollPlace.changesConversation = list.filter
        window.scrollPlace.changesTurn = top
        window.scrollPlace.changesSelected = selected
    }

    /// Right after the window switched to its project in place, the list
    /// goes back to where it was as the window left the project, once
    /// (`ProjectWindowState.takeScrollRestore`): the turn then at its top
    /// back at the top, while the list still shows the same filter, has
    /// the turn, and selects the turn it selected then; else the selected
    /// turn, put in sight as the list opens on it
    /// (`ProjectScrollMemory.changesTarget`, `selectedTurn`). Never
    /// animated, Reduce Motion or not. Says whether it took the list's
    /// place. Only the rows drawn (`drawn`) are places: one the fold hides
    /// has no view to scroll to.
    private func restoreScroll(selected: TurnID?, drawn: [TurnID], proxy: ScrollViewProxy) -> Bool {
        guard let restore = window.takeScrollRestore(for: .changes) else { return false }
        let target = ProjectScrollMemory.changesTarget(
            remembered: restore.memory.changes,
            conversation: list.filter,
            rows: drawn,
            selected: selected
        )
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch target {
            case let .remembered(turn):
                if ProjectScrollMemory.goesToTop(target, in: drawn) {
                    proxy.scrollTo(ListTop.mark, anchor: .top)
                } else {
                    proxy.scrollTo(turn, anchor: .top)
                }
                // Kept as it is put back: a list that does not move is not
                // heard from again, and leaving once more would lose it.
                report(top: turn, selected: selected)
            case let .selected(turn):
                proxy.scrollTo(turn, anchor: .bottom)
            case nil:
                break
            }
        }
        return true
    }
}

/// The viewed line under a list's last row, the timeline's or a section's
/// (`ChangesPanelModel.Line`), once every row there is viewed; nothing
/// otherwise. "Unmark as Viewed" takes back that line's last mark while it
/// still can, never another list's.
struct ViewedLineRow: View {
    let line: ChangesPanelModel.Line?
    let state: AppState
    @Environment(ProjectWindowState.self) private var window

    var body: some View {
        if let line {
            ViewedLineHead(unmark: unmark(line))
                .padding(WeirLayout.Supervision.viewedLineInset)
                // Contained, not combined: combined, VoiceOver's default
                // action on the line would press "Unmark as Viewed".
                .accessibilityElement(children: .contain)
        }
    }

    private func unmark(_ line: ChangesPanelModel.Line) -> (@MainActor () -> Void)? {
        guard !line.undo.isEmpty else { return nil }
        let undo = line.undo
        let window = window
        let state = state
        return { ChangesPanelActions.unmark(undo, window: window, stores: state.changesPanelStores) }
    }
}

/// The fold's line over the viewed rows at the top of the list: "Show 12
/// earlier viewed turns", the cards it holds coming in its place, in words
/// alone, left-aligned and without an edge, starting where the cards' turn
/// numbers do. No chevron: under a section's heading one pointed against
/// the heading's own and read as a pair. The viewed line keeps the list's
/// one edged button, at its right end; a centered button here read as the
/// same kind of row with its button in another place. Pressing it opens the fold and the line
/// leaves the list; nothing folds the cards again until the list is drawn
/// anew, as a chat's earlier messages stay once loaded.
struct ChangesFoldLine: View {
    let title: String
    /// Opens the fold, told whether the line had the keyboard or VoiceOver,
    /// which the first card shown then takes.
    let open: (_ hadFocus: Bool) -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isSpokenFocused: Bool

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Button {
            open(isFocused || isSpokenFocused)
        } label: {
            HStack(spacing: 0) {
                Text(verbatim: title)
                    .font(.supervision(.caption, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle((isHovering ? SupervisionTokens.text : SupervisionTokens.muted).color)
            .padding(.horizontal, Layout.turnCardInsets.leading)
            .padding(.vertical, Layout.spaceXS)
            .background(
                RoundedRectangle(cornerRadius: Layout.smallControlCornerRadius)
                    .fill(isHovering ? SupervisionTokens.hover.color : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityFocused($isSpokenFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// The viewed line's own row: the rule running out on both sides of
/// "Viewed up to here", so the line reads as one mark across the list, and
/// at its right end "Unmark as Viewed" while the last mark can still be
/// taken back, the way back once the toast is gone. The move sits on
/// the line it moves rather than apart from it under the line. A compact
/// edged button, as the cards' moves are, not a link: blue marks only
/// unread and unviewed. A view of its own, apart from the list, which
/// reads the window and the app: built from plain values, the row can be
/// measured against the panel in a test.
struct ViewedLineHead: View {
    /// Takes the line back; `nil` while there is nothing to take back.
    let unmark: (@MainActor () -> Void)?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.viewedLineWordSpacing) {
            rule
            Text(verbatim: ChangesPanelText.line(locale: locale))
                .font(.supervision(.caption, weight: .semibold))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize()
            rule
            if let unmark {
                Button(ChangesPanelText.unmarkViewed(locale: locale)) {
                    unmark()
                }
                .buttonStyle(.supervisionSecondary(size: .compact))
                .accessibilityLabel(Text(verbatim: ChangesPanelText.unmarkViewed(locale: locale)))
            }
        }
    }

    private var rule: some View {
        SupervisionTokens.line.color
            .frame(height: 1)
            .frame(minWidth: WeirLayout.Supervision.viewedLineRuleMinWidth, maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
