// SidebarSectionFoldRow.swift
// Weir — the line a section of the sidebar folds into: "▸ Other Worktrees 52".

import SwiftUI

/// One of the lists that fold into a line, 26pt: a chevron, the list's
/// name, how many rows it holds, and at its end, under the pointer, the
/// button that clears the list when it has one (Delete Worktrees…, Remove
/// All from Sidebar). Pressing it opens or folds the list; the rows under
/// it are drawn only while it is open.
struct SidebarSectionFoldRow: View {
    let fold: SessionSidebarModel.Fold
    /// The arrow keys are on this line while the sidebar has the keyboard.
    var isKeyboardSelected = false
    /// The line's one action, as its button at the line's end; `nil` for a
    /// list with none. The line has no right-click menu: the button is
    /// the one thing to do there.
    var clear: SidebarFoldClear?
    let onToggle: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Layout.spaceSnug) {
                Image(systemName: "chevron.right")
                    .font(.supervision(.micro, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .rotationEffect(.degrees(fold.isOpen ? 90 : 0))
                    .animation(reduceMotion ? nil : WeirMotion.reorder, value: fold.isOpen)
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
                // Room for the button laid over the line's end, so a narrow
                // sidebar cuts the name before it runs under the glyph.
                if clear != nil {
                    Color.clear.frame(width: Layout.stateGlyphSize, height: 1)
                }
            }
            .modifier(SessionRowFace(
                height: Layout.sidebarFoldRowHeight,
                isActive: false,
                isHovering: isHovering,
                isKeyboardSelected: isKeyboardSelected
            ))
        }
        .buttonStyle(.plain)
        // Over the line rather than in it, so a press on it is its own and
        // does not also fold the list; inside the hover, so the line stays
        // lit under it.
        .overlay(alignment: .trailing) { clearButton }
        // Out of ⇥'s stops, as every line of the sidebar is: the keyboard's way
        // through the sidebar is ⌥⌘0 and the arrows, and ⇥ stopping
        // on these lines alone said nothing of where it was. VoiceOver
        // still reaches it as a button.
        .focusable(false)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: SidebarSectionText.accessibilityLabel(fold.section, count: fold.count, locale: locale)))
        .accessibilityValue(Text(SidebarSectionText.state(isOpen: fold.isOpen)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
        // The button's action, for a person who cannot point at it.
        .accessibilityActions {
            if let clear {
                Button(action: clear.action) { Text(clear.kind.name) }
            }
        }
    }

    /// The line's one way to clear its list, as a glyph at the line's end,
    /// where the project header has its fold. It shows only under the
    /// pointer: at rest a glyph on every fold line drew the eye away from
    /// the rows, and clearing a list is not what the line is for.
    @ViewBuilder private var clearButton: some View {
        if let clear {
            clearButton(clear)
        }
    }

    private func clearButton(_ clear: SidebarFoldClear) -> some View {
        Button(action: clear.action) {
            Image(systemName: clear.kind.systemImage)
                .font(.supervision(.micro, weight: .medium))
                .frame(width: Layout.stateGlyphSize, height: Layout.sidebarHeadingButtonHeight)
        }
        .buttonStyle(.supervisionIcon(horizontalPadding: Layout.spaceXS))
        // Hidden rather than left out, so the line does not shift as the
        // pointer comes and goes.
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        // The glyph stands where the header's fold does: the row's inset
        // less the room the button keeps beside it.
        .padding(.trailing, Layout.sessionRowHorizontalInset - Layout.spaceXS)
        // The pointer's alone: VoiceOver reaches it through the line's
        // actions.
        .focusable(false)
        // AppKit's own tooltip: `.help` never showed here, on a button laid
        // over another button.
        .trackedHelp(clear.kind.name.resolved(in: locale))
        .accessibilityHidden(true)
    }
}

/// What a fold line's button does to the rows under it.
struct SidebarFoldClear {
    enum Kind {
        /// Deletes the worktrees ready to clean up with `git worktree
        /// remove`, after a confirmation; their branches stay.
        case deleteAll
        /// Removes the missing worktrees' rows: their folders are gone, so
        /// there is nothing left to keep.
        case removeAll

        /// The button's tooltip and its VoiceOver action.
        var name: LocalizedStringResource {
            switch self {
            case .deleteAll: "Delete Worktrees…"
            case .removeAll: "Remove All from Sidebar"
            }
        }

        /// One glyph for both: each takes the rows off the list, and the
        /// confirmation, not the glyph, says what Delete Worktrees… does to
        /// the folders.
        var systemImage: String {
            "xmark"
        }
    }

    let kind: Kind
    let action: () -> Void
}
