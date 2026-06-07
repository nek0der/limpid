// SelectablePillBackground.swift
// Limpid — shared selection / hover treatment for any list row that
// behaves like a "pill": ContainerRow, TabRow, and anything we
// add later. One modifier means the two lists can never visually
// drift apart (cornerRadius, fill, stroke).

import SwiftUI

extension View {
    func selectablePillBackground(
        isActive: Bool,
        isHovering: Bool,
        isDescendantActive: Bool = false,
        cornerRadius: CGFloat = 12,
        horizontalPadding: CGFloat = 10
    ) -> some View {
        modifier(SelectablePillBackground(
            isActive: isActive,
            isHovering: isHovering,
            isDescendantActive: isDescendantActive,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding
        ))
    }
}

private struct SelectablePillBackground: ViewModifier {
    let isActive: Bool
    let isHovering: Bool
    /// `true` when a *descendant* of this row owns selection (e.g. a
    /// worktree selected under its project header). We dim the pill to
    /// a softer fill and drop the white stroke so the ancestor reads
    /// as "in the path of selection" without competing with the actual
    /// selected row below it.
    let isDescendantActive: Bool
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(stroke, lineWidth: 0.5)
                    )
                    .padding(.horizontal, horizontalPadding)
            )
    }

    private var fill: Color {
        if isActive { return LimpidColor.rowActiveFill }
        if isDescendantActive { return LimpidColor.rowAncestorActiveFill }
        if isHovering { return LimpidColor.rowHoverFill }
        return .clear
    }

    private var stroke: Color {
        // Hardcoded white reads on the dark slab but disappears against
        // the near-white light-mode `.glassEffect(.regular)` background,
        // killing the only stroke-based selection cue (the
        // `.primary.opacity(0.08)` fill is already barely-visible in
        // light mode by itself). Route through the adaptive accent
        // token instead so each appearance gets a contrast-appropriate
        // value.
        isActive ? LimpidColor.rowActiveBorder : .clear
    }
}
