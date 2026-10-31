// SessionRowView.swift
// Limpid — one session row in the two-line form, and the scratch row.

import SwiftUI

/// A session row: 44pt in two lines. The first line has the state
/// glyph, the name (cut at its end), and the time since the last activity
/// in a fixed column; the second has the one fact and the agent badge in
/// the same column, so every row cuts its name at the same place and the
/// columns line up.
struct SessionRowView: View {
    /// What dragging a worktree's row carries.
    struct Drag {
        let id: String
        let dragState: LimpidDragState
    }

    let row: SessionSidebarModel.Row
    /// The project the row belongs to, read out after its name.
    let projectName: String?
    /// How the row's pull request is drawn, for a row with one.
    let pullRequestMark: PRMarkPresentation?
    /// The pull request the hover card describes, which the mark opens,
    /// and the second line while it states the request.
    let pullRequestCard: (container: ContainerID, info: PRInfo)?
    /// `nil` for the project's own folder, which stays first.
    let drag: Drag?
    /// The arrow keys are on this row while the sidebar has the keyboard.
    var isKeyboardSelected = false
    let now: Date
    let actions: SessionRowActions
    /// Opens the approval card beside the row; `nil` when the row offers
    /// no Answer….
    let onAnswer: (() -> Void)?
    let onActivate: () -> Void
    /// Rename submit; `nil` for a row that cannot be renamed.
    let onRename: ((String) -> Void)?
    @Binding var isRenaming: Bool
    @Environment(\.locale) private var locale
    /// A dragged tab or pane would land here: the name takes the accent.
    @Environment(\.isDropTarget) private var isDropTarget
    @Environment(\.limpidAccent) private var accent
    @State private var isHovering = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        // Two concrete chains rather than one through a helper: a
        // conditional `.draggable` stops the drag from starting on macOS 26.
        if let drag {
            content
                .opacity(drag.dragState.currentSourceID == drag.id ? Layout.draggedItemOpacity : baseOpacity)
                .limpidDraggable(kind: .worktree, prefix: DragPrefix.worktree, id: drag.id, dragState: drag.dragState)
        } else {
            content
                .opacity(baseOpacity)
        }
    }

    /// A worktree whose folder is gone is drawn faint, and its fact says so
    /// in words (its stop).
    private var baseOpacity: Double {
        row.isMissing ? 0.5 : 1
    }

    private var content: some View {
        // The row's tooltip. The mark and the fact show the PR card in
        // its place, so the two never open over the same spot; every other
        // part of the row shows it. Put on the parts rather than the whole
        // row, so a part's empty tooltip never depends on how an inner one
        // meets an outer one.
        let tooltip = SessionRowFactText.tooltip(for: row, now: now, locale: locale)
        return HStack(alignment: .top, spacing: Layout.sessionRowColumnSpacing) {
            SessionStateGlyph(glyph: row.fact.glyph)
                .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
                .help(Text(verbatim: tooltip))
                .padding(.top, LimpidLayout.Supervision.spaceHairline)
            VStack(alignment: .leading, spacing: Layout.sessionRowLineSpacing) {
                HStack(spacing: Layout.sessionRowColumnSpacing) {
                    // The mark belongs to the name, so it sits closer than
                    // the next column does.
                    HStack(spacing: Layout.spaceXS) {
                        InlineRenameField(
                            name: row.name,
                            isEditing: $isRenaming,
                            // One weight whether or not the row is open, so
                            // opening it does not move where its name is cut;
                            // the fill says which row is open.
                            font: .supervision(.label, weight: .medium),
                            foregroundColor: isDropTarget ? accent : SupervisionTokens.text.color,
                            onRename: onRename,
                            // The repository's mark follows the name rather
                            // than the column, so the name keeps only its own
                            // width.
                            fillsWidth: !row.isMainFolder,
                            // A branch keeps both ends; a conversation's name
                            // and one the person gave keep their start.
                            truncationMode: Text.TruncationMode(row.nameTruncation),
                            // Clearing the name hands the row back to the name
                            // it would have without one.
                            submitsEmptyName: true,
                            fieldName: "Worktree label",
                            // The field edits the row's label, never its
                            // branch: a row with no label starts empty, under
                            // the name it goes by.
                            editsFrom: row.label ?? "",
                            prompt: row.label == nil ? row.name : nil
                        )
                        .lineLimit(1)
                        if row.isMainFolder {
                            RepositoryMark()
                                .help(Text(verbatim: tooltip))
                        }
                    }
                    if row.isMainFolder {
                        Spacer(minLength: 0)
                    }
                    // At least the shared column; Answer… may widen it and
                    // cut the name a little shorter while it shows.
                    trailingLineOne
                        .frame(minWidth: Layout.sessionRowTrailingColumnWidth, alignment: .trailing)
                }
                .help(Text(verbatim: tooltip))
                HStack(spacing: Layout.sessionRowColumnSpacing) {
                    lineTwo(tooltip: tooltip)
                        // The line goes ahead of the column's spacer, which
                        // would otherwise take half the free room and cut
                        // the fact short beside it.
                        .layoutPriority(1)
                    // We draw the column only with something in it: a
                    // shell's row draws no badge, and an empty column with
                    // its spacing cut the fact short beside blank room.
                    if hasTrailingMark || usageLimitChip != nil {
                        trailingLineTwo(tooltip: tooltip)
                    }
                }
            }
        }
        .modifier(SessionRowFace(
            height: Layout.sessionRowHeight,
            isActive: row.isActive,
            isHovering: isHovering,
            isKeyboardSelected: isKeyboardSelected
        ))
        // Not `.onTapGesture`: it waits out the double-click window that
        // the rename field's double-click opens, and the row would feel
        // slow to open.
        .simultaneousGesture(TapGesture().onEnded {
            if !isRenaming {
                onActivate()
            }
        })
        // Laid over the row after its tap rather than inside it, so
        // pressing Answer… does not also open the row. The first line
        // keeps a hidden copy of it, so the name is cut where the button
        // will cover it.
        .overlay(alignment: .topTrailing) {
            if isShowingAnswer, let onAnswer {
                Button(action: onAnswer) {
                    Text("Answer…")
                }
                .buttonStyle(.supervisionSecondary(size: .compact))
                // It shows only on a hovered row, whose fill is opaque.
                .environment(\.supervisionSurfaceOpacity, 1)
                .padding(Layout.sessionRowAnswerInsets)
            }
        }
        // After the overlay, so the pointer on Answer… still counts as on
        // the row; inside it, the button would hide itself as it is reached.
        .onHover { isHovering = $0 }
        .contextMenu { SessionRowActionsMenu(actions: actions) }
        // The card hangs beside the whole row, but only the mark and the
        // fact open it; the rest of the row keeps the row's tooltip,
        // and holds an open card up while the pointer crosses to it.
        .prHoverCardAnchor(pullRequestCard?.container)
        // While renaming, the field inside is what VoiceOver edits.
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(Text(verbatim: SessionRowFactText.spokenLabel(
            for: row,
            projectName: projectName,
            now: now,
            locale: locale
        )))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(row.isActive ? .isSelected : [])
        // The tap gesture opens the row for the pointer; VoiceOver and
        // other assistive tools press it through this.
        .accessibilityAction { onActivate() }
        .accessibilityActions {
            if let onAnswer {
                Button("Answer…", action: onAnswer)
            }
            // The card's one action, for a person who cannot point at the
            // mark; the right-click menu offers it too.
            if let openPullRequest = actions.openPullRequest {
                Button(action: openPullRequest.action) {
                    Text(openPullRequest.title)
                }
            }
            if let removeFromWorking = actions.removeFromWorking {
                Button("Move to Other Worktrees", action: removeFromWorking)
            }
        }
    }

    /// Draws the second line's words: a labeled row's checkout, then the
    /// fact. The checkout goes first and keeps its width, so the fact is
    /// what is cut short; the checkout is cut, in its middle as a path is,
    /// only when it does not fit by itself.
    private func lineTwo(tooltip: String) -> some View {
        let fact = SessionRowFactText.current(row, now: now, locale: locale)
        let lead = SessionRowFactText.lineLead(row, fact: fact, locale: locale)
        return HStack(spacing: 0) {
            if !lead.isEmpty {
                Text(verbatim: lead)
                    .font(.supervision(.meta))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .supervisionTruncation(.path)
                    .layoutPriority(1)
                    .help(Text(verbatim: tooltip))
            }
            if row.showsFact {
                Text(factText(fact))
                    .font(.supervision(.meta))
                    .foregroundStyle(factColor)
                    .lineLimit(1)
                    // "Write: /Users/…/notes.txt" keeps its verb and its
                    // file; prose keeps its start.
                    .supervisionTruncation(.fact(row.fact.fact))
                    // The request's words are the card's, so the
                    // fact that states it has no tooltip to open over it.
                    .help(Text(verbatim: factCard == nil ? tooltip : ""))
                    .prHoverCardPart(factCard, part: .fact)
            }
        }
    }

    /// The card the second line opens, while it states the request.
    private var factCard: (container: ContainerID, info: PRInfo)? {
        guard case .pullRequest = row.fact.fact else { return nil }
        return pullRequestCard
    }

    /// The pull request's mark, on every row with one, whatever its state:
    /// the left says the state, the right what is attached.
    private var attachedMark: PRMarkPresentation? {
        row.fact.pullRequest == nil ? nil : pullRequestMark
    }

    /// The second line after its fact: a usage limit's chip, then the pull
    /// request's mark and the agents' badges in the column the time is in. The
    /// column only grows to the left for them, so the fact is what is cut
    /// short, never a mark or a badge.
    private func trailingLineTwo(tooltip: String) -> some View {
        HStack(spacing: Layout.sessionRowColumnSpacing) {
            HStack(spacing: Layout.sessionRowColumnSpacing) {
                Spacer(minLength: 0)
                // Worded against the row's clock, so it goes once the
                // limit resets. VoiceOver reads it in the row's label.
                if let chip = usageLimitChip {
                    Text(verbatim: chip)
                        .font(.supervision(.micro, weight: .medium))
                        .foregroundStyle(SupervisionTokens.stoppedText.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, LimpidLayout.Supervision.spaceSnug)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(SupervisionTokens.stoppedText.color.opacity(0.5), lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
            .help(Text(verbatim: tooltip))
            HStack(spacing: Layout.spaceSnug) {
                if let attachedMark {
                    // The mark's own words are the card's, so it has
                    // no tooltip to open over it. VoiceOver reads the
                    // request in the row's label.
                    SessionPRMark(style: attachedMark)
                        .prHoverCardPart(pullRequestCard, part: .mark)
                }
                AgentBadgeStrip(kinds: row.agentKinds)
                    .help(Text(verbatim: tooltip))
            }
            .frame(minWidth: hasTrailingMark ? Layout.sessionRowTrailingColumnWidth : 0, alignment: .trailing)
        }
    }

    /// This is a usage limit's chip, worded against the row's clock.
    private var usageLimitChip: String? {
        SessionRowFactText.usageLimitChip(row.usageLimits, locale: locale, now: now)
    }

    /// This is true when the second line's column shows a pull request's
    /// mark or an agent's badge.
    private var hasTrailingMark: Bool {
        attachedMark != nil || !row.agentKinds.isEmpty
    }

    /// Answer… shows while the pointer is on a row that offers it,
    /// over the time rather than beside it, so the row's columns do not
    /// move.
    private var isShowingAnswer: Bool {
        isHovering && onAnswer != nil && !isRenaming
    }

    @ViewBuilder private var trailingLineOne: some View {
        if isShowingAnswer {
            // As wide as the button laid over it
            // (`SupervisionSecondaryButtonStyle`'s compact size), so the
            // name is cut where the button begins.
            Text("Answer…")
                .font(.supervision(.meta, weight: .medium))
                .fixedSize()
                .padding(.horizontal, LimpidLayout.Supervision.spaceS)
                .hidden()
        } else if let lastActivity = row.lastActivity {
            Text(verbatim: SessionRowFactText.elapsed(since: lastActivity, now: now, locale: locale))
                .font(.supervision(.meta))
                .monospacedDigit()
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
        }
    }

    /// Returns the second line's fact, with an approval's command in the monospaced face
    /// a command has.
    private func factText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let range = SessionRowFactText.commandRange(in: text, for: row),
           let lower = AttributedString.Index(range.lowerBound, within: attributed),
           let upper = AttributedString.Index(range.upperBound, within: attributed)
        {
            attributed[lower..<upper].font = .supervision(.caption, design: .monospaced)
        }
        return attributed
    }

    private var factColor: Color {
        switch row.tone {
        case .waiting: SupervisionTokens.waitingText.color
        case .stopped: SupervisionTokens.stoppedText.color
        case .muted: SupervisionTokens.muted.color
        }
    }
}

/// The mark after the name of the project's own folder's row: what the row
/// is, not a state, so it stays whatever the row's lines say. A symbol rather
/// than a word, so a long branch loses only its width. The tooltip says it in
/// words, and VoiceOver reads them in the row's label.
private struct RepositoryMark: View {
    var body: some View {
        Image(systemName: "house")
            .font(.supervision(.micro, weight: .medium))
            .foregroundStyle(SupervisionTokens.muted.color)
            .accessibilityHidden(true)
    }
}

/// The sidebar's foot bar, which holds the scratch row, on the line the
/// decision bar's and the changes panel's rules are on. The row keeps the
/// list's inset, so it lines up with the session rows above it.
struct SidebarFootBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        SupervisionFootBar(
            leadingInset: LimpidLayout.Supervision.sidebarListInset,
            trailingInset: LimpidLayout.Supervision.sidebarListInset,
            content: content
        )
    }
}

