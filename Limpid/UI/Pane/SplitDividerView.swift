// SplitDividerView.swift
// Limpid — thin draggable handle between two pane halves.

import SwiftUI

struct SplitDividerView: View {
    enum Axis { case horizontal, vertical }
    let direction: Axis
    let onDrag: (Double) -> Void

    @State private var lastTranslation: CGFloat = 0
    @State private var isHovering: Bool = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? LimpidColor.accent.opacity(0.35) : Color.primary.opacity(0.08))
            .frame(
                width: direction == .horizontal ? 6 : nil,
                height: direction == .vertical ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let total = direction == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let delta = total - lastTranslation
                        lastTranslation = total
                        onDrag(Double(delta))
                    }
                    .onEnded { _ in
                        lastTranslation = 0
                    }
            )
    }
}
