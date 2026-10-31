// EqualSegmentsLayout.swift
// Weir — a row of segments of one width each, at its ideal size as wide as the widest needs.

import SwiftUI

/// Lays out a segmented control's segments side by side at one width each,
/// the track's width over their count, where the pill is placed
/// (`SegmentPillSlide.segmentWidth`). At its ideal size, as a control
/// that fits its words asks, each is as wide as the widest segment's
/// words: an even split of the words' widths added up would hand a short
/// label room it does not need and cut a long one, whose words then ran
/// under the pill beside it ("By Conversation" read as "Conversation").
struct EqualSegmentsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let width = proposal.width.map { $0 / count }
            ?? subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width }.max()
            ?? 0
        let segment = ProposedViewSize(width: width, height: proposal.height)
        let height = subviews.map { $0.sizeThatFits(segment).height }.max() ?? 0
        return CGSize(width: width * count, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + width * CGFloat(index), y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }
}
