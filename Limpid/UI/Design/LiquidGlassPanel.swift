// LiquidGlassPanel.swift
// Limpid — Notes 2026-style "floating panel" Liquid Glass treatment.
// Used for container column (the container sidebar) and any sub-panel that wants to
// visually pop above the flush tab / terminal column areas.
//
// On macOS 26 the panel uses SwiftUI's canonical `.glassEffect(.regular,
// in:)` — Apple's official Liquid Glass primitive. We layer a rim-light
// stroke + soft drop shadow on top so the panel reads as "floating"
// above the window toolbar.
//
// When the user (or macOS Accessibility) asks to reduce transparency,
// the panel falls back to a solid fill — opaque, no rim glow, lighter
// shadow. The shape and corner radius stay identical so the surrounding
// layout doesn't shift between modes.

import AppKit
import SwiftUI

extension View {
    /// Treat this view as a floating panel — translucent material,
    /// rounded corners, rim-light, drop shadow. Mirrors the container column sidebar
    /// in macOS Notes 2026. `solid` forces an opaque fill (used when
    /// transparency resolves to reduced); leaving it at the default
    /// keeps Liquid Glass. `solidFill` is the color painted in solid
    /// mode — pass a window-tint-aware color so the opaque panel still
    /// tracks the theme instead of going flat gray. In glass mode the
    /// panel samples the tint from the surface behind it, so the fill is
    /// ignored there.
    func liquidGlassPanel(
        cornerRadius: CGFloat = 10,
        isSolid: Bool = false,
        solidFill: Color = Color(nsColor: .windowBackgroundColor)
    ) -> some View {
        modifier(LiquidGlassPanelModifier(
            cornerRadius: cornerRadius,
            isSolid: isSolid,
            solidFill: solidFill
        ))
    }

    /// Smaller variant used for in-toolbar buttons / search fields —
    /// thinner stroke, half the shadow, capsule shape.
    func liquidGlassPill() -> some View {
        modifier(LiquidGlassPillModifier())
    }
}

private struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isSolid: Bool
    let solidFill: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        slabBackground(content: content, shape: shape)
            .overlay(
                // Liquid Glass mode keeps the rim glow; solid mode
                // drops it because the opaque fill already reads as
                // a distinct surface without help.
                shape.strokeBorder(
                    isSolid
                        ? LinearGradient(
                            colors: [Color.primary.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.10)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                    lineWidth: isSolid ? 0.5 : 1
                )
            )
            // `.glassEffect` on macOS 26 supplies its own depth cues
            // (specular highlight, lensing, soft system shadow), so we
            // skip the manual drop shadow in glass mode — stacking one
            // on top read as a dark cloud under the sidebar in light
            // mode. Solid mode still needs a hand-drawn shadow because
            // the windowBackground fill is flat.
            .shadow(
                color: Color.black.opacity(isSolid ? 0.12 : 0),
                radius: isSolid ? 6 : 0,
                x: 0,
                y: isSolid ? 2 : 0
            )
            .compositingGroup()
    }

    /// Solid mode paints the system window background. Glass mode
    /// goes through SwiftUI's macOS 26 Liquid Glass primitive
    /// (`.glassEffect(.regular, in:)`), the same API Apple uses in
    /// Notes / Mail / Reminders sidebars. Splitting the branches
    /// avoids stuffing two different background mechanisms behind
    /// a single `AnyShapeStyle`.
    @ViewBuilder
    private func slabBackground(content: Content, shape: some Shape) -> some View {
        if isSolid {
            content.background(solidFill, in: shape)
        } else {
            // macOS 26's `.glassEffect(.regular, in:)` applied as a
            // content wrapper silently kills `.draggable` hit-testing
            // on descendants: rows below it report `.onAppear` but
            // their drag autoclosure is never invoked. Pushing the
            // glass into a background layer + `.allowsHitTesting(false)`
            // restores drag while keeping the Liquid Glass look — the
            // glass is now a sibling under the content rather than an
            // ancestor that intercepts the pointer stream.
            content.background {
                Color.clear
                    .glassEffect(.regular, in: shape)
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