/// The scratch row: one line at the bottom for the tabs outside any
/// project. No heading and no pin; its glyph and badges say what a
/// worktree's row says of the same tabs. With no second line, its fact is in
/// its tooltip, after the folder a new tab starts in.
struct ScratchRowView: View {
    let row: SessionSidebarModel.Row
    /// Where a new scratch tab starts, as Settings says.
    let startFolder: URL
    let now: Date
    var isKeyboardSelected = false
    let actions: SessionRowActions
    /// Opens the approval card beside the row; `nil` when the row offers
    /// no Answer….
    var onAnswer: (() -> Void)?
    let onActivate: () -> Void
    /// A dragged tab or pane would land here: the name takes the accent.
    @Environment(\.isDropTarget) private var isDropTarget
    @Environment(\.limpidAccent) private var accent
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: Layout.sessionRowColumnSpacing) {
                SessionStateGlyph(glyph: row.fact.glyph)
                    .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
                Text("Scratch")
                    // The session rows' one weight.
                    .font(.supervision(.label, weight: .medium))
                    .foregroundStyle(isDropTarget ? accent : SupervisionTokens.text.color)
                Spacer(minLength: LimpidLayout.Supervision.spaceXS)
                AgentBadgeStrip(kinds: row.agentKinds)
            }
            // The workspace rows' face, only shorter, so the open scratch
            // row is filled and inset as an open workspace row is.
            .modifier(SessionRowFace(
                height: Layout.scratchRowHeight,
                isActive: row.isActive,
                isHovering: isHovering,
                isKeyboardSelected: isKeyboardSelected
            ))
        }
        .buttonStyle(.plain)
        // Out of ⇥'s stops, as every other line of the sidebar is: its
        // keyboard is ⌥⌘0 and the arrows.
        .focusable(false)
        // Over the badges rather than beside them, so the row does not
        // move; beside the row's button, so pressing it does not open the row.
        .overlay(alignment: .trailing) {
            if isHovering, let onAnswer {
                Button(action: onAnswer) {
                    Text("Answer…")
                }
                .buttonStyle(.supervisionSecondary(size: .compact))
                // It shows only on a hovered row, whose fill is opaque.
                .environment(\.supervisionSurfaceOpacity, 1)
                .padding(.trailing, Layout.spaceXS)
            }
        }
        // After the overlay, so the pointer on Answer… still counts as on
        // the row.
        .onHover { isHovering = $0 }
        .contextMenu { SessionRowActionsMenu(actions: actions) }
        .help(Text(verbatim: SessionRowFactText.scratchTooltip(for: row, startFolder: startFolder, now: now, locale: locale)))
        .accessibilityLabel(Text(verbatim: SessionRowFactText.spokenLabel(
            for: row,
            projectName: nil,
            now: now,
            locale: locale
        )))
        .accessibilityHint(Text(verbatim: SessionRowFactText.scratchHint(startFolder: startFolder, locale: locale)))
        .accessibilityAddTraits(row.isActive ? .isSelected : [])
        .accessibilityActions {
            if let onAnswer {
                Button("Answer…", action: onAnswer)
            }
        }
    }
}

