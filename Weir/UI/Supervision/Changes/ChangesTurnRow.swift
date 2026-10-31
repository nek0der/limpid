// ChangesTurnRow.swift
// Weir — one turn's card in the changes panel: its number, prompt, facts, reply, and the moves it offers.

import SwiftUI

/// One turn, as a card of two lines: "T7" over its conversation's bar and
/// badge beside its prompt and when it started; then what it changed,
/// its checks in the order they ran, the tokens it used, and how long it
/// ran, each fact in a column of its own so the facts read down the list.
/// The card's moves (the viewed line's, the restore) stand where its time
/// is: at rest on the list's (or the section's) last card with moves and
/// on the one that says why a restore waits, and on another while the
/// pointer or the keyboard is on it or the review reads it. Its context
/// menu and its VoiceOver actions offer them at all times: worded buttons
/// under every card made each one twice as tall. An unviewed turn's number
/// stands in a blue pill (`TurnCardLabel`); one the review tab reads is ringed; one a restore
/// took back is struck out in a dashed edge.
struct ChangesTurnRow: View {
    let row: ChangesPanelModel.Row
    /// The worktree's conversations, named as the filter names them, for
    /// the toast of a move that reaches more than this row's.
    let conversations: [ConversationChoice]
    let isShownInReview: Bool
    /// Whether the menu leads with "Show Tab": while a pane of the
    /// window's session runs the card's conversation
    /// (`ChangesPanelActions.offersShowTab`).
    let offersShowTab: Bool
    /// Whether the card draws its conversation's bar and badge: not in a
    /// section of the list grouped by conversation, whose heading carries
    /// them. The card still marks its tab under the pointer.
    let showsConversation: Bool
    let state: AppState
    /// Whether the card takes the keyboard and VoiceOver as it appears: the
    /// first card a fold opened from the keyboard or VoiceOver showed, whose
    /// line had them and has left the list. `tookFocus` tells the list it
    /// was taken, so the card does not take it again as it scrolls back
    /// into view.
    let takesFocus: Bool
    let tookFocus: () -> Void
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.turnNumberDigits) private var turnNumberDigits
    /// Whether the pointer is on the card, for its own hover look: the
    /// fill and the moves. The window's conversation hover is the
    /// modifier's (`conversationHover`).
    @State private var isHovering = false
    @FocusState private var focus: TurnCardFocus?
    @AccessibilityFocusState private var isSpokenFocused: Bool

    private typealias Layout = WeirLayout.Supervision

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
                    .padding(Layout.turnNoteInsets(
                        hasConversation: showsConversation && row.conversation != nil,
                        digits: turnNumberDigits
                    ))
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
        .animation(reduceMotion ? nil : WeirMotion.hoverReveal, value: showsMoves)
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
        // Dimmed or outlined while a tab's conversation is under the
        // pointer, before the ring is drawn over it; and the card marks its
        // conversation's tab while the pointer is on it. A card with no
        // color (a worktree of one conversation) marks no tab.
        .conversationHover(
            row.turn.conversation,
            surface: .card(row.id),
            identity: row.conversation?.identity,
            mark: .card(isRinged: isRinged)
        ) { isHovering = $0 }
        .overlay {
            if isRinged {
                shape.strokeBorder(SupervisionTokens.unread.color, lineWidth: Layout.turnOpenRingWidth)
                    .accessibilityHidden(true)
            }
        }
        .modifier(TurnCardMenu(isShown: offersShowTab || !moves.isEmpty) { menu })
        .accessibilityElement(children: .contain)
        .onAppear {
            guard takesFocus else { return }
            tookFocus()
            // Once the fold's line, which held the keys, has left the
            // list: asked at once, the request is lost.
            KeyboardHandoff.afterResponderSettles {
                focus = .card
                isSpokenFocused = true
            }
        }
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
            .accessibilityFocused($isSpokenFocused)
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
                .accessibilityFocused($isSpokenFocused)
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

    /// "Show Tab" first, as the way from a turn back to the terminal that
    /// ran it, then the card's moves.
    @ViewBuilder private var menu: some View {
        if offersShowTab {
            Button {
                ChangesPanelActions.showTab(of: row.turn.conversation, window: window, stores: state.changesPanelStores)
            } label: {
                Text(
                    "Show Tab",
                    // swiftlint:disable:next line_length
                    comment: "Changes panel: a turn card's context menu item and a section heading's button; brings forward the tab whose pane runs the conversation"
                )
            }
            .accessibilityLabel(Text("Show Tab"))
            if !moves.isEmpty {
                Divider()
            }
        }
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
                ChangesPanelActions.markViewed(
                    through: row.turn,
                    movesOnlyItsOwnLine: row.movesOnlyItsOwnLine,
                    named: name,
                    window: window,
                    stores: state.changesPanelStores
                )
            case .markUnviewedFrom:
                ChangesPanelActions.markNotViewed(
                    from: row.turn,
                    movesOnlyItsOwnLine: row.movesOnlyItsOwnLine,
                    named: name,
                    window: window,
                    stores: state.changesPanelStores
                )
            }
        case .restore:
            RestoreActions.ask(row.turn, window: window, state: state)
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.turnColumnSpacing) {
            TurnCardLabel(
                number: row.turn.displayNumber,
                isUnviewed: row.status == .unviewed,
                conversation: showsConversation ? row.conversation : nil
            )
            VStack(alignment: .leading, spacing: Layout.turnLineSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceSnug) {
                    // What a restore took back reads as struck out, in the
                    // muted tone: it is history, still read at 4.5:1.
                    Text(verbatim: TurnPromptText.instruction(row.turn.prompt, locale: locale) ?? "")
                        .font(.supervision(.label, weight: .medium))
                        .foregroundStyle(isRestored ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                        .strikethrough(isRestored)
                        .lineLimit(1)
                        .supervisionTruncation(.sentence)
                    Spacer(minLength: WeirLayout.Supervision.spaceSnug)
                    timeSlot
                }
                TurnFactsLine(facts: ChangesPanelText.facts(row, locale: locale))
                // What the agent tried and was refused, seen in passing: a
                // card with none stays as it was. The tooltip has them all,
                // with their reasons.
                if let denied = ChangesPanelText.deniedLine(row.turn, locale: locale) {
                    TurnDeniedLine(action: denied.action, more: denied.more)
                }
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

    private var timeSlot: some View {
        TurnCardTimeSlot(moves: moves, time: ChangesPanelText.time(row.turn, locale: locale), showsMoves: showsMoves)
    }
}

/// The end of a card's first line: the time, or while the moves show, room
/// as wide as they are. The slot keeps only the time's width at rest, so the
/// prompt has the rest of the line, and gives up its end only while the
/// moves stand over the time. The room takes their width alone: as tall as
/// a glyph, set on the line's baseline, it would push the line down by the
/// glyph's depth below the time's, and the card would grow while the
/// pointer or the keyboard is on it.
struct TurnCardTimeSlot: View {
    let moves: [TurnCardMove]
    let time: String?
    let showsMoves: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if showsMoves {
                TurnCardMovesRoom(moves: moves)
                    .frame(height: 0)
            }
            if let time {
                Text(verbatim: time)
                    .font(.supervision(.caption).monospacedDigit())
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .opacity(showsMoves ? 0 : 1)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// A turn card's first column: "T7", and under it the conversation's
/// badge, led by its identity bar where it has one, where the worktree has
/// more than one conversation. Stacked in the one column, so the prompt
/// starts where it does in a worktree of one conversation, and every row
/// of the list keeps the column whatever its conversation. An unviewed
/// turn's number stands in a filled pill, the card's one mark of its
/// state; the row's sentence says "Unviewed" in words.
struct TurnCardLabel: View {
    let number: Int
    let isUnviewed: Bool
    /// The row's conversation, `nil` in a worktree of one.
    let conversation: ConversationChoice?
    @Environment(\.locale) private var locale
    @Environment(\.turnNumberDigits) private var turnNumberDigits

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        content
            .frame(
                width: Layout.turnFirstColumnWidth(hasConversation: conversation != nil, digits: turnNumberDigits),
                alignment: .leading
            )
    }

    /// The column's contents at their own width.
    var content: some View {
        VStack(alignment: .leading, spacing: Layout.turnLabelSpacing) {
            // Monospaced, so the numbers stand in one column down the list.
            // The pill is drawn behind the number, past its frame, rather
            // than padding it: the number stays where a viewed turn's
            // stands, and the card stays as tall.
            Text(verbatim: ReceiptText.turn(number))
                .font(Font(Layout.turnNumberFont))
                .foregroundStyle(isUnviewed ? SupervisionTokens.onUnreadCount.color : SupervisionTokens.muted.color)
                .background {
                    if isUnviewed {
                        RoundedRectangle(cornerRadius: Layout.turnUnviewedPillCornerRadius, style: .continuous)
                            .fill(SupervisionTokens.unreadCount.color)
                            .padding(.horizontal, -Layout.turnUnviewedPillPadding.width)
                            .padding(.vertical, -Layout.turnUnviewedPillPadding.height)
                            .accessibilityHidden(true)
                    }
                }
            if let conversation {
                let badge = SessionRowFact.Badge.agent(conversation.conversation.provider)
                // Silent: the row's sentence names the conversation.
                ConversationIdentityLead(identity: conversation.identity) {
                    SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .row)
                }
                // Out to where the unviewed pill starts, so the two marks
                // share a left edge; moved, not padded, so the column and
                // the prompt after it stay put.
                .offset(x: -Layout.turnUnviewedPillPadding.width)
            }
        }
    }
}

/// The card's context menu, left off a card with nothing to offer (a running
/// turn whose conversation no pane of the session runs), so a right-click
/// there opens nothing rather than an empty menu.
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

extension EnvironmentValues {
    /// How many digits the list's highest turn number has
    /// (`ChangesPanelModel.TurnList.turnNumberDigits`), which sizes every
    /// card's first column. Four outside the list, room for "T1000".
    @Entry var turnNumberDigits = 4
}
