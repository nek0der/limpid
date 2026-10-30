// DragChip.swift
// Limpid — the chip that names what a tab or pane drag carries.

import SwiftUI

/// A dragged tab's chip, below and to the right of the pointer rather than
/// under it, so the row it would land on stays readable. AppKit centers a
/// preview on the pointer, so hidden copies of the chip fill the other three
/// quarters.
struct TabDragChip: View {
    let title: String

    var body: some View {
        VStack(spacing: LimpidLayout.Supervision.spaceXS) {
            DragChipFace(title: title).hidden()
            HStack(spacing: LimpidLayout.Supervision.spaceXS) {
                DragChipFace(title: title).hidden()
                DragChipFace(title: title)
            }
        }
    }
}

/// What a dragged tab or pane is called, on the popovers' surface, in the
/// accent's ring, so the person sees what they carry.
struct DragChipFace: View {
    let title: String
    @Environment(\.limpidAccent) private var accent

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.surfaceCornerRadius, style: .continuous)
        return Text(verbatim: title)
            .font(.supervision(.label, weight: .medium))
            .foregroundStyle(SupervisionTokens.text.color)
            .lineLimit(1)
            .frame(maxWidth: Layout.dragChipMaxWidth)
            .fixedSize()
            .padding(.horizontal, Layout.spaceM)
            .padding(.vertical, Layout.spaceS)
            .background(shape.fill(SupervisionTokens.popover.color))
            .overlay(shape.strokeBorder(accent, lineWidth: Layout.dropTargetRingWidth))
    }
}
