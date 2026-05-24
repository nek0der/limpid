// WindowVibrancyBackground.swift
// Limpid — `NSVisualEffectView` bridge for true behind-window
// blending. SwiftUI's built-in Materials (`.thickMaterial`,
// `.regularMaterial`, etc) only blend with content drawn *inside*
// the app, so on a `isOpaque = false` window they leave the
// content area transparent — desktop wallpaper / apps behind the
// window simply show through as bare pixels.
//
// AppKit's `NSVisualEffectView` with `blendingMode = .behindWindow`
// is still the only API on macOS 26 that reads the framebuffer
// *behind* the window and blurs it. Apple's Notes / Mail /
// Reminders sidebars all rely on this primitive underneath their
// `.glassEffect` slabs; Ghostty uses the same bridge for its
// About window. We promote the bridge to a top-level type so both
// the main window (`ThreePaneLayout`) and the Settings window
// (`SettingsScene`) share one implementation.

import AppKit
import SwiftUI

struct WindowVibrancyBackground: NSViewRepresentable {
    /// Defaults match Apple's Notes 2026 sidebar / Mail mailbox
    /// list — `.underWindowBackground` gives the slightly darker
    /// "system surface" tone, which reads as a window backdrop
    /// rather than an in-content material.
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
