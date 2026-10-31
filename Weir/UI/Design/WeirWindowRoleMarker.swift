// WeirWindowRoleMarker.swift
// Weir — tags the hosting NSWindow with its `WeirWindowRole`.

import SwiftUI

/// Apply with `.background(WeirWindowRoleMarker(role: .main))` inside the
/// scene's content. The main window's `LeftRailView` and the Settings
/// window's `GeneralPane` each render their own `UpdatePopover`;
/// tagging Settings too keeps Check Now… from opening Sparkle's standard
/// modal alongside the inline popover when the main window is hidden.
struct WeirWindowRoleMarker: NSViewRepresentable {
    let role: WeirWindowRole

    /// Tags in `viewDidMoveToWindow`. A shape that deferred the tag by one
    /// `DispatchQueue.main.async` tick bailed when AppKit had not parented the
    /// view yet — a real race on cold launch while SwiftUI is still attaching
    /// the representable — and left the window untagged for the whole
    /// session. `viewDidMoveToWindow` fires the moment the view enters a
    /// window, and matches `WindowAccessor`'s idiom.
    final class MarkerView: NSView {
        var role: WeirWindowRole = .main

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tagAsWeir(role)
        }
    }

    func makeNSView(context _: Context) -> MarkerView {
        let view = MarkerView()
        view.role = role
        return view
    }

    func updateNSView(_: MarkerView, context _: Context) {}
}
