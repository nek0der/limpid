// BalancedLines.swift
// Weir — a layout that sets a wrapping text in lines of even length, as CSS `text-wrap: balance` does.

import SwiftUI

/// Its one text at the narrowest width that keeps the line count the room
/// gives it, so a sentence that needs two lines is set in two of about the
/// same length, not one full line and a word or two alone under it. In
/// Japanese, which may break between any two characters, a full line left
/// its last few characters alone on the second; here each line takes about
/// half.
///
/// The width it reports is the width the lines take, so a stack that
/// centers it centers the lines, and a text that fits on one line is left
/// as it is.
struct BalancedLines: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        assert(subviews.count == 1, "BalancedLines lays out one view")
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(balancedProposal(proposal, for: subview))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let subview = subviews.first else { return }
        // Centered in what the stack gave, should it give more than the
        // lines take.
        subview.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: balancedProposal(proposal, for: subview)
        )
    }

    /// The room, or the narrowest width that still sets the text in as
    /// many lines as the room does.
    private func balancedProposal(_ proposal: ProposedViewSize, for subview: LayoutSubview) -> ProposedViewSize {
        guard let room = proposal.width, room.isFinite, room > 0 else { return proposal }
        let ideal = subview.sizeThatFits(.unspecified).width
        let width = TextBalance.width(idealWidth: ideal, room: room) { width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return ProposedViewSize(width: width, height: proposal.height)
    }
}

/// The arithmetic behind `BalancedLines`, apart from any view, so it can be
/// checked against a stand-in for the text.
enum TextBalance {
    /// How close the search comes to the narrowest width, in points.
    static let precision: CGFloat = 1

    /// The lines a text of single-line width `idealWidth` needs at least in
    /// `room`; what breaks fall on can add one more.
    static func minimumLineCount(idealWidth: CGFloat, room: CGFloat) -> Int {
        guard room > 0, idealWidth > room else { return 1 }
        return Int((idealWidth / room).rounded(.up))
    }

    /// The narrowest width, no wider than `room`, at which the text is no
    /// taller than it is at `room`. `height` measures the text at a width.
    /// A text that fits on one line keeps the room.
    ///
    /// A greedy line breaker never sets a text in more lines at a wider
    /// width, so the heights fall as the width grows and a search between
    /// `idealWidth / lines` (where the text cannot yet fit that many lines)
    /// and the room finds where they reach the room's height.
    static func width(idealWidth: CGFloat, room: CGFloat, height: (CGFloat) -> CGFloat) -> CGFloat {
        guard room > 0, idealWidth > room else { return room }
        let lines = CGFloat(minimumLineCount(idealWidth: idealWidth, room: room))
        let target = height(room)
        /// Heights are whole lines apart; the slack takes rounding.
        func fits(_ width: CGFloat) -> Bool {
            height(width) <= target + 0.5
        }
        var low = (idealWidth / lines).rounded(.down)
        if fits(low) {
            return low
        }
        var high = room
        while high - low > precision {
            let middle = ((low + high) / 2).rounded(.down)
            if middle <= low {
                break
            }
            if fits(middle) {
                high = middle
            } else {
                low = middle
            }
        }
        return high
    }
}
