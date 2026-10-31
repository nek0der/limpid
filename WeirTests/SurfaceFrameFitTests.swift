// SurfaceFrameFitTests.swift
// Weir — a pane's attention frame and drop ring keep inside the surface's border and follow the corners it shares.

import SwiftUI
import Testing
@testable import Weir

/// A pane's attention frame on the session's surface: inside the border on
/// the edges it shares, rounded at the corners it shares, square elsewhere.
struct SurfaceFrameFitTests {
    private let surface = CGSize(width: 800, height: 600)

    private func fit(_ frame: CGRect) -> SurfaceFrameFit {
        SurfaceFrameFit.fit(frame: frame, surface: surface, border: 1, cornerRadius: 10)
    }

    @Test func aPaneFillingTheSurface_staysInsideTheBorder_andFollowsEveryCorner() {
        let fit = fit(CGRect(origin: .zero, size: surface))
        #expect(fit.insets == EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1))
        #expect(fit.radii == RectangleCornerRadii(topLeading: 9, bottomLeading: 9, bottomTrailing: 9, topTrailing: 9))
    }

    @Test func aBottomLeftPane_meetsOnlyTheLeftAndBottomEdges() {
        // Under the header and the strip, left of a split at 400.
        let fit = fit(CGRect(x: 0, y: 66, width: 400, height: 534))
        #expect(fit.insets == EdgeInsets(top: 0, leading: 1, bottom: 1, trailing: 0))
        #expect(fit.radii == RectangleCornerRadii(topLeading: 0, bottomLeading: 9, bottomTrailing: 0, topTrailing: 0))
    }

    @Test func aRightHandPane_meetsOnlyTheRightAndBottomEdges() {
        let fit = fit(CGRect(x: 401, y: 66, width: 399, height: 534))
        #expect(fit.insets == EdgeInsets(top: 0, leading: 0, bottom: 1, trailing: 1))
        #expect(fit.radii == RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: 9, topTrailing: 0))
    }

    @Test func anEdgeWithinHalfAPoint_countsAsTheSurfaces() {
        // A measured frame can land a fraction off the surface's edge.
        #expect(fit(CGRect(x: 0.5, y: 66, width: 799, height: 534)).insets.leading == 1)
        #expect(fit(CGRect(x: 0.6, y: 66, width: 799, height: 534)).insets.leading == 0)
        #expect(fit(CGRect(x: 0, y: 66, width: 799.5, height: 534)).insets.trailing == 1)
        #expect(fit(CGRect(x: 0, y: 66, width: 799.4, height: 534)).insets.trailing == 0)
    }

    @Test func oneReadingOfThePane_placesItOnTheSurface() {
        // The surface's bounds seen from a pane at (401, 66): it starts up
        // and to the left of the pane's origin.
        let bounds = CGRect(x: -401, y: -66, width: 800, height: 600)
        let fit = SurfaceFrameFit.fit(size: CGSize(width: 399, height: 534), surfaceBounds: bounds, border: 1, cornerRadius: 10)
        #expect(fit == self.fit(CGRect(x: 401, y: 66, width: 399, height: 534)))
    }

    @Test func offASurface_theFrameIsSquareOnThePanesEdge() {
        #expect(SurfaceFrameFit.fit(size: surface, surfaceBounds: nil) == .none)
        #expect(SurfaceFrameFit.fit(frame: CGRect(origin: .zero, size: surface), surface: .zero) == .none)
    }

    // MARK: - A pane's drop ring

    /// The drop ring 4pt in from every line around the pane, on a surface
    /// the panes fill, split at a Retina seam (half a point).
    private func ring(_ frame: CGRect) -> SurfaceFrameFit {
        fit(frame).inset(by: 4)
    }

    private func edges(_ top: CGFloat, _ leading: CGFloat, _ bottom: CGFloat, _ trailing: CGFloat) -> EdgeInsets {
        EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }

    @Test func aSinglePanesRing_isConcentricWithTheSurfaceAtEveryCorner() {
        let ring = ring(CGRect(origin: .zero, size: surface))
        // 1pt of border and 4pt of inset: 10 - 5.
        #expect(ring.insets == edges(5, 5, 5, 5))
        #expect(ring.radii == RectangleCornerRadii(topLeading: 5, bottomLeading: 5, bottomTrailing: 5, topTrailing: 5))
    }

    @Test func sideBySidePanes_roundOnlyTheirOuterCorners_andStandAsFarFromTheSeamAsFromTheBorder() {
        let left = ring(CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(left.insets == edges(5, 5, 5, 4))
        #expect(left.radii == RectangleCornerRadii(topLeading: 5, bottomLeading: 5, bottomTrailing: 0, topTrailing: 0))

        let right = ring(CGRect(x: 400.5, y: 0, width: 399.5, height: 600))
        #expect(right.insets == edges(5, 4, 5, 5))
        #expect(right.radii == RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: 5, topTrailing: 5))
    }

    @Test func stackedPanes_roundOnlyTheirOuterCorners() {
        let top = ring(CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(top.insets == edges(5, 5, 4, 5))
        #expect(top.radii == RectangleCornerRadii(topLeading: 5, bottomLeading: 0, bottomTrailing: 0, topTrailing: 5))

        let bottom = ring(CGRect(x: 0, y: 300.5, width: 800, height: 299.5))
        #expect(bottom.insets == edges(4, 5, 5, 5))
        #expect(bottom.radii == RectangleCornerRadii(topLeading: 0, bottomLeading: 5, bottomTrailing: 5, topTrailing: 0))
    }

    @Test func theMiddlePanesOfAThreeWaySplit_areSquareAtEveryCorner() {
        let side = ring(CGRect(x: 266.5, y: 0, width: 266.5, height: 600))
        #expect(side.insets == edges(5, 4, 5, 4))
        #expect(side.radii == RectangleCornerRadii())

        let stacked = ring(CGRect(x: 0, y: 200.5, width: 800, height: 199.5))
        #expect(stacked.insets == edges(4, 5, 4, 5))
        #expect(stacked.radii == RectangleCornerRadii())
    }

    @Test func aRingInsetPastTheSurfacesCorner_isSquare() {
        #expect(fit(CGRect(origin: .zero, size: surface)).inset(by: 12).radii == RectangleCornerRadii())
    }
}
