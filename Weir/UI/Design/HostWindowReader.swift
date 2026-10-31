// HostWindowReader.swift
// Weir — tells a SwiftUI view which window it is in, for the AppKit panels that hang from that window.

import AppKit
import SwiftUI

/// The window a view is in, held weakly: a view's state that held its own
/// window strongly would keep the window, and with it the view, alive.
@MainActor
final class HostWindowReference {
    weak var window: NSWindow?
}

/// Puts the window it is in into `reference`, and keeps it current as the
/// view moves between windows. Use it where an AppKit panel must be
/// attached to the sheet or window it was asked from: the key window is
/// only a guess at that.
struct HostWindowReader: NSViewRepresentable {
    let reference: HostWindowReference

    func makeNSView(context _: Context) -> ReaderView {
        let view = ReaderView(frame: .zero)
        view.reference = reference
        return view
    }

    func updateNSView(_ view: ReaderView, context _: Context) {
        view.reference = reference
        reference.window = view.window
    }

    @MainActor final class ReaderView: NSView {
        var reference: HostWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}
