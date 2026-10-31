// SupervisionNotificationHistoryRows.swift
// Weir — the notification history's source headings, rows, and folds as the supervision window draws them.

import SwiftUI

/// A source's heading: the agent's badge or the shell's mark, where it ran
/// and the tab when the heading names it, the shorter tab first, and a note that gives way
/// first: "Closed Pane" for a pane that is gone, else "Other Window". Not a
/// button: a row opens what it names, and the heading names only where they
/// came from. What it says is the model's (`NotificationHistoryList.Heading`).
struct SupervisionHistorySourceHeading: View {
    let heading: NotificationHistoryList.Heading
    let isFirstOfDay: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let words = heading.words(locale: locale)
        HStack(spacing: WeirLayout.Supervision.notificationColumnSpacing) {
            badgeView
                .frame(width: WeirLayout.Supervision.notificationGlyphColumnWidth)
            HStack(spacing: WeirLayout.Supervision.spaceXS) {
                // What leads is whole for longer: the rest gives way first
                // (`Words.isTabLeading`). A place's middle goes first, so a
                // worktree's name keeps its project and its own end.
                if words.isTabLeading, let tab = words.tab {
                    leading(tab, truncation: words.tabTruncation)
                    following(words.title, truncation: words.titleTruncation)
                } else {
                    leading(words.title, truncation: words.titleTruncation)
                    if let tab = words.tab {
                        following(tab, truncation: words.tabTruncation)
                    }
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
        .frame(height: WeirLayout.Supervision.notificationSourceHeadingHeight)
        // The badge over the rows' glyphs, inside their group's edge.
        .padding(.horizontal, WeirLayout.Supervision.notificationRowInsets.leading + WeirLayout.Supervision.notificationGroupInset)
        .padding(.top, isFirstOfDay ? 0 : WeirLayout.Supervision.notificationSourceSpacing)
        .padding(.bottom, WeirLayout.Supervision.notificationHeadingGroupGap)
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
                .frame(width: WeirLayout.Supervision.agentBadgeWidth)
                .accessibilityHidden(true)
        }
    }

    private func leading(_ text: String, truncation: SupervisionTruncation) -> some View {
        Text(verbatim: text)
            .fontWeight(.semibold)
            .foregroundStyle(heading.isClosed ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
            .lineLimit(1)
            .supervisionTruncation(truncation)
            .layoutPriority(1)
    }

    private func following(_ text: String, truncation: SupervisionTruncation) -> some View {
        Text(verbatim: text)
            .foregroundStyle(SupervisionTokens.muted.color)
            .lineLimit(1)
            .supervisionTruncation(truncation)
    }

    /// A note ("Closed Pane") after the title, set off by the separator.
    private func separated(_ text: String) -> String {
        AgentStatusText.separator(locale: locale).trimmingCharacters(in: .whitespaces) + " " + text
    }
}

/// One history row in two lines: the state's glyph, then what the row is
/// about, bolder while unread, with when on the right; under it what came
/// of it, quiet or in the glyph's tone, with the facts on the right, so the
/// times and the counts of every row stand in one column each. Each line
/// is cut where it loses least. Hovered, its × takes the time's place. An
/// unread row's glyph is the unread ring, as the sidebar marks an unread
/// turn. A closed source's row is muted and rests, with no hover fill,
/// since opening it only marks it read.
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
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.notificationRowCornerRadius, style: .continuous)
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: WeirLayout.Supervision.notificationColumnSpacing) {
                StateGlyph(kind: glyph)
                    .frame(
                        width: WeirLayout.Supervision.notificationGlyphColumnWidth,
                        height: WeirLayout.Supervision.notificationSourceLineHeight
                    )
                VStack(alignment: .leading, spacing: WeirLayout.Supervision.notificationLineSpacing) {
                    firstLine
                    if lines.outcome != nil || !lines.facts.isEmpty {
                        secondLine
                    }
                }
            }
            .padding(WeirLayout.Supervision.notificationRowInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The fill alone marks the selected row: an edge of its own
            // would run just inside its group's, one frame within another.
            .background(shape.fill(fill))
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
        Button("Delete Notification", role: .destructive, action: onDelete)
    }

    private var fill: Color {
        if isSelected {
            return ground.selection.color
        }
        return isHovering && !isClosed ? ground.hover.color : Color.clear
    }

    private var firstLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
            Text(verbatim: lines.subject)
                .font(.supervision(.body, weight: isUnread ? .semibold : .regular))
                .foregroundStyle(isClosed ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                .lineLimit(1)
                .supervisionTruncation(lines.isSubjectAName ? .subject : .sentence)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The × replaces the time in the same place; laid over the
            // time, so the line keeps the height of its text.
            Text(verbatim: timeLabel)
                .font(.supervision(.meta))
                .monospacedDigit()
                .foregroundStyle(SupervisionTokens.muted.color)
                // Relative labels run wider in ja ("5 分前") than in en; what
                // the row is about gives way first.
                .fixedSize()
                .opacity(isHovering ? 0 : 1)
                .overlay(alignment: .trailing) {
                    DismissGlyphButton(label: "Delete Notification", action: onDelete)
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                }
        }
        .frame(height: WeirLayout.Supervision.notificationSourceLineHeight)
    }

    private var secondLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
            Group {
                switch lines.outcome {
                case let .reply(reply)?:
                    TurnReplyLine(reply: reply, size: .row, lineLimit: 1)
                case .headline?:
                    Text(verbatim: lines.headline)
                        .font(.supervision(.row))
                        .foregroundStyle(tone)
                        .lineLimit(1)
                        .supervisionTruncation(.sentence)
                case let .detail(detail)?:
                    Text(verbatim: detail)
                        .font(.supervision(.row))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(1)
                        .supervisionTruncation(.sentence)
                case nil:
                    Color.clear.frame(height: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !lines.facts.isEmpty {
                // Whole, in the time's column: the reply gives way first.
                Text(ReceiptRunRenderer.attributed(lines.facts, size: .meta, style: .mutedFacts))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// The headline's color under what the row names: the glyph's tone
    /// while the agent is still in that state, quiet once it has left it.
    private var tone: Color {
        switch mark {
        case .approval, .question, .response, .signIn: SupervisionTokens.waitingText.color
        case .stopped: SupervisionTokens.stoppedText.color
        case .idle: SupervisionTokens.muted.color
        }
    }

    private var glyph: StateGlyph.Kind {
        switch mark {
        case .approval: .needsApproval
        case .question: .needsAnswer
        case .response: .needsResponse
        case .signIn: .needsSignIn
        case .stopped: .stopped
        // A closed source's rows rest, read or not.
        case .idle: isUnread && !isClosed ? .unread : .idle
        }
    }

    /// The row's lines whole (`Lines.help`); a closed source's says so
    /// first, as clicking it only marks it read.
    private var help: String {
        let text = lines.help(locale: locale)
        guard isClosed else { return text }
        return NotificationHistoryHeading.paneClosed.resolved(in: locale) + "\n" + text
    }
}

/// A source's rows and its fold drawn as one group under its heading: an
/// edge around them all and a rule between each, from the words' column to
/// the edge. Each line draws its own part, so the list stays flat and
/// lazily drawn; the first closes the edge above it, the last below.
struct NotificationSourceGroupSegment: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.popoverSurface.ground) private var ground

    func body(content: Content) -> some View {
        let inset = WeirLayout.Supervision.notificationGroupInset
        content
            // Inside the edge, so a hovered or selected row's fill never
            // covers it.
            .padding(.horizontal, inset)
            .padding(.top, isFirst ? inset : 0)
            .padding(.bottom, isLast ? inset : 0)
            .overlay {
                NotificationSourceGroupEdge(
                    isFirst: isFirst,
                    isLast: isLast,
                    cornerRadius: WeirLayout.Supervision.notificationGroupCornerRadius
                )
                .stroke(ground.groupRule.color, lineWidth: 1)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if !isFirst {
                    ground.groupRule.color
                        .frame(height: 1)
                        .padding(.leading, WeirLayout.Supervision.notificationGroupRuleLeading)
                        .padding(.trailing, inset + WeirLayout.Supervision.notificationRowInsets.trailing)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// One line's part of its group's edge: the two sides, with the rounded
/// top for the first line and the rounded bottom for the last. Drawn half
/// a point in, so the 1pt stroke stays inside the line's frame.
struct NotificationSourceGroupEdge: Shape {
    let isFirst: Bool
    let isLast: Bool
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(cornerRadius, frame.width / 2, frame.height / 2)
        let top = isFirst ? frame.minY : rect.minY
        let bottom = isLast ? frame.maxY : rect.maxY
        var path = Path()
        // Up the left side, across the top if this line opens the group,
        // down the right side, and back along the bottom if it closes it.
        path.move(to: CGPoint(x: frame.minX, y: isLast ? bottom - radius : bottom))
        if isFirst {
            path.addLine(to: CGPoint(x: frame.minX, y: top + radius))
            path.addArc(tangent1End: CGPoint(x: frame.minX, y: top), tangent2End: CGPoint(x: frame.minX + radius, y: top), radius: radius)
            path.addLine(to: CGPoint(x: frame.maxX - radius, y: top))
            path.addArc(tangent1End: CGPoint(x: frame.maxX, y: top), tangent2End: CGPoint(x: frame.maxX, y: top + radius), radius: radius)
        } else {
            path.addLine(to: CGPoint(x: frame.minX, y: top))
            path.move(to: CGPoint(x: frame.maxX, y: top))
        }
        if isLast {
            path.addLine(to: CGPoint(x: frame.maxX, y: bottom - radius))
            path.addArc(
                tangent1End: CGPoint(x: frame.maxX, y: bottom),
                tangent2End: CGPoint(x: frame.maxX - radius, y: bottom),
                radius: radius
            )
            path.addLine(to: CGPoint(x: frame.minX + radius, y: bottom))
            path.addArc(
                tangent1End: CGPoint(x: frame.minX, y: bottom),
                tangent2End: CGPoint(x: frame.minX, y: bottom - radius),
                radius: radius
            )
        } else {
            path.addLine(to: CGPoint(x: frame.maxX, y: bottom))
        }
        return path
    }
}

extension View {
    /// This line's part of its source's group (`NotificationSourceGroupSegment`).
    func notificationSourceGroup(isFirst: Bool, isLast: Bool) -> some View {
        modifier(NotificationSourceGroupSegment(isFirst: isFirst, isLast: isLast))
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
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.notificationRowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: WeirLayout.Supervision.spaceXS) {
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
                WeirLayout.Supervision.notificationGlyphColumnWidth + WeirLayout.Supervision.notificationColumnSpacing
            )
            .padding(WeirLayout.Supervision.notificationRowInsets)
            .frame(maxWidth: .infinity, minHeight: WeirLayout.Supervision.notificationFoldHeight, alignment: .leading)
            // No edge, as on a row (`SupervisionHistoryRow`).
            .background(shape.fill(isSelected ? ground.selection.color : isHovering ? ground.hover.color : .clear))
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
