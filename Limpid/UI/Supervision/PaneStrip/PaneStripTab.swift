// PaneStripTab.swift
// Limpid — one tab of the pane strip: its state, its badge, its title, and the marks the tab list shows.

import SwiftUI

/// A tab in the pane strip. The title is the tab list's (a name the
/// person gave, else the terminal's OSC 2 title, else the process), led by
/// the badge of who runs in it (Cl, Cx, or a shell's prompt) with the
/// sidebar's state glyph on the badge's corner (the turning arc while an
/// agent runs, the amber "?" while one waits on the person, the red "!"
/// once one stopped, nothing at rest), and followed by the tab list's marks: the exit code of
/// a process that failed, tmux's mark, and a dot that says a command
/// finished, a notification came, or the bell rang since the tab was last
/// shown. A turn's "unread" shows on neither, as it is not urgent.
///
/// A tab is a folder tab: the selected one is edged in `line` and opens
/// onto the terminal below it (`PaneStripRule`).
struct PaneStripTab: View {
    let item: PaneStripModel.Item
    let onActivate: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    /// Tells the strip which tab is being renamed.
    let onEditingChanged: (Bool) -> Void
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(LimpidDragState.self) private var dragState
    /// The window the strip is in, which ⇧⌘R names.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @State private var isEditing = false
    @State private var isHovering = false

    private var isBeingDragged: Bool {
        dragState.current == .tab && dragState.currentSourceID == item.id.uuidString
    }

