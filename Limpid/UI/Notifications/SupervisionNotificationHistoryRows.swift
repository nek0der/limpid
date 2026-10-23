// SupervisionNotificationHistoryRows.swift
// Limpid — the notification history's source headings, rows, and folds as the supervision window draws them.

import SwiftUI

/// A source's heading: the agent's badge or the shell's mark, where
/// it ran, the tab when the heading names it, and a note that gives way
/// first: "Closed Pane" for a pane that is gone, else "Other Window". Not a
/// button: a row opens what it names, and the heading names only where they
/// came from. What it says is the model's (`NotificationHistoryList.Heading`).
struct SupervisionHistorySourceHeading: View {
    let heading: NotificationHistoryList.Heading
    let isFirstOfDay: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let words = heading.words(locale: locale)
        HStack(spacing: LimpidLayout.Supervision.notificationColumnSpacing) {
            badgeView
                .frame(width: LimpidLayout.Supervision.notificationGlyphColumnWidth)
            HStack(spacing: LimpidLayout.Supervision.spaceXS) {
                // A place's middle goes first: a worktree's name keeps its
                // project and its own end.
                Text(verbatim: words.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(heading.isClosed ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                    .lineLimit(1)
                    .supervisionTruncation(words.titleTruncation)
                    // The place names the source: the tab and the note give
                    // way before it, so a long tab never squeezes it to
                    // nothing and leaves the line starting at "·".
                    .layoutPriority(1)
                if let tab = words.tab {
                    // The separator on its own, so a path cut at its head
                    // still starts with it.
                    HStack(spacing: 0) {
                        Text(verbatim: separated(""))
                            .fixedSize()
                        Text(verbatim: tab)
                            .lineLimit(1)
                            .supervisionTruncation(words.tabTruncation)
                    }
                    .foregroundStyle(SupervisionTokens.muted.color)
                }
                if let note = words.note {
                    Text(verbatim: separated(note))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(1)
                        .supervisionTruncation(.sentence)
                        .layoutPriority(-1)
                }
            }
            .font(.supervision(.meta))
            Spacer(minLength: 0)
        }
        .frame(height: LimpidLayout.Supervision.notificationSourceHeadingHeight)
        .padding(.horizontal, LimpidLayout.Supervision.notificationRowInsets.leading)
        .padding(.top, isFirstOfDay ? 0 : LimpidLayout.Supervision.notificationSourceSpacing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: heading.spokenLabel(locale: locale)))
        .accessibilityAddTraits(.isHeader)
    }

    /// A closed source's badge is gray (`closedMark`), the shell's mark as the agent's.
    /// A source that never said which agent spoke wears the generic place
    /// mark, so no heading starts without one.
    @ViewBuilder private var badgeView: some View {
        switch heading.badge {
        case let .agent(kind):
            SessionAgentBadge(
                badge: .agent(kind),
                text: SessionRowFactText.badge(.agent(kind), locale: locale),
                isFaint: heading.isClosed
            )
        case .shell:
            ShellPromptBadge(isFaint: heading.isClosed)
        case .none:
            Image(systemName: "mappin.and.ellipse")
                .font(.supervision(.caption))
                .foregroundStyle(heading.isClosed ? SupervisionTokens.closedMark.color : SupervisionTokens.muted.color)
                .frame(width: LimpidLayout.Supervision.agentBadgeWidth)
                .accessibilityHidden(true)
        }
    }

    /// A tab ("zsh") or a note ("Closed Pane") after the title, set off as
    /// the row's facts are.
    private func separated(_ text: String) -> String {
        AgentStatusText.separator(locale: locale).trimmingCharacters(in: .whitespaces) + " " + text
    }
}

