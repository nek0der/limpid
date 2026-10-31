// SidebarProjectHeaderView.swift
// Limpid — a project's header in the sidebar: its mark, its name, a rule to the edge, its count, and its fold.

import AppKit
import SwiftUI

/// A project's header, 28pt: `[mark] name ─── count ▼`. The rule
/// runs from the name to the count, so where one project ends and the next
/// begins reads at a glance. A folded header shows what waits or runs
/// inside it before its count; one another window shows says so in place
/// of the count, and pressing that brings the window forward. Its ＋ makes
/// a new worktree in the project, and is always shown: the sidebar
/// heading's ＋ opens a folder as a project, so this is the one in view
/// for a worktree.
///
/// Pressing anywhere on it opens or folds it, ⌥ held for every header; it
/// never switches the window's project, which a row does. It is dragged
/// to reorder the projects, on a layer over the list
/// (`SidebarProjectReorderLayer`). A dragged tab dropped on it goes to the
/// project's repository row; one that rests on it while it is folded opens it
/// for the drag (`LimpidMotion.springOpenDelay`), as its ring fills.
struct SidebarProjectHeaderView: View {
    let header: SidebarProjectHeader
    /// The arrow keys are on this header while the sidebar has the keyboard.
    var isKeyboardSelected = false
    let actions: SidebarProjectActions
    /// Opens or folds the header; `true` for every header (⌥-click).
    let onToggle: (_ isAll: Bool) -> Void
    /// What dragging the header does.
    let drag: Drag
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.limpidAccent) private var accent
    @State private var isHovering = false

    /// The drag of the header.
    struct Drag {
        let dragState: LimpidDragState
        /// What a tab or pane dropped on the header does.
        let rowDrop: SidebarRowDrop
        /// This window drags this header: another window showing the list
        /// draws no layer, so it keeps its own.
        let hidesHeader: Bool
        /// Pressed at this height in the list, with the pointer now at this one.
        let onMove: (_ startY: CGFloat, _ pointerY: CGFloat) -> Void
    }

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        content
            // The reorder layer draws it while it is held.
            .opacity(drag.hidesHeader ? 0 : 1)
            .gesture(
                DragGesture(minimumDistance: Layout.sidebarHeaderDragThreshold, coordinateSpace: .named(SidebarProjectDragSurface.space))
                    .onChanged { drag.onMove($0.startLocation.y, $0.location.y) }
                    .onEnded { _ in drag.dragState.end() }
            )
            .reorderableDropTarget(
                targetID: targetID,
                acceptedPrefixes: [DragPrefix.tab, DragPrefix.pane],
                // A tab dropped here lands on the repository row, which is
                // marked in its place.
                assignsOnDrop: true,
                rowMark: .none,
                project: project,
                isNoOp: { source, _ in drag.rowDrop.refuses(source, on: repositoryRow) },
                onDrop: { prefix, source, _ in drag.rowDrop.drop(prefix: prefix, source, on: repositoryRow) }
            )
            // The wait before a folded header opens under a resting tab;
            // the tab moving off it, or the drag ending, cancels it.
            .onChange(of: isCarriedResting) { _, isResting in
                if isResting {
                    drag.dragState.beginRest(on: project)
                } else {
                    drag.dragState.endRest(on: project)
                }
            }
    }

    private var targetID: String {
        SidebarDropTarget.header(header.id, in: drag.rowDrop.window)
    }

    private var project: SidebarDropProject {
        SidebarDropProject(window: drag.rowDrop.window, projectID: header.id)
    }

    /// Where a tab or pane dropped on the header goes.
    private var repositoryRow: ContainerID {
        .project(header.id)
    }

    /// A dragged tab or pane is on this folded header, which opens once it has
    /// rested there.
    private var isCarriedResting: Bool {
        header.isCollapsed && drag.dragState.isCarryingToRow && drag.dragState.hoverTargetID == targetID
    }

    /// A dragged tab or pane is over this project, at its header or at one of its
    /// rows: the name and the rule take the accent, over the project's mark.
    private var isCarriedOverProject: Bool {
        drag.dragState.isCarryingToRow && drag.dragState.carriedOverProject == project
    }

    private var content: some View {
        let contents = SidebarHeaderText.contents(
            header.marks.map { StateGlyph.Kind($0).name.resolved(in: locale) },
            locale: locale
        )
        return HStack(spacing: Layout.spaceSnug) {
            ProjectAvatar(name: header.name, paletteIndex: header.paletteIndex, size: .header)
            // The name is what a narrow sidebar cuts first, then the count,
            // then the marks; the ＋ and the fold stay.
            Text(verbatim: header.name)
                .font(.supervision(.label, weight: header.isCollapsed ? .medium : .bold))
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .supervisionTruncation(.name)
                .layoutPriority(1)
            Rectangle()
                .fill(isCarriedOverProject ? accent : SupervisionTokens.line.color)
                .frame(height: 1)
                .frame(minWidth: Layout.spaceM)
                .accessibilityHidden(true)
            if !header.marks.isEmpty {
                HStack(spacing: Layout.spaceXS) {
                    ForEach(Array(header.marks.enumerated()), id: \.offset) { _, mark in
                        Self.mark(mark)
                    }
                }
                .help(Text(verbatim: contents ?? ""))
                .layoutPriority(3)
            }
            trailingMark
                .layoutPriority(2)
            // The sidebar heading's ＋ in its header's size: muted at rest,
            // and filled under the pointer, so it reads as a click of its
            // own rather than part of the header's fold. It keeps less room
            // beside it than the heading's: the heading's room set it apart
            // from the count and the fold by more than they are from each
            // other.
            Button(action: actions.newWorktree) {
                Image(systemName: "plus")
                    .font(.supervision(.row, weight: .medium))
                    .frame(height: Layout.sidebarHeadingButtonHeight)
            }
            .buttonStyle(.supervisionIcon(horizontalPadding: Layout.spaceXS))
            // The pointer's alone: the keyboard and VoiceOver reach it
            // through the header's actions and its menu.
            .focusable(false)
            .help(Text(SidebarHeaderText.newWorktree(in: header.name)))
            .accessibilityHidden(true)
            .layoutPriority(4)
            Group {
                if isCarriedResting {
                    SpringOpenRing()
                } else {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.supervision(.disclosure, weight: .semibold))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .rotationEffect(.degrees(header.isCollapsed ? 0 : 90))
                        .animation(reduceMotion ? nil : LimpidMotion.reorder, value: header.isCollapsed)
                }
            }
            .frame(width: Layout.stateGlyphSize)
            .accessibilityHidden(true)
            .layoutPriority(4)
        }
        .modifier(SessionRowFace(
            height: Layout.sidebarProjectHeaderHeight,
            isActive: false,
            isHovering: isHovering,
            isKeyboardSelected: isKeyboardSelected
        ))
        // Below the ＋ and the Other Window mark, which take their own
        // clicks rather than also folding the header.
        .onTapGesture { onToggle(Self.isOptionClick) }
        .onHover { isHovering = $0 }
        .contextMenu { SidebarProjectActionsMenu(header: header, actions: actions) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: SidebarHeaderText.accessibilityLabel(header, locale: locale)))
        .accessibilityValue(Text(SidebarSectionText.state(isOpen: !header.isCollapsed)))
        .accessibilityHint(contents.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction { actions.toggle() }
        .accessibilityActions {
            Button(action: actions.toggle) {
                Text(header.isCollapsed ? SidebarProjectActionText.expand : SidebarProjectActionText.collapse)
            }
            if actions.canMoveUp {
                Button(action: actions.moveUp) { Text(SidebarProjectActionText.moveUp) }
                Button(action: actions.moveToTop) { Text(SidebarProjectActionText.moveToTop) }
            }
            if actions.canMoveDown {
                Button(action: actions.moveDown) { Text(SidebarProjectActionText.moveDown) }
            }
            Button(action: actions.newWorktree) { Text(SidebarHeaderText.newWorktree(in: header.name)) }
            Button(action: actions.syncWorktrees) { Text(SidebarProjectActionText.syncWorktrees) }
            if let showHiddenWorktrees = actions.showHiddenWorktrees {
                Button(action: showHiddenWorktrees) { Text(SidebarProjectActionText.showHiddenWorktrees) }
            }
            if let removeMissingWorktrees = actions.removeMissingWorktrees {
                Button(action: removeMissingWorktrees) { Text(SidebarProjectActionText.removeMissingWorktrees) }
            }
            if let bringOtherWindowForward = actions.bringOtherWindowForward {
                Button(action: bringOtherWindowForward) { Text(SidebarProjectActionText.bringForward) }
            }
        }
    }

    /// The name's color: the accent while a dragged tab or pane is over the
    /// project, else muted while it is folded.
    private var nameColor: Color {
        if isCarriedOverProject {
            return accent
        }
        return header.isCollapsed ? SupervisionTokens.muted.color : SupervisionTokens.text.color
    }

    /// The count, or "Other Window" for a project another window shows,
    /// which brings that window forward.
    @ViewBuilder private var trailingMark: some View {
        if header.isInOtherWindow, let bringForward = actions.bringOtherWindowForward {
            Button(action: bringForward) {
                Text("Other Window", comment: "Another window shows this project: choosing it brings that window forward")
                    .font(.supervision(.micro))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .padding(.horizontal, Layout.spaceXS)
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.spaceXS, style: .continuous)
                            .strokeBorder(SupervisionTokens.line.color, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(Text(SidebarHeaderText.otherWindowHelp(header.name)))
        } else if let count = SidebarHeaderText.count(header, locale: locale) {
            Text(verbatim: count)
                .font(.supervision(.detail))
                .monospacedDigit()
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
        }
    }

    /// One of a folded header's marks, at the compact size a tab's mark
    /// shares, so they keep their gaps beside the count.
    static func mark(_ glyph: SessionRowFact.Glyph) -> SessionStateGlyph {
        SessionStateGlyph(glyph: glyph, size: Layout.sidebarHeaderMarkSize)
    }

    /// Whether the click being handled held ⌥ alone: the one that opens or
    /// folds every header. Read from the click AppKit is handling, as a
    /// ⌘-click is (`NewWindowModifier.isCommandClick`).
    private static var isOptionClick: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return event.modifierFlags.chord == .option
    }
}

/// A folded header's fold while a dragged tab or pane rests on it: a ring that
/// fills over the wait (`LimpidMotion.springOpenDelay`), and the header
/// opens as it closes. Under Reduce Motion it stands full from the start,
/// and the header still opens after the same wait.
private struct SpringOpenRing: View {
    @Environment(\.limpidAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let width = Layout.dropTargetRingWidth
        ZStack {
            Circle()
                .stroke(SupervisionTokens.line.color, lineWidth: width)
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : progress)
                .stroke(accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
        .frame(width: Layout.sidebarHeaderMarkSize, height: Layout.sidebarHeaderMarkSize)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(LimpidMotion.springOpenFill) {
                progress = 1
            }
        }
    }
}
