// MainWindowMinimumLayout.swift
// Weir — a main window's root, which reports the window's minimum and nothing of its content's.

import SwiftUI

/// A main window's root: as large as it is offered and never smaller than
/// `minimum`, which is the only size it reports when asked for its
/// smallest. Its content is laid out in that size and does not take part
/// in the window's minimum, so a view inside that is wider than the floor
/// (a sidebar at its saved width) cannot raise it. The hosting view writes
/// what this reports to the window (`ProjectWindowController`).
struct MainWindowMinimumLayout: Layout {
    let minimum: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        CGSize(
            width: max(proposal.width ?? minimum.width, minimum.width),
            height: max(proposal.height ?? minimum.height, minimum.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
