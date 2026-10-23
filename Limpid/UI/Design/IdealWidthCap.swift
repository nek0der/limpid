// IdealWidthCap.swift
// Limpid — a view that asks for no more than a given width at its ideal size, and takes any width it is given.

import SwiftUI

/// Its one view as it is, except at its ideal size, where it is measured
/// at no more than `maxIdealWidth`. For a row whose `ViewThatFits` should
/// judge its fits by what a cuttable text needs at least rather than by
/// the text's whole length: `ViewThatFits` compares each fit's ideal width
/// with the room, and the fit it chooses is then laid out at the room
/// itself, where the text takes all it is given.
struct IdealWidthCap: Layout {
    var maxIdealWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        assert(subviews.count == 1, "IdealWidthCap lays out one view")
        guard let subview = subviews.first else { return .zero }
        guard proposal.width == nil else { return subview.sizeThatFits(proposal) }
        let ideal = subview.sizeThatFits(proposal)
        guard ideal.width > maxIdealWidth else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxIdealWidth, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
