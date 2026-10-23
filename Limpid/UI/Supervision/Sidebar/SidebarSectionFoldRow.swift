// SidebarSectionFoldRow.swift
// Limpid — the line a section of the sidebar folds into: "▸ Other Worktrees 52".

import SwiftUI

/// One of the two lists that fold into a line, 26pt: a chevron, the
/// list's name, and how many rows it holds. Pressing it opens or folds the
/// list; the rows under it are drawn only while it is open.
struct SidebarSectionFoldRow: View {
    let fold: SessionSidebarModel.Fold
    /// The arrow keys are on this line while the sidebar has the keyboard.
    var isKeyboardSelected = false
    /// The line's right-click menu: "Hide All" on the rows ready to clean up.
    var menu: SessionRowActions = .init()
    let onToggle: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Layout.spaceSnug) {
                Image(systemName: "chevron.right")
                    .font(.supervision(.micro, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .rotationEffect(.degrees(fold.isOpen ? 90 : 0))
                    .animation(reduceMotion ? nil : LimpidMotion.reorder, value: fold.isOpen)
                    .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
                    .accessibilityHidden(true)
                if let title = SidebarSectionText.title(fold.section) {
                    Text(title)
                        .font(.supervision(.meta, weight: .medium))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(1)
                }
                Text(verbatim: "\(fold.count)")
                    .font(.supervision(.meta))
                    .monospacedDigit()
                    .foregroundStyle(SupervisionTokens.muted.color)
                Spacer(minLength: 0)
            }
            .modifier(SessionRowFace(
                height: Layout.sidebarFoldRowHeight,
                isActive: false,
                isHovering: isHovering,
                isKeyboardSelected: isKeyboardSelected
            ))
        }
        .buttonStyle(.plain)
        // Out of ⇥'s stops, as every line of the sidebar is: the keyboard's way
        // through the sidebar is ⌥⌘0 and the arrows, and ⇥ stopping
        // on these lines alone said nothing of where it was. VoiceOver
        // still reaches it as a button.
        .focusable(false)
        .onHover { isHovering = $0 }
        .contextMenu { SessionRowActionsMenu(actions: menu) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: SidebarSectionText.accessibilityLabel(fold.section, count: fold.count, locale: locale)))
        .accessibilityValue(Text(SidebarSectionText.state(isOpen: fold.isOpen)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
        // The right-click menu's entry, for a person who cannot open it.
        .accessibilityActions {
            if let hideAll = menu.hideAll {
                Button("Hide All", action: hideAll)
            }
        }
    }
}
