// LimpidButtonStyles.swift
// Limpid — shared button modifiers, derived from Calyx's pattern:
// `.buttonStyle(.plain)` plus a semi-transparent fill so the parent
// window's Liquid Glass shows through. The OS's own `.glass` button
// style draws an opaque pill that fights the sidebar's vibrancy, so we
// use this instead.

import SwiftUI

extension View {
    /// Pill-shaped subtle background used by sidebar/tab-bar chrome
    /// buttons (New Group, +, etc.). The fill is dark in dark mode and
    /// light in light mode, both at low opacity so the underlying
    /// material reads through.
    func limpidChromeButton(cornerRadius: CGFloat = 8) -> some View {
        modifier(LimpidChromeButtonModifier(cornerRadius: cornerRadius))
    }
}

private struct LimpidChromeButtonModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(scheme == .dark
                        ? Color.white.opacity(0.07)
                        : Color.black.opacity(0.07))
            )
            .opacity(controlActiveState == .key ? 1.0 : 0.6)
    }
}
