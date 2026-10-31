// TerminalSlideHold.swift
// Weir — the terminal's size while its pane's frame animates.

import CoreGraphics

/// While the sidebar or the changes panel slides, SwiftUI hands a pane its
/// final size at once, in the layout, and then moves the pane's AppKit
/// frame there over the animation, a step on every frame. A terminal sized
/// from that frame had its pty resized on every frame: libghostty sends the
/// pixel size on to the pty even when the columns stay, so each step was a
/// SIGWINCH, which a TUI answers by drawing again. Sized by this rule, the
/// terminal changes once per slide, at its final size: at once when the
/// pane grows (the frame uncovers it as it widens), and as the slide ends
/// when the pane shrinks (it keeps its width until then, so no empty ground
/// shows beside it).
enum TerminalSlideHold {
    /// How far the frame may stand from the layout's size and still be
    /// taken as there: layout rounds the frame to the display's pixels.
    static let tolerance: CGFloat = 1

    /// The size to lay the terminal at, while the pane's frame is `frame`,
    /// the layout gives it `layout` (`nil` before it has given any), and the
    /// terminal has `laid` (`nil` before it was laid out).
    static func size(frame: CGSize, layout: CGSize?, laid: CGSize?) -> CGSize {
        guard let layout else { return frame }
        guard isMoving(frame: frame, layout: layout), let laid else { return layout }
        // Each side apart: a side that grows takes its end at once, a side
        // that shrinks keeps what it had.
        return CGSize(width: max(laid.width, layout.width), height: max(laid.height, layout.height))
    }

    /// Whether the frame is still on its way to the layout's size.
    static func isMoving(frame: CGSize, layout: CGSize) -> Bool {
        abs(frame.width - layout.width) > tolerance || abs(frame.height - layout.height) > tolerance
    }
}
