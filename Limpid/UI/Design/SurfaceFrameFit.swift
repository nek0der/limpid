// SurfaceFrameFit.swift
// Limpid — how a frame drawn around a view keeps clear of the surface it stands on.

import SwiftUI

/// How a frame drawn around a view on a surface (a pane's attention frame)
/// keeps clear of the surface: on each edge it shares with the surface it
/// steps inside the surface's border, and at each corner it shares, it
/// rounds as the surface does, less that border. Elsewhere it stays square
/// and on the view's edge. Drawn over the view, it moves no columns.
struct SurfaceFrameFit: Equatable, Sendable {
    var insets: EdgeInsets
    var radii: RectangleCornerRadii

    /// Edges closer than this to the surface's count as shared: a frame
    /// measured in points can land a fraction off.
    static let tolerance: CGFloat = 0.5

    /// Off a surface, or before it is measured: square, on the view's edge.
    static let none = Self(insets: EdgeInsets(), radii: RectangleCornerRadii())

    /// The fit for a view of `size` from one reading of its geometry:
    /// `surfaceBounds` is the surface's rectangle in the view's own
    /// coordinates (`GeometryProxy.bounds(of:)`), `nil` off a surface. Read
    /// together, the view's place and the surface's size never come from
    /// two different moments of a resize.
    static func fit(
        size: CGSize,
        surfaceBounds: CGRect?,
        border: CGFloat = LimpidLayout.Supervision.surfaceBorderWidth,
        cornerRadius: CGFloat = LimpidLayout.Supervision.surfaceCornerRadius
    ) -> Self {
        guard let surfaceBounds else { return none }
        return fit(
            frame: CGRect(origin: CGPoint(x: -surfaceBounds.minX, y: -surfaceBounds.minY), size: size),
            surface: surfaceBounds.size,
            border: border,
            cornerRadius: cornerRadius
        )
    }

    /// The fit for a view at `frame` on a surface of `surface`'s size, both
    /// in the surface's coordinates.
    static func fit(
        frame: CGRect,
        surface: CGSize,
        border: CGFloat = LimpidLayout.Supervision.surfaceBorderWidth,
        cornerRadius: CGFloat = LimpidLayout.Supervision.surfaceCornerRadius
    ) -> Self {
        guard surface.width > 0, surface.height > 0 else { return none }
        let touchesTopEdge = frame.minY <= tolerance
        let touchesLeadingEdge = frame.minX <= tolerance
        let touchesBottomEdge = frame.maxY >= surface.height - tolerance
        let touchesTrailingEdge = frame.maxX >= surface.width - tolerance
        let radius = max(cornerRadius - border, 0)
        return Self(
            insets: EdgeInsets(
                top: touchesTopEdge ? border : 0,
                leading: touchesLeadingEdge ? border : 0,
                bottom: touchesBottomEdge ? border : 0,
                trailing: touchesTrailingEdge ? border : 0
            ),
            radii: RectangleCornerRadii(
                topLeading: touchesTopEdge && touchesLeadingEdge ? radius : 0,
                bottomLeading: touchesBottomEdge && touchesLeadingEdge ? radius : 0,
                bottomTrailing: touchesBottomEdge && touchesTrailingEdge ? radius : 0,
                topTrailing: touchesTopEdge && touchesTrailingEdge ? radius : 0
            )
        )
    }

    /// The same fit stepped `inset` further in on every edge: from the
    /// surface's border where the view meets the surface, from the view's
    /// own edge (a split's seam) elsewhere, so a mark drawn there stands as
    /// far from every line around the pane. Its rounded corners stay
    /// concentric with the surface's, smaller by the step, and its square
    /// corners stay square, as a pane's corner at a seam is.
    func inset(by amount: CGFloat) -> Self {
        func corner(_ radius: CGFloat) -> CGFloat {
            radius > 0 ? max(radius - amount, 0) : 0
        }
        return Self(
            insets: EdgeInsets(
                top: insets.top + amount,
                leading: insets.leading + amount,
                bottom: insets.bottom + amount,
                trailing: insets.trailing + amount
            ),
            radii: RectangleCornerRadii(
                topLeading: corner(radii.topLeading),
                bottomLeading: corner(radii.bottomLeading),
                bottomTrailing: corner(radii.bottomTrailing),
                topTrailing: corner(radii.topTrailing)
            )
        )
    }
}
