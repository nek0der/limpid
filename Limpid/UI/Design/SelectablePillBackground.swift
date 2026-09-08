// SelectablePillBackground.swift
// Limpid — shared selection / hover treatment for any list row that
// behaves like a "pill": ContainerRow, TabRow, AttentionRow, and
// anything we add later. One modifier means the lists can never
// visually drift apart (cornerRadius, fill).
//
// Selection is carried by fill alone. A stroked outline was tried and
// dropped: on a row that already sits inside a filled pill it read as
// a second frame around the first.

import SwiftUI

extension View {
    /// - Parameter leadingPadding: Inset for the pill's leading edge
    ///   when it has to differ from `horizontalPadding`. A row nested
    ///   under a rule needs to start clear of it, or the pill's
    ///   rounded corner crosses the line. Defaults to symmetric.
    func selectablePillBackground(
        isActive: Bool,
        isHovering: Bool,
        isDescendantActive: Bool = false,
        cornerRadius: CGFloat = 12,
        horizontalPadding: CGFloat = LimpidLayout.rowPillInset,
        leadingPadding: CGFloat? = nil
    ) -> some View {
        modifier(SelectablePillBackground(
            isActive: isActive,
            isHovering: isHovering,
            isDescendantActive: isDescendantActive,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            leadingPadding: leadingPadding ?? horizontalPadding
        ))
    }
}

private struct SelectablePillBackground: ViewModifier {
    let isActive: Bool
    let isHovering: Bool
    /// `true` when a *descendant* of this row owns selection (e.g. a
    /// worktree selected under its project header). We dim the pill to
    /// a softer fill so the ancestor reads as "in the path of
    /// selection" without competing with the actual selected row
    /// below it.
    let isDescendantActive: Bool
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let leadingPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .padding(.leading, leadingPadding)
                    .padding(.trailing, horizontalPadding)
            )
    }

    private var fill: Color {
        if isActive {
            return LimpidColor.rowActiveFill
        }
        if isDescendantActive {
            return LimpidColor.rowAncestorActiveFill
        }
        if isHovering {
            return LimpidColor.rowHoverFill
        }
        return .clear
    }
}
