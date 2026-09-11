// GlassSurfaces.swift
// Limpid — Liquid Glass surface treatments. The flush sidebar is the
// one in use; `liquidGlassPill` is kept for in-toolbar buttons and
// search fields but currently has no callers.
//
// On macOS 26 the sidebar goes through SwiftUI's canonical
// `.glassEffect(.regular, in:)` — Apple's official Liquid Glass
// primitive. When the user (or macOS Accessibility) asks to reduce
// transparency it falls back to a solid fill; the shape stays
// identical so the surrounding layout doesn't shift between modes.
import AppKit
import SwiftUI

extension View {
    /// Treat this view as a flush sidebar — a full-height glass
    /// surface against the window's leading edge, separated from the
    /// column beside it by a hairline on that edge alone.
    ///
    /// There is no corner radius, no rim stroke around the perimeter
    /// and no drop shadow. Those three say
    /// "this panel floats", and a sidebar that reaches the window
    /// edges does not. HIG allows either posture — a sidebar may float
    /// in the Liquid Glass layer — but the floating one asks for
    /// content to run underneath the panel, which a terminal's
    /// character grid cannot do without being hidden.
    func flushGlassSidebar(
        isSolid: Bool = false,
        solidFill: Color = LimpidColor.sidebarSolidFill
    ) -> some View {
        modifier(FlushGlassSidebarModifier(isSolid: isSolid, solidFill: solidFill))
    }

    /// Smaller variant used for in-toolbar buttons / search fields —
    /// thinner stroke, half the shadow, capsule shape.
    func liquidGlassPill() -> some View {
        modifier(LiquidGlassPillModifier())
    }

    /// Separates a transient leading panel from content it temporarily covers.
    /// Reserved columns stay flush and use only their trailing hairline.
    func transientLeadingPanelShadow() -> some View {
        shadow(color: Color.black.opacity(0.08), radius: 8, x: 3)
    }
}

private struct FlushGlassSidebarModifier: ViewModifier {
    let isSolid: Bool
    let solidFill: Color

    func body(content: Content) -> some View {
        surface(content: content)
            // The only edge that needs a line is the one facing the
            // next column. The other three sit on the window frame,
            // where a stroke would draw a seam along the window's own
            // rounded-corner mask.
            .overlay(alignment: .trailing) {
                LimpidColor.toolbarHairline.frame(width: 0.5)
            }
    }

    /// Two branches: solid mode paints an opaque fill, glass mode goes
    /// through macOS 26's
    /// `.glassEffect(.regular, in:)`. The glass sits in a background
    /// layer that takes no input because applying it as a content
    /// wrapper silently kills `.draggable` hit-testing on descendants.
    @ViewBuilder
    private func surface(content: Content) -> some View {
        if isSolid {
            content.background(solidFill)
        } else {
            content.background {
                Color.clear
                    .glassEffect(.regular, in: Rectangle())
                    // Regular glass draws outside its shape to cast a
                    // shadow. This sidebar is flush rather than floating,
                    // so keep that rendering inside the sidebar bounds.
                    .clipped()
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct LiquidGlassPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
    }
}
