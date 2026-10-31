// WindowBaseFill.swift
// Weir — the main window's backdrop: behind-window glass, or the opaque window color.

import SwiftUI

/// What a main window draws under its columns and title bar, from the
/// supervision window's ground (`SupervisionWindowGround`), so the title
/// bar and the layout under it read as one window.
struct WindowBaseFill: View {
    let isFullScreen: Bool
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        if reduceTransparencyResolver.shouldReduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            // Behind-window vibrancy samples whatever sits behind the
            // window. In a fullscreen Space that's the bare wallpaper, so
            // its hue floods the backdrop — a green wallpaper tints the
            // whole window green in dark mode. Swapping the material does
            // NOT fix it: `.behindWindow` pulls the wallpaper pixels in
            // regardless of material. Instead we drain the saturation while
            // fullscreen — the translucent blur stays, but the wallpaper's
            // color collapses to neutral gray, matching the windowed look.
            WindowVibrancyBackground(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            )
            .saturation(isFullScreen ? 0 : 1)
        }
    }
}
