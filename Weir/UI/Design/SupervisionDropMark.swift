// SupervisionDropMark.swift
// Weir — how the supervision window marks the place a drag would land.

import SwiftUI

/// Where a dragged tab or pane would land among the panes and the pane
/// strip, drawn one way there: a ring in the accent, a step thinner than the
/// keyboard's ring (`dropTargetRingWidth`), in the target's own shape, over
/// the accent's soft tone. The mark takes the language the window's other
/// marks already speak rather than macOS's default drop highlight, so a
/// drop target reads as the same kind of place as a focused one. The
/// soft tone is translucent so what the target holds (a tab's title, a
/// pane's lines) still reads under it. The sidebar marks its rows apart
/// (`SupervisionRowDropMark`), inside the project they belong to.
struct SupervisionDropMark<S: InsettableShape>: View {
    let shape: S
    @Environment(\.weirAccent) private var accent

    var body: some View {
        ZStack {
            shape.fill(accent.opacity(SupervisionTokens.dropTargetFillOpacity))
            shape.strokeBorder(accent, lineWidth: WeirLayout.Supervision.dropTargetRingWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A sidebar row a dragged tab or pane would move to: the accent's soft tone over
/// the whole row, with no ring. The row sits inside its project's own mark
/// (`SupervisionProjectDropMark`), and a ring around one row inside that
/// read as one frame too many; the deeper tone, and the row's name in the
/// accent (`isDropTarget`), say which row of the project it is. Laid over
/// the row rather than under it, so the fill of the open row does not
/// hide it.
struct SupervisionRowDropMark: ViewModifier {
    let isTargeted: Bool
    let cornerRadius: CGFloat
    @Environment(\.weirAccent) private var accent

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(accent.opacity(SupervisionTokens.dropTargetFillOpacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
    }
}

/// One line of a project in the sidebar that a dragged tab or pane is over, at its
/// header or at any of its rows: the accent's faintest tone behind every
/// line of the project, so the project reads as one place the tab is in.
/// The lines are drawn apart in one list (`SidebarListModel`), so each draws
/// its own piece: the header its top corners, the last line its bottom
/// ones, and each reaches over the gap below it to the next.
struct SupervisionProjectDropMark: View {
    let isFirst: Bool
    let isLast: Bool
    /// The gap down to the next line, which the piece covers unless it is
    /// the last.
    let gapBelow: CGFloat
    @Environment(\.weirAccent) private var accent

    var body: some View {
        let radius = WeirLayout.Supervision.sessionRowCornerRadius
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0,
            style: .continuous
        )
        .fill(accent.opacity(SupervisionTokens.dropProjectFillOpacity))
        .padding(.bottom, isLast ? 0 : -gapBelow)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// Whether a dragged tab or pane would land on the line this is in: its name
    /// takes the accent (`SupervisionRowDropMark`).
    @Entry var isDropTarget = false
}
