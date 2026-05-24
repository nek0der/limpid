// SelectablePillBackground.swift
// Limpid — shared selection / hover treatment for any list row that
// behaves like a "pill": L1 ContainerRow, L2 TabRow, and anything we
// add later. One modifier means the two lists can never visually
// drift apart (cornerRadius, fill, stroke).

import SwiftUI

extension View {
    func selectablePillBackground(
        isActive: Bool,
        isHovering: Bool,
        cornerRadius: CGFloat = 12,
        horizontalPadding: CGFloat = 10
    ) -> some View {
        modifier(SelectablePillBackground(
            isActive: isActive,
            isHovering: isHovering,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding
        ))
    }
}

private struct SelectablePillBackground: ViewModifier {
    let isActive: Bool
    let isHovering: Bool
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
        if isHovering { return LimpidColor.rowHoverFill }
        return .clear
    }

    private var stroke: Color {
        isActive ? Color.white.opacity(0.18) : .clear
    }
}
