// WidthCap.swift
// Weir — a layout that gives a view its own width, up to a cap, rather than all the width it is offered.

import SwiftUI

/// Its one subview at the subview's own width while that fits under `max`
/// and the width offered, else at the smaller of the two, where a text in
/// it is cut. `.frame(maxWidth:)` cannot say this: it hands a flexible view
/// (a `Menu` drawn plain, which fills what it is given) the whole cap, and
/// the new worktree sheet's base menu opened a 200pt gap in its sentence.
/// `.fixedSize()` cannot either: it never cuts.
struct WidthCap: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(childProposal(proposal, for: subview))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: bounds.origin, anchor: .topLeading, proposal: childProposal(proposal, for: subview))
    }

    /// The subview's own width, held to the cap and to the width offered.
    private func childProposal(_ proposal: ProposedViewSize, for subview: LayoutSubview) -> ProposedViewSize {
        let own = subview.sizeThatFits(.unspecified).width
        let width = Swift.min(own, max, proposal.width ?? .infinity)
        return ProposedViewSize(width: width, height: proposal.height)
    }
}
