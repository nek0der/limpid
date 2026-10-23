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
        modifier(FloatingPanelSurface(shape: shape))
    }
}

/// The surface itself. Every popover and menu shares it: the material
/// while transparency is on, the opaque `popover` token while it is off or
/// reduced, as every surface follows the appearance settings, and the
/// two shadows its lifted surfaces cast (`FloatingSurfaceShadow`). It tells
/// the rows inside which of the two they stand on (`PopoverGround`), so a
/// selected or hovered row still shows on the material.
private struct FloatingPanelSurface<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    /// Optional, as `PopoverGround(resolver:)` says.
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver: ReduceTransparencyResolver?

    func body(content: Content) -> some View {
        // The shadow belongs to the backing shape alone. Applied to the
        // whole view, SwiftUI would also cast it from every piece of text
        // and every row fill inside the panel, which reads as a haze.
        content
            .environment(\.popoverSurface, .limpid(PopoverGround(resolver: reduceTransparencyResolver)))
            // The panel's ground is the material or the opaque `popover`,
            // never the background opacity, so a box inside it is filled
            // whole, whatever surface the panel was opened over.
            .environment(\.supervisionSurfaceOpacity, 1)
            .background {
                FloatingPanelFill(shape: shape).modifier(FloatingSurfaceShadow())
            }
            .overlay {
                shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}

extension PopoverGround {
    /// The ground a floating part is filled with, from the app's resolver,
    /// which folds the app's transparency switch together with the
    /// system's Reduce Transparency. Optional: a part drawn where the
    /// resolver was never handed down (a preview, a panel of its own)
    /// keeps the material.
    @MainActor init(resolver: ReduceTransparencyResolver?) {
        self.init(reducesTransparency: resolver?.shouldReduceTransparency == true)
    }
}

/// The ground of a part that floats over the terminal or a surface and
/// draws its own edge and shadow, or none, rather than the panel
/// treatment's: `material` while transparency is on, the opaque `popover`
/// token while the app's switch is off or the system reduces it. The same
/// decision as `FloatingPanelSurface`'s (`PopoverGround`), so turning the
/// app's switch off makes every floating part opaque at once, not only
/// those the system would.
struct FloatingPanelFill<FillShape: Shape>: View {
    let shape: FillShape
    /// The material while transparency is on: the panels' regular one
    /// unless a part was drawn on a thinner or thicker one.
    let material: Material
    /// Optional, as `PopoverGround(resolver:)` says.
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver: ReduceTransparencyResolver?

    init(shape: FillShape, material: Material = .regularMaterial) {
        self.shape = shape
        self.material = material
    }

    var body: some View {
        switch PopoverGround(resolver: reduceTransparencyResolver) {
        case .opaque: shape.fill(SupervisionTokens.popover.color)
        case .material: shape.fill(material)
        }
    }
}