    var body: some View {
        let layout = LimpidLayout.Supervision.self
        HStack(spacing: layout.paneStripTabSpacing) {
            // The color a scratch tab kept from its group. Its name
            // prefix says the same in words, so the mark is not read out.
            if let paletteIndex = item.paletteIndex {
                Circle()
                    .fill(LimpidColor.paletteColor(paletteIndex))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            // The state is laid on the badge's corner, so it takes no
            // place of its own: the tab's width and its title stay put as
            // the agent starts, waits, and stops, and a tab at rest leaves
            // no gap where a glyph would be. The tab's label says the state
            // in words, so VoiceOver skips it.
            PaneStripTabBadge(agent: item.agent, state: item.stateGlyph)
            InlineRenameField(
                name: item.title,
                isEditing: $isEditing,
                font: .supervision(.label, weight: .medium),
                foregroundColor: item.isActive || isHovering ? SupervisionTokens.text.color : SupervisionTokens.muted.color,
                onRename: onRename,
                // A tab is as wide as what it holds, not the strip's width.
                fillsWidth: false,
                truncationMode: Text.TruncationMode(item.titleTruncation),
                // While it is renamed the title is as wide as what is typed,
                // to the same limit as at rest, even where the strip had
                // cut it to share its width.
                editingWidthLimit: layout.paneStripTitleMaxWidth,
                fieldName: "Tab name"
            )
            // A long title is cut, so one tab never crowds out the rest; the
            // field is laid over the title's own frame (`InlineRenameField`).
            .frame(maxWidth: layout.paneStripTitleMaxWidth, alignment: .leading)
            .layoutPriority(1)
            // ⇧⌘R asks this of the window; only the tab it names begins
            // renaming.
            .onWindowCommand(of: window) { command in
                guard command == .renameTab(item.id) else { return false }
                if !isEditing {
                    isEditing = true
                }
                return true
            }
            PaneStripTabMarks(item: item)
            closeButton
        }
        .padding(.leading, layout.paneStripTabHorizontalPadding)
        .padding(.trailing, layout.paneStripTabTrailingInset)
        // Centered over the strip's rule rather than across it, so a
        // tab's line sits evenly between the strip's top and the rule.
        .padding(.bottom, layout.paneStripRuleWidth)
        .frame(height: layout.paneStripHeight)
        .folderTabFace(isSelected: item.isActive, isHovering: isHovering, scrolls: true)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: isEditing) { _, isEditing in
            onEditingChanged(isEditing)
        }
        // Not `.onTapGesture`, which waits out the rename field's
        // double-click window and makes switching tabs feel a beat late.
        .simultaneousGesture(TapGesture().onEnded {
            if !isEditing {
                onActivate()
            }
        })
        .trackedHelp(item.tooltip(locale: locale))
        .contextMenu { menu }
        // The tab being dragged stands faint in the place it would land,
        // as a sidebar row being dragged does: the tabs move aside for it
        // as the pointer crosses them, so its place is the drop's mark.
        .opacity(isBeingDragged ? LimpidLayout.Supervision.draggedItemOpacity : 1)
        .limpidDraggable(kind: .tab, prefix: "tab:", id: item.id.uuidString, dragState: dragState)
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(Text(verbatim: item.spokenLabel(locale: locale)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(item.isActive ? .isSelected : [])
        .accessibilityAction { onActivate() }
        .accessibilityActions {
            Button("Rename…") { isEditing = true }
            Button("Close Tab", action: onClose)
        }
    }

    /// Present only while the tab is selected or under the pointer. The
    /// strip keeps its place the rest of the time, so a tab, as wide as
    /// what it holds, does not widen under the pointer and push the tabs
    /// after it along; hidden, it is neither pressed, reached by the
    /// keyboard, nor read.
    private var closeButton: some View {
        let isShown = item.isActive || isHovering
        return DismissGlyphButton(label: "Close Tab", action: onClose)
            .opacity(isShown ? 1 : 0)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }

    /// The menu the tab list's rows have, with the same keys shown.
    @ViewBuilder private var menu: some View {
        let keyboard = settingsStore.settings.keyboard
        Button {
            isEditing = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        .contextMenuShortcut(MenuCommand.renameTab.shortcut(in: keyboard))
        .tint(Color.primary)
        Divider()
        Button(role: .destructive, action: onClose) {
            Label("Close", systemImage: "xmark")
        }
        .contextMenuShortcut(MenuCommand.closeTab.shortcut(in: keyboard))
        .tint(Color.primary)
    }
}

/// Who runs in a tab: Claude's or Codex's badge, as the sidebar's
/// rows wear it, or a shell's prompt in the shell badge's outline. The
/// tab's label says what runs in it, so VoiceOver skips the badge.
///
/// An agent's badge carries the tab's state (`PaneStripModel.tabGlyph`)
/// on its bottom trailing corner: the state glyph, small, in a ring cut
/// out of the badge so it stands apart from the brand's color on whatever
/// ground the tab has (selected, hovered, or at rest, translucent or not).
/// Laid over the badge, so it takes no width.
struct PaneStripTabBadge: View {
    let agent: AgentKind?
    var state: SessionRowFact.Glyph?
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        if let agent {
            SessionAgentBadge(
                badge: .agent(agent),
                text: SessionRowFactText.badge(.agent(agent), locale: locale),
                size: .regular
            )
            // Cut whether or not a state shows, so the badge keeps its
            // identity as the state comes and goes.
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        if state != nil {
                            Circle()
                                .frame(width: ringDiameter, height: ringDiameter)
                                .offset(x: ringOutset, y: ringOutset)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                if let state {
                    StateGlyph(kind: StateGlyph.Kind(state), size: Layout.tabStateMarkSize)
                        .offset(x: Layout.tabStateMarkOutset, y: Layout.tabStateMarkOutset)
                        .accessibilityHidden(true)
                }
            }
        } else {
            ShellPromptBadge()
        }
    }

    /// The cut is the mark and its ring, centered where the mark is.
    private var ringDiameter: CGFloat {
        Layout.tabStateMarkSize + Layout.tabStateMarkRing * 2
    }

    private var ringOutset: CGFloat {
        Layout.tabStateMarkOutset + Layout.tabStateMarkRing
    }
}

/// A tab's marks after its title: the failed exit, tmux, then the dot for
/// unread output, most lasting first, so the dot that comes and goes
/// is last and moves nothing when it does. Open Tabs draws them after a
/// row's title too.
struct PaneStripTabMarks: View {
    let item: PaneStripModel.Item
    @Environment(\.locale) private var locale

    var body: some View {
        let layout = LimpidLayout.Supervision.self
        let markShape = RoundedRectangle(cornerRadius: layout.tabMarkCornerRadius, style: .continuous)
        if let mark = item.exitMark(locale: locale) {
            Text(verbatim: mark)
                .font(.supervision(.detail, design: .monospaced))
                .foregroundStyle(SupervisionTokens.stoppedText.color)
                .padding(layout.exitMarkInsets)
                .background(markShape.fill(SupervisionTokens.stoppedFill.color))
                .fixedSize()
        }
        if item.isInTmux {
            // Product name, the same in every language.
            Text(verbatim: "tmux")
                .font(.supervision(.micro, design: .monospaced))
                .foregroundStyle(SupervisionTokens.muted.color)
                .padding(.horizontal, layout.tmuxMarkHorizontalPadding)
                .frame(height: layout.tmuxMarkHeight)
                .overlay(markShape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
                .fixedSize()
                .help(Text("Running in tmux — the session survives quitting Limpid"))
        }
        if item.hasUnread {
            // A filled dot in a neutral tone: a turn's unread is a blue
            // ring, and this one means something else, so it takes
            // neither the ring's shape nor its blue.
            Circle()
                .fill(SupervisionTokens.muted.color)
                .frame(width: layout.tabUnreadDotSize, height: layout.tabUnreadDotSize)
        }
    }
}

extension View {
    /// A strip tab's face: the selected
    /// tab is edged in `line` up its sides and over its top corners, with
    /// nothing filled, so it is the surface the terminal stands on, and the
    /// strip's rule stops under it (`PaneStripRule`); any other tab has
    /// neither edge nor fill until the pointer is on it, when `hover` fills
    /// it down to the rule. The terminal is drawn on that surface, so the
    /// selected tab needs no fill of its own to read as the terminal's
    /// ground. The hover fill stays opaque whatever the background opacity,
    /// as the rows' hover and selection do: the tab's text is held at 4.5:1
    /// on that fill, which a fill mixed with the glass behind it could
    /// not promise.
    func folderTabFace(isSelected: Bool, isHovering: Bool, scrolls: Bool) -> some View {
        let layout = LimpidLayout.Supervision.self
        return background {
            if !isSelected, isHovering {
                UnevenRoundedRectangle(
                    topLeadingRadius: layout.paneStripTabCornerRadius,
                    topTrailingRadius: layout.paneStripTabCornerRadius,
                    style: .circular
                )
                .fill(SupervisionTokens.hover.color)
                // Down to the rule, not over it: the rule runs whole under
                // a tab that is not selected.
                .padding(.bottom, layout.paneStripRuleWidth)
            }
        }
        .overlay {
            if isSelected {
                FolderTabEdge(cornerRadius: layout.paneStripTabCornerRadius)
                    .stroke(SupervisionTokens.line.color, lineWidth: layout.paneStripRuleWidth)
                    .allowsHitTesting(false)
            }
        }
        .stripTabSelection(isSelected, scrolls: scrolls)
    }
}

/// A folder tab's edge: up its sides and over its rounded top, open along
/// the bottom, where the selected tab meets the terminal.
struct FolderTabEdge: Shape {
    /// The radius of the edge's outer side, as CSS's `border-radius` is,
    /// so the stroke's outer side, not its middle, has the given radius.
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Half a line in from the sides and the top, so the whole stroke
        // lands inside the tab; the sides run on to the bottom edge, where
        // the strip's rule stops at the tab's outer edge
        // (`PaneStripRuleLayout`) and so meets them square, with no gap
        // and no line drawn twice. The stroke's middle turns half a line
        // inside the outer radius.
        let half = LimpidLayout.Supervision.paneStripRuleWidth / 2
        let left = rect.minX + half
        let right = rect.maxX - half
        let top = rect.minY + half
        let radius = max(0, min(cornerRadius - half, (right - left) / 2))
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + radius, y: top), radius: radius)
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + radius), radius: radius)
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        return path
    }
}

/// Where the strip's selected tab is, so the rule under the strip can
/// stop for it.
struct SelectedStripTab: Equatable {
    /// The tab's frame in the strip's own space.
    let frame: CGRect
    /// Whether the tab is one of the tabs that scroll (the terminal tabs
    /// and the review's), and so can be seen only within the scroll view.
    let scrolls: Bool
}

struct SelectedStripTabKey: PreferenceKey {
    static let defaultValue: SelectedStripTab? = nil

    static func reduce(value: inout SelectedStripTab?, nextValue: () -> SelectedStripTab?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Reports this strip tab's frame while it is the selected one.
    func stripTabSelection(_ isSelected: Bool, scrolls: Bool) -> some View {
        background {
            if isSelected {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SelectedStripTabKey.self,
                        value: SelectedStripTab(frame: proxy.frame(in: .named(PaneStripView.coordinateSpace)), scrolls: scrolls)
                    )
                }
            }
        }
    }
}