/// A sidebar row's face: its words inset in its fill, the fill that says
/// it is open or hovered, and the ring the arrow keys put on it, in the
/// row's corners. The workspace rows and the scratch row both draw theirs
/// through this, so the one never drifts from the other; only the height
/// differs, the scratch row's fitting the sidebar's foot bar.
struct SessionRowFace: ViewModifier {
    let height: CGFloat
    let isActive: Bool
    let isHovering: Bool
    let isKeyboardSelected: Bool
    /// Optional: a row drawn outside a window, as a test draws one, has no
    /// drag to read.
    @Environment(LimpidDragState.self) private var dragState: LimpidDragState?

    private typealias Layout = LimpidLayout.Supervision

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Layout.sessionRowCornerRadius, style: .continuous)
        // A drag reports no hover ending, so the line it started over or
        // passed would stay filled for as long as it lasts, beside the mark
        // of where the drag would land.
        let isHovered = isHovering && dragState?.current == nil
        content
            .padding(.horizontal, Layout.sessionRowHorizontalInset)
            .frame(height: height)
            .background(shape.fill(SessionRowFill.color(isActive: isActive, isHovering: isHovered)))
            // On the row's edge rather than outside it: the rows sit close,
            // and a ring outside would reach into the next one.
            .supervisionFocusRing(
                isFocused: isKeyboardSelected,
                cornerRadius: Layout.sessionRowCornerRadius,
                placement: .onEdge
            )
            .contentShape(Rectangle())
    }
}

/// A sidebar row's fill: `selection` for the open row, `hover` under the
/// pointer. The surface's tokens rather than a tint of the text color, so
/// the fills match the rest of the window's selected and hovered rows.
enum SessionRowFill {
    static func color(isActive: Bool, isHovering: Bool) -> Color {
        if isActive {
            return SupervisionTokens.selection.color
        }
        return isHovering ? SupervisionTokens.hover.color : .clear
    }
}
