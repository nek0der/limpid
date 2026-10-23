// UpdateControlVisibilityMarker.swift
// Limpid — tells the hosting window whether its update control is in sight.

import SwiftUI

/// Tells the hosting window whether its update control is hidden, which
/// `LimpidUpdateDriver` reads to decide between its inline popover and
/// Sparkle's own dialog.
struct UpdateControlVisibilityMarker: NSViewRepresentable {
    let isHidden: Bool

    final class MarkerView: NSView {
        var hidesControl = false {
            didSet { window?.hidesUpdateControl = hidesControl }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.hidesUpdateControl = hidesControl
        }
    }

    func makeNSView(context _: Context) -> MarkerView {
        let view = MarkerView()
        view.hidesControl = isHidden
        return view
    }

    func updateNSView(_ view: MarkerView, context _: Context) {
        view.hidesControl = isHidden
    }
}
