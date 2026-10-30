// ChangesTurnSection.swift
// Limpid — one conversation's section of the changes panel's list grouped by conversation: its heading, fold, cards, and line.

import SwiftUI

/// One conversation's turns in the list grouped by conversation: its
/// heading, then, while the section is open, its own fold, its cards
/// at the list's full width, and its own viewed line. Drawn as siblings
/// in the list's lazy stack rather than in a stack of its own, so the list
/// reports and restores its place by the cards as it does on the timeline.
struct ChangesTurnSection: View {
    let section: ChangesPanelModel.Section
    let isFirst: Bool
    let isCollapsed: Bool
    /// The rows the list hides (`ChangesPanelModel.hiddenRows(sections:collapsed:unfolded:shownInReview:)`).
    let hidden: Set<TurnID>
    let shownInReview: Set<TurnID>
    /// Whether a pane of the window's session runs the conversation, so
    /// its heading and cards offer "Show Tab".
    let offersShowTab: Bool
    /// The worktree's conversations, for a move's toast.
    let conversations: [ConversationChoice]
    let state: AppState
    /// The card that takes the keyboard and VoiceOver as it appears
    /// (`ChangesTurnRow.takesFocus`), and what clears it once taken.
    let focusOnAppear: TurnID?
    let tookFocus: () -> Void
    let toggleCollapse: () -> Void
    let openFold: (_ hadFocus: Bool) -> Void
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        ChangesSectionHeading(
            choice: section.choice,
            isCollapsed: isCollapsed,
            offersShowTab: offersShowTab,
            state: state,
            toggle: toggleCollapse
        )
        .padding(.top, isFirst ? 0 : Layout.changesSectionGap)
        if !isCollapsed {
            if let fold = ChangesPanelModel.foldLine(section.fold, rows: section.rows, hidden: hidden) {
                ChangesFoldLine(title: ChangesPanelText.fold(fold, locale: locale), open: openFold)
                    .conversationHoverDimming(section.id)
            }
            ForEach(section.rows) { row in
                if !hidden.contains(row.id) {
                    ChangesTurnRow(
                        row: row,
                        conversations: conversations,
                        isShownInReview: shownInReview.contains(row.id),
                        offersShowTab: offersShowTab,
                        showsConversation: false,
                        state: state,
                        takesFocus: focusOnAppear == row.id,
                        tookFocus: tookFocus
                    )
                    .id(row.id)
                }
            }
            // The section's own line, whose "Unmark as Viewed" never moves
            // another section's.
            ViewedLineRow(line: section.line, state: state)
                .conversationHoverDimming(section.id)
        }
    }
}

/// A section's heading: the chevron that opens and closes it, the
/// conversation's identity bar and badge, which its cards leave out, its
/// name over its detail line (`ConversationText.detail`), its
/// unviewed count, and "Show Tab" while a pane of the session runs it.
/// It stands for the conversation's cards under the pointer: it marks the
/// conversation's tab as a card does, and steps back with the cards while
/// another conversation's tab is under the pointer (`ConversationHoverRule`).
struct ChangesSectionHeading: View {
    let choice: ConversationChoice
    let isCollapsed: Bool
    let offersShowTab: Bool
    let state: AppState
    let toggle: () -> Void
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let detail = ConversationText.detail(choice, locale: locale)
        HStack(spacing: Layout.spaceS) {
            Button(action: toggle) {
                label(detail: detail)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: ConversationText.help(choice, locale: locale)))
            .accessibilityLabel(Text(verbatim: ConversationText.spokenName(choice, locale: locale)))
            .accessibilityValue(Text(verbatim: ConversationText.sectionValue(choice, isCollapsed: isCollapsed, locale: locale)))
            .accessibilityAddTraits(.isHeader)
            if offersShowTab {
                Button {
                    ChangesPanelActions.showTab(of: choice.conversation, window: window, stores: state.changesPanelStores)
                } label: {
                    Text(
                        "Show Tab",
                        // swiftlint:disable:next line_length
                        comment: "Changes panel: a turn card's context menu item and a section heading's button; brings forward the tab whose pane runs the conversation"
                    )
                }
                .buttonStyle(.supervisionSecondary(size: .compact))
                .accessibilityLabel(Text("Show Tab"))
            }
        }
        // Faded with the section's cards behind another conversation's
        // tab, never outlined, as only a card is; it marks its tab as a
        // card does.
        .conversationHover(
            choice.conversation,
            surface: .heading(choice.conversation),
            identity: choice.identity,
            mark: .heading
        )
        .accessibilityElement(children: .contain)
    }

    private func label(detail: String) -> some View {
        let badge = SessionRowFact.Badge.agent(choice.conversation.provider)
        return HStack(spacing: Layout.spaceS) {
            Image(systemName: "chevron.right")
                .font(.supervision(.micro, weight: .semibold))
                .foregroundStyle(SupervisionTokens.muted.color)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(reduceMotion ? nil : LimpidMotion.reorder, value: isCollapsed)
                .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
                .accessibilityHidden(true)
            ConversationIdentityLead(identity: choice.identity, barHeight: Layout.conversationIdentityBarHeadingHeight) {
                SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .regular)
            }
            VStack(alignment: .leading, spacing: Layout.turnLineSpacing) {
                HStack(spacing: Layout.spaceSnug) {
                    Text(verbatim: ConversationText.name(choice, locale: locale))
                        .font(.supervision(.label, weight: .semibold))
                        .foregroundStyle(SupervisionTokens.text.color)
                        .lineLimit(1)
                        .supervisionTruncation(.name)
                    if choice.unviewedCount > 0 {
                        ChangesSectionCount(count: choice.unviewedCount)
                    }
                }
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.supervision(.caption))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A section's unviewed count, in the pill the rail's count stands in.
/// Silent: the heading's value says the count in words.
private struct ChangesSectionCount: View {
    let count: Int

    var body: some View {
        let size = LimpidLayout.Supervision.changesSectionCountSize
        Text(verbatim: "\(count)")
            .font(.supervision(.badge, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(SupervisionTokens.onUnreadCount.color)
            .padding(.horizontal, LimpidLayout.Supervision.spaceXS)
            .frame(minWidth: size, minHeight: size)
            .background(Capsule().fill(SupervisionTokens.unreadCount.color))
            .fixedSize()
            .accessibilityHidden(true)
    }
}
