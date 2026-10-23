// TrackedHelp.swift
// Limpid — a tooltip AppKit tracks with a tracking area of its own, for a view that can be under the pointer as its window appears.

import AppKit
import SwiftUI

extension View {
    /// The view's tooltip, shown and hidden by AppKit's tooltip manager
    /// for a view of our own laid behind it, in place of `.help`.
    ///
    /// SwiftUI's `.help` goes through the hosting view's dynamic tooltip
    /// manager, which follows the pointer's moves itself. A pane strip tab
    /// under the pointer as the window appeared at launch showed its
    /// tooltip and kept it after the pointer left, until the tab was
    /// hovered and left again: that manager missed the exit of a pointer
    /// it had not seen come in. AppKit's own tooltip for a view rides on
    /// an `NSTrackingArea`, which reads whether the pointer starts inside
    /// when it is added and sends the exit either way.
    /// Hit testing passes through the view, so clicks, drags, and the
    /// context menu still reach the SwiftUI view.
    func trackedHelp(_ text: String) -> some View {
        background(TrackedHelpRegion(text: text))
    }
}

/// The view behind `trackedHelp(_:)` that carries the tooltip.
private struct TrackedHelpRegion: NSViewRepresentable {
    let text: String

    func makeNSView(context _: Context) -> TrackedHelpView {
        TrackedHelpView()
    }

    func updateNSView(_ view: TrackedHelpView, context _: Context) {
        // Only on a change: setting it again would put the tooltip back
        // on its delay while it shows.
        if view.toolTip != text {
            view.toolTip = text
        }
    }
}

/// A view that holds a tooltip and nothing else: it takes no click and is
/// not read by VoiceOver, as the SwiftUI view in front says what it is.
final class TrackedHelpView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
