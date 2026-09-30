// LimpidWindowRoleMarker.swift
// Limpid — tags the hosting NSWindow with its `LimpidWindowRole`.

import SwiftUI

/// Apply with `.background(LimpidWindowRoleMarker(role: .main))` inside the
/// scene's content. The main window hosts `ToolbarTerminalColumnSegment`
/// and the Settings window's `GeneralPane` renders its own `UpdatePopover`;
/// tagging Settings too keeps Check Now… from opening Sparkle's standard
/// modal alongside the inline popover when the main window is hidden.
struct LimpidWindowRoleMarker: NSViewRepresentable {
    let role: LimpidWindowRole

    /// Tags in `viewDidMoveToWindow`. A shape that deferred the tag by one
    /// `DispatchQueue.main.async` tick bailed when AppKit had not parented the
    /// view yet — a real race on cold launch while SwiftUI is still attaching
    /// the representable — and left the window untagged for the whole
    /// session. `viewDidMoveToWindow` fires the moment the view enters a
    /// window, and matches `WindowAccessor`'s idiom.
    final class MarkerView: NSView {
        var role: LimpidWindowRole = .main

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tagAsLimpid(role)
        }
    }

    func makeNSView(context _: Context) -> MarkerView {
        let view = MarkerView()
        view.role = role
        return view
    }

    func updateNSView(_: MarkerView, context _: Context) {}
}
