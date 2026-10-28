// ChangesPanelView.swift
// Limpid — the changes panel: the worktree's turns as one timeline, with each row's viewed state, beside the terminal.

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

    private typealias Layout = LimpidLayout.Supervision

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
                ChangesTurnList(list: list, state: state)
                    .id(window.selection.activeContainerID)
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
        // mark moves the unviewed range the totals count, as Limpid
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
        let summary: String? = if case let .turns(list) = content, list.hasAgents {
            ChangesPanelText.summary(turns: list.turnCount, unviewed: list.unviewedCount, locale: locale)
        } else {
            nil
        }
        let conversations: [ConversationChoice] = if case let .turns(list) = content {
            list.conversations
        } else {
            []
        }
        return VStack(alignment: .leading, spacing: Layout.changesHeadSpacing) {
            ChangesPanelHeadLayout(summary: summary, hasFilter: !conversations.isEmpty) {
                title
            } buttons: {
                headButtons(content)
            } filter: {
                if case let .turns(list) = content {
                    ChangesConversationFilter(filter: list.filter, conversations: conversations) { conversation in
                        ChangesPanelActions.select(conversation, window: window, session: state.session)
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

    private var title: some View {
        Text("Changes")
            .font(LimpidFont.Supervision.surfaceHeading)
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
    let hasFilter: Bool
    @ViewBuilder var title: () -> Title
    @ViewBuilder var buttons: () -> Buttons
    @ViewBuilder var filter: () -> Filter
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.changesHeadSpacing) {
            switch ChangesSummaryPlacement.placement(hasFilter: hasFilter) {
            case .besideWhileItFits:
                ViewThatFits(in: .horizontal) {
                    titleLine {
                        title()
                        summaryText
                        Spacer(minLength: LimpidLayout.Supervision.spaceS)
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
        HStack(spacing: LimpidLayout.Supervision.spaceS, content: content)
            .frame(height: Layout.surfaceHeadingLineHeight)
            .padding(.trailing, Layout.surfaceHeadingButtonTrailingInset - Layout.changesHeadInsets.trailing)
    }

    private var titleOverSummary: some View {
        VStack(alignment: .leading, spacing: Layout.changesHeadSpacing) {
            titleLine {
                title()
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
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
                // The panel has no standing line that says what "unviewed"
                // counts, so the counts say it on hover.
                .help(Text("Unviewed: turns not yet marked as viewed, in every conversation in this worktree"))
                .accessibilityLabel(Text(verbatim: AgentStatusText.spoken(summary, locale: locale)))
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

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let shown = conversations.first { $0.conversation == filter }
        let label = ChangesPanelText.filterLabel(filter, among: conversations, locale: locale)
        HStack(spacing: LimpidLayout.Supervision.spaceS) {
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
                value: label
            ) {
                entries
            } label: {
                BorderedMenuTriggerLabel {
                    if let shown {
                        let badge = SessionRowFact.Badge.agent(shown.conversation.provider)
                        SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .regular)
                    }
                    Text(verbatim: label)
                        .font(.supervision(.row, weight: .medium))
                        .foregroundStyle(SupervisionTokens.text.color)
                        .lineLimit(1)
                }
            }
            .fixedSize()
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
/// viewed. Opens on the latest unviewed turn.
private struct ChangesTurnList: View {
    let list: ChangesPanelModel.TurnList
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// This is true once the person opened the fold. The list folds again
    /// as it is drawn anew (another worktree, which the panel gives a list
    /// of its own, or the panel opened again).
    @State private var isUnfolded = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let shownInReview = ChangesPanelModel.turnsShownInReview(window.review)
        let selected = ProjectScrollMemory.selectedTurn(
            rows: list.rows.map(\.id),
            shownInReview: shownInReview,
            opensOn: list.scrollTarget
        )
        let hidden = ChangesPanelModel.hiddenRows(
            fold: list.fold,
            isUnfolded: isUnfolded,
            shownInReview: shownInReview,
            rows: list.rows
        )
        let drawn = ChangesPanelModel.drawnRows(list.rows, hidden: hidden)
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
                        if let fold = list.fold {
                            ChangesFoldLine(title: ChangesPanelText.fold(fold, isUnfolded: isUnfolded, locale: locale)) {
                                withAnimation(reduceMotion ? nil : LimpidMotion.changesFold) {
                                    isUnfolded.toggle()
                                }
                            }
                        }
                        ForEach(list.rows) { row in
                            if !hidden.contains(row.id) {
                                ChangesTurnRow(
                                    row: row,
                                    conversations: list.conversations,
                                    isShownInReview: shownInReview.contains(row.id),
                                    state: state
                                )
                                .id(row.id)
                            }
                        }
                        if list.line != nil {
                            lineView
                        }
                    }
                    // The turns are what the list reports its place by.
                    .scrollTargetLayout()
                    .modifier(SharedTurnFactColumns())
                    .padding(Layout.changesListInset)
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

    /// The line under the last row (`ViewedLineHead`), once every row is
    /// viewed.
    private var lineView: some View {
        ViewedLineHead(unmark: unmark)
            .padding(Layout.viewedLineInset)
            // Contained, not combined: combined, VoiceOver's default action
            // on the line would press "Unmark as Viewed".
            .accessibilityElement(children: .contain)
    }

    /// Takes the last mark back while it can still be (`ViewedLineHead`).
    private var unmark: (@MainActor () -> Void)? {
        guard let undo = list.line?.undo, !undo.isEmpty else { return nil }
        let window = window
        let state = state
        return { ChangesPanelActions.unmark(undo, window: window, stores: state.changesPanelStores) }
    }
}

/// The fold's line over the viewed rows at the top of the list: "Show 12
/// viewed turns", between two rules, as the viewed line reads, and "Hide
/// viewed turns" once they are shown. The words are a compact secondary
/// button, as the viewed line's "Unmark as Viewed" is, so the two lines
/// read as one kind.
struct ChangesFoldLine: View {
    let title: String
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.viewedLineWordSpacing) {
            rule
            Button(title, action: toggle)
                .buttonStyle(.supervisionSecondary(size: .compact))
                .accessibilityLabel(Text(verbatim: title))
            rule
        }
        .padding(LimpidLayout.Supervision.viewedLineInset)
    }

    private var rule: some View {
        SupervisionTokens.line.color
            .frame(height: 1)
            .frame(minWidth: LimpidLayout.Supervision.viewedLineRuleMinWidth, maxWidth: .infinity)
            .accessibilityHidden(true)
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
        HStack(spacing: LimpidLayout.Supervision.viewedLineWordSpacing) {
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
            .frame(minWidth: LimpidLayout.Supervision.viewedLineRuleMinWidth, maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// One turn, as a card of two lines: "T7" over its conversation's badge
/// ("Cl #4") beside its prompt and when it started; then what it changed,
/// its checks in the order they ran, the tokens it used, and how long it
/// ran, each fact in a column of its own so the facts read down the list.
/// The card's moves (the viewed line's, the restore) stand where its time
/// is: at rest on the list's last card with moves and on the one that says
/// why a restore waits, and on another while the pointer or the keyboard is
/// on it or the review reads it. Its context menu and its VoiceOver actions
/// offer them at all times: worded buttons under every card made each one
/// twice as tall. An unviewed turn carries the
/// blue rule at its leading edge; one the review tab reads is ringed; one
/// a restore took back is struck out in a dashed edge.
private struct ChangesTurnRow: View {
    let row: ChangesPanelModel.Row
    /// The worktree's conversations, named as the filter names them, for
    /// the toast of a move that reaches more than this row's.
    let conversations: [ConversationChoice]
    let isShownInReview: Bool
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var focus: TurnCardFocus?

    private typealias Layout = LimpidLayout.Supervision

    /// Ringed only where the row opens the review, so the ring and the
    /// row's selected trait say the same.
    private var isRinged: Bool {
        isShownInReview && row.isSelectable
    }

    private var isRestored: Bool {
        row.status == .restored
    }

    private var moves: [TurnCardMove] {
        ChangesPanelText.moves(row, locale: locale)
    }

    private var showsMoves: Bool {
        (row.showsMovesAtRest || isHovering || isRinged || focus != nil) && !moves.isEmpty
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.turnCardCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            opener
            // Under the facts rather than beside the glyph, so the reason
            // wraps to the card's width.
            if row.offersRestore, row.showsBlockerNote, let blocker = row.restoreBlocker {
                RestoreBlockerNote(blocker: blocker)
                    .padding(Layout.turnNoteInsets(hasConversation: row.conversation != nil))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Over the card rather than inside the row's button, whose label
        // cannot hold buttons of its own. The time's slot widens to take
        // them (`timeSlot`), so they cover nothing. Silent to VoiceOver,
        // which offers the same moves as the row's actions.
        .overlay(alignment: .topTrailing) {
            if showsMoves {
                TurnCardMoves(moves: moves, perform: perform, focus: $focus)
                    .padding(.top, Layout.turnCardInsets.top)
                    .padding(.trailing, Layout.turnCardInsets.trailing)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : LimpidMotion.hoverReveal, value: showsMoves)
        // No fill at rest: the card is the panel's own `window` surface,
        // edged, so it is as see-through as the panel with transparency on.
        .background(isHovering && row.isSelectable ? SupervisionTokens.hover.color.opacity(surfaceOpacity) : .clear)
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    SupervisionTokens.line.color,
                    style: StrokeStyle(lineWidth: 1, dash: isRestored ? Layout.restoredTurnBorderDash : [])
                )
                .accessibilityHidden(true)
        }
        // The card's leading edge, thickened, so the rule follows the card's
        // corners rather than standing as a bar the corners cut.
        .overlay {
            if row.status == .unviewed {
                LeadingEdgeShape(cornerRadius: Layout.turnCardCornerRadius, width: Layout.turnUnviewedRuleWidth)
                    .fill(SupervisionTokens.unread.color)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if isRinged {
                shape.strokeBorder(SupervisionTokens.unread.color, lineWidth: Layout.turnOpenRingWidth)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovering = $0 }
        .modifier(TurnCardMenu(isShown: !moves.isEmpty) { menu })
        .accessibilityElement(children: .contain)
    }

    /// A turn that opens in the review is a button; one that cannot (an
    /// answer, a running turn, one a restore took back) is not, so its
    /// words keep their contrast: a disabled plain button would fade them.
    /// Either reads as one sentence, with its conversation and its state
    /// (`ChangesPanelText.rowSpoken`), and offers the card's moves as its
    /// actions; a restore held back says why as the card's hint.
    @ViewBuilder private var opener: some View {
        let help = Text(verbatim: ChangesPanelText.help(row, locale: locale))
        let spoken = Text(verbatim: ChangesPanelText.rowSpoken(row, locale: locale))
        let hint = Text(verbatim: moves.lazy.compactMap(\.blocker).first ?? "")
        // A card that does not open still takes the keyboard, so its moves
        // show for it as for one that does.
        if row.isSelectable {
            Button {
                ChangesPanelActions.open(row.turn, window: window, stores: state.changesPanelStores)
            } label: {
                summary
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .card)
            .help(help)
            .accessibilityLabel(spoken)
            .accessibilityHint(hint)
            .accessibilityAddTraits(isRinged ? .isSelected : [])
            .accessibilityActions { moveActions }
        } else {
            summary
                // Only the keyboard moves focus here, as it does to a plain
                // button: a click does not, so the moves do not stay out.
                .focusable(interactions: .activate)
                .focused($focus, equals: .card)
                .help(help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityHint(hint)
                .accessibilityActions { moveActions }
        }
    }

    /// The moves VoiceOver offers on the row, whether the glyphs show or
    /// not. A held-back restore is left out, as an action that does
    /// nothing; the row's hint says why it is held back.
    private var moveActions: some View {
        ForEach(moves.filter(\.isEnabled)) { move in
            Button(move.title) {
                perform(move.kind)
            }
        }
    }

    private var menu: some View {
        ForEach(moves) { move in
            Button(move.title) {
                perform(move.kind)
            }
            .disabled(!move.isEnabled)
        }
    }

    private func perform(_ kind: TurnCardMove.Kind) {
        switch kind {
        case let .line(action):
            // The toast names whichever conversation's line moved first,
            // which need not be this row's.
            let named = conversations + (row.conversation.map { [$0] } ?? [])
            let name: (ConversationKey) -> String? = { key in
                named.first { $0.conversation == key }.map { ConversationText.name($0, locale: locale) }
            }
            switch action {
            case .markViewedThrough:
                ChangesPanelActions.markViewed(through: row.turn, named: name, window: window, stores: state.changesPanelStores)
            case .markUnviewedFrom:
                ChangesPanelActions.markNotViewed(from: row.turn, named: name, window: window, stores: state.changesPanelStores)
            }
        case .restore:
            RestoreActions.ask(row.turn, window: window, state: state)
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.turnColumnSpacing) {
            label
            VStack(alignment: .leading, spacing: Layout.turnLineSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: LimpidLayout.Supervision.spaceSnug) {
                    // What a restore took back reads as struck out, in the
                    // muted tone: it is history, still read at 4.5:1.
                    Text(verbatim: TurnPromptText.instruction(row.turn.prompt, locale: locale) ?? "")
                        .font(.supervision(.label, weight: .medium))
                        .foregroundStyle(isRestored ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                        .strikethrough(isRestored)
                        .lineLimit(1)
                        .supervisionTruncation(.sentence)
                    Spacer(minLength: LimpidLayout.Supervision.spaceSnug)
                    timeSlot
                }
                TurnFactsLine(facts: ChangesPanelText.facts(row, locale: locale))
                // What the agent said as the turn ended, under what the turn
                // did, so the prompt above and the reply here read as the
                // turn's two ends. Two lines at most; the tooltip has more.
                if let reply = row.turn.reply {
                    TurnReplyLine(reply: reply, size: .caption, lineLimit: 2, isStruckOut: isRestored)
                }
            }
        }
        .padding(Layout.turnCardInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The time, or while the moves show, room as wide as they are: the
    /// slot keeps only the time's width at rest, so the prompt has the
    /// rest of the line, and gives up its end only while the moves stand
    /// over the time.
    private var timeSlot: some View {
        ZStack(alignment: .trailing) {
            if showsMoves {
                TurnCardMovesRoom(moves: moves)
            }
            if let time = ChangesPanelText.time(row.turn, locale: locale) {
                Text(verbatim: time)
                    .font(.supervision(.caption).monospacedDigit())
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .opacity(showsMoves ? 0 : 1)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// The row's first column: "T7", and under it the conversation's badge
    /// with its number ("Cl #4") where the worktree has more than one
    /// conversation. Stacked in the one column, so the prompt starts
    /// where it does in a worktree of one conversation, and every row of
    /// the list keeps the column whatever its conversation.
    private var label: some View {
        VStack(alignment: .leading, spacing: Layout.turnLineSpacing) {
            // Monospaced, so the numbers stand in one column down the list.
            Text(verbatim: ReceiptText.turn(row.turn.displayNumber))
                .font(Font(LimpidLayout.Supervision.turnNumberFont))
                .foregroundStyle(row.status == .unviewed ? SupervisionTokens.unreadText.color : SupervisionTokens.muted.color)
            if let conversation = row.conversation {
                let badge = SessionRowFact.Badge.agent(conversation.conversation.provider)
                // Apart enough that "#2" reads as the badge's number, not
                // as a letter of it.
                HStack(spacing: LimpidLayout.Supervision.spaceXS) {
                    // Silent: the row's sentence names the conversation.
                    SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .row)
                    if let ordinal = ChangesPanelText.ordinal(conversation) {
                        Text(verbatim: ordinal)
                            .font(.supervision(.caption).monospacedDigit())
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .frame(width: Layout.turnFirstColumnWidth(hasConversation: row.conversation != nil), alignment: .leading)
    }
}

/// The card's context menu, left off a card with no moves (a running turn),
/// so a right-click there opens nothing rather than an empty menu.
private struct TurnCardMenu<Items: View>: ViewModifier {
    let isShown: Bool
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        if isShown {
            content.contextMenu { items() }
        } else {
            content
        }
    }
}