/// One history row: the state's glyph; what happened, bolder while
/// unread, with its facts quiet after it, and when on the right with the
/// unread dot; under it the instruction or detail, quiet, on one line, cut
/// where it loses least. Hovered, its × takes the time's place. A closed
/// source's row is muted and rests, with no hover fill, since opening it
/// only marks it read.
struct SupervisionHistoryRow: View {
    let lines: NotificationHistoryRowText.Lines
    let mark: NotificationHistoryRowText.Mark
    let timeLabel: String
    let isUnread: Bool
    /// Muted and resting, with no hover fill: the source's pane is gone.
    let isClosed: Bool
    /// Whether the row offers Open Pane, in its menu and to VoiceOver
    /// (`NotificationHistoryList.Row.opensPane`).
    let opensPane: Bool
    let isSelected: Bool
    let onOpen: () -> Void
    let onMarkRead: () -> Void
    let onDelete: () -> Void
    @Environment(\.locale) private var locale
    @State private var isHovering = false
    @Environment(\.popoverSurface.ground) private var ground

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.notificationRowCornerRadius, style: .continuous)
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: LimpidLayout.Supervision.notificationColumnSpacing) {
                StateGlyph(kind: glyph)
                    .frame(
                        width: LimpidLayout.Supervision.notificationGlyphColumnWidth,
                        height: LimpidLayout.Supervision.notificationSourceLineHeight
                    )
                VStack(alignment: .leading, spacing: LimpidLayout.Supervision.notificationLineSpacing) {
                    firstLine
                    if let detail = lines.detail {
                        Text(verbatim: detail)
                            .font(.supervision(.row))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .lineLimit(1)
                            .supervisionTruncation(lines.isDetailASubject ? .subject : .sentence)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(LimpidLayout.Supervision.notificationRowInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .popoverSelectionEdge(isSelected: isSelected, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: help))
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: NotificationHistoryRowText.spokenLabel(
            lines,
            timeLabel: timeLabel,
            isUnread: isUnread,
            locale: locale
        )))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // A row that opens no pane offers none to VoiceOver either.
        .accessibilityActions {
            if opensPane {
                Button("Open Pane", action: onOpen)
            }
            if isUnread {
                Button("Mark as Read", action: onMarkRead)
            }
            Button("Delete Notification", action: onDelete)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open Pane", action: onOpen)
            .disabled(!opensPane)
        Button("Mark as Read", action: onMarkRead)
            .disabled(!isUnread)
        Divider()
        Button("Delete Notification", action: onDelete)
    }

    private var fill: Color {
        if isSelected {
            return ground.selection.color
        }
        return isHovering && !isClosed ? ground.hover.color : Color.clear
    }

    private var firstLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: LimpidLayout.Supervision.spaceS) {
            Text(firstLineText)
                .lineLimit(1)
                .supervisionTruncation(.sentence)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The × replaces the time in the same place rather than covering
            // the unread dot; laid over the time, so the line keeps the
            // height of its text.
            Text(verbatim: timeLabel)
                .font(.supervision(.meta))
                .monospacedDigit()
                .foregroundStyle(SupervisionTokens.muted.color)
                // Relative labels run wider in ja ("5 分前") than in en; what
                // happened gives way first.
                .fixedSize()
                .opacity(isHovering ? 0 : 1)
                .overlay(alignment: .trailing) {
                    DismissGlyphButton(label: "Delete Notification", action: onDelete)
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                }
            // Kept in its place while read, so every row's time ends at the
            // same edge. VoiceOver reads "Unread" in the row's label.
            Circle()
                .fill(isUnread ? SupervisionTokens.unread.color : Color.clear)
                .frame(
                    width: LimpidLayout.Supervision.notificationUnreadDotSize,
                    height: LimpidLayout.Supervision.notificationUnreadDotSize
                )
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
        }
        .frame(height: LimpidLayout.Supervision.notificationSourceLineHeight)
    }

    /// What happened in the text color (muted for a closed source), then
    /// its facts quiet, the receipt's counts in the diff colors.
    private var firstLineText: AttributedString {
        var headline = AttributedString(lines.headline)
        headline.foregroundColor = isClosed ? SupervisionTokens.muted.color : SupervisionTokens.text.color
        headline.font = .supervision(.body, weight: isUnread ? .semibold : .regular)
        return headline + ReceiptRunRenderer.attributed(lines.facts, size: .body, style: .mutedFacts)
    }

    private var glyph: StateGlyph.Kind {
        switch mark {
        case .approval: .needsApproval
        case .question: .needsAnswer
        case .response: .needsResponse
        case .stopped: .stopped
        case .idle: .idle
        }
    }

    /// Both lines whole, which the row may cut; a closed source's says so
    /// first, as clicking it only marks it read.
    private var help: String {
        let text = [lines.firstLine, lines.detail].compactMap(\.self).joined(separator: "\n")
        guard isClosed else { return text }
        return NotificationHistoryHeading.paneClosed.resolved(in: locale) + "\n" + text
    }
}

/// "4 more" under a source's rows, its read rows past the first few; open,
/// "Show Less". Its words in line with the rows' words, quiet; the whole
/// line takes the click, as tall as a row's line, since a click a little
/// under the words lands between rows and would do nothing if only the
/// words took it.
struct SupervisionHistoryFold: View {
    let count: Int
    let isExpanded: Bool
    /// The source's place, which VoiceOver names: the fold is read apart
    /// from its heading.
    let sourceName: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.popoverSurface.ground) private var ground

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.notificationRowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: LimpidLayout.Supervision.spaceXS) {
                if isExpanded {
                    Text("Show Less")
                } else {
                    Text("\(count) more")
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.supervision(.glyph, weight: .semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(.supervision(.row))
            .foregroundStyle(isHovering || isSelected ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
            // In line with the rows' words: past the glyph's column.
            .padding(
                .leading,
                LimpidLayout.Supervision.notificationGlyphColumnWidth + LimpidLayout.Supervision.notificationColumnSpacing
            )
            .padding(LimpidLayout.Supervision.notificationRowInsets)
            .frame(maxWidth: .infinity, minHeight: LimpidLayout.Supervision.notificationFoldHeight, alignment: .leading)
            .background(shape.fill(isSelected ? ground.selection.color : isHovering ? ground.hover.color : .clear))
            .popoverSelectionEdge(isSelected: isSelected, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isExpanded
            ? Text("Show less from \(sourceName)")
            : Text("Show \(count) more from \(sourceName)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
