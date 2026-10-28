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
/// to reorder the projects, and a dragged header drops at a line.
struct SidebarProjectHeaderView: View {
    let header: SidebarProjectHeader
    /// The arrow keys are on this header while the sidebar has the keyboard.
    var isKeyboardSelected = false
    let actions: SidebarProjectActions
    /// Opens or folds the header; `true` for every header (⌥-click).
    let onToggle: (_ isAll: Bool) -> Void
    /// What dragging the header carries, and where a dragged one lands.
    let drag: Drag
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// The drag of the header, and the drop of another on it.
    struct Drag {
        let dragState: LimpidDragState
        /// Whether dropping `source` at `position` of this header would
        /// leave the order as it is.
        let isNoOp: (_ source: UUID, _ position: DropPosition) -> Bool
        /// Drops `source` at `position` of this header.
        let onDrop: (_ source: UUID, _ position: DropPosition) -> Void
    }

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        content
            .opacity(drag.dragState.currentSourceID == header.id.uuidString ? Layout.draggedItemOpacity : 1)
            .limpidDraggable(kind: .project, prefix: "project:", id: header.id.uuidString, dragState: drag.dragState)
            .reorderableDropTarget(
                targetID: "header-\(header.id)",
                acceptedPrefixes: ["project:"],
                dropsAtLine: true,
                isNoOp: drag.isNoOp,
                onDrop: { _, source, position in drag.onDrop(source, position) }
            )
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
                .foregroundStyle(header.isCollapsed ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                .lineLimit(1)
                .supervisionTruncation(.name)
                .layoutPriority(1)
            Rectangle()
                .fill(SupervisionTokens.line.color)
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
            Image(systemName: "arrowtriangle.right.fill")
                .font(.supervision(.disclosure, weight: .semibold))
                .foregroundStyle(SupervisionTokens.muted.color)
                .rotationEffect(.degrees(header.isCollapsed ? 0 : 90))
                .animation(reduceMotion ? nil : LimpidMotion.reorder, value: header.isCollapsed)
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
