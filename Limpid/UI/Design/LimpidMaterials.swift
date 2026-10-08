// LimpidMaterials.swift
// Limpid — shared surface treatment for panels that float over the terminal.

import SwiftUI

extension View {
    /// Surface for panels that float over the terminal. They share one
    /// treatment so they read as the same layer. We use a material rather
    /// than Liquid Glass because glass lets the terminal text behind it
    /// show through strongly enough to compete with the panel's own text.
    func floatingPanelSurface(cornerRadius: CGFloat) -> some View {
        floatingPanelSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The same surface in any outline, for a panel whose shape is more than
    /// a rounded rectangle, such as one with an arrow pointing at what
    /// opened it. One outline filled and stroked once, so the parts read as
    /// one piece.
    func floatingPanelSurface(in shape: some Shape) -> some View {
        // The shadow belongs to the backing shape alone. Applied to the
        // whole view, SwiftUI would also cast it from every piece of text
        // and every row fill inside the panel, which reads as a haze.
        background {
            shape
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        }
        .overlay {
            shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }
}
