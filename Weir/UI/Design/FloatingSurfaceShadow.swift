// FloatingSurfaceShadow.swift
// Weir — the shadow of a supervision surface lifted over another, deeper in dark.

import SwiftUI

/// The two shadows of a surface lifted over another (a panel laid over the
/// terminal, the all projects sheet): a close one for its edge and a wide
/// one for its height, deeper in dark, where a light one would not show.
/// Laid on the surface's ground (a filled shape behind it), never on the
/// surface itself: cast from what the surface holds, SwiftUI works the
/// blur out again whenever that changes, every frame of a scroll.
struct FloatingSurfaceShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        content
            .shadow(color: .black.opacity(isDark ? 0.3 : 0.06), radius: 1, y: 1)
            .shadow(color: .black.opacity(isDark ? 0.5 : 0.16), radius: 28, y: 20)
    }
}
