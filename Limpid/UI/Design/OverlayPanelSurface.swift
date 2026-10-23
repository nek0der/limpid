// OverlayPanelSurface.swift
// Limpid — the ground, edge, corner, and shadow of a panel laid over the whole window.

import SwiftUI

extension View {
    /// The face of a panel over the whole window (`ModalMotion.overlayPanel`:
    /// All Projects, the keyboard shortcuts panel). One modifier for every
    /// such panel, so they read as the same kind of surface and cannot
    /// drift apart.
    ///
    /// Opaque, on the window's color and edge, so what the panel holds
    /// reads on the same ground as the window under it. The shadow is the
    /// ground's alone: cast from the whole panel, it was worked out again
    /// from every card on every frame of a scroll.
    func overlayPanelSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.overlayPanelCornerRadius, style: .continuous)
        return clipShape(shape)
            .background(shape.fill(SupervisionTokens.window.color).modifier(FloatingSurfaceShadow()))
            .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
    }
}
