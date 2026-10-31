// FloatingPanelShapeTests.swift
// Weir — a floating panel's outline, with and without its arrow.

import SwiftUI
import Testing
@testable import Weir

struct FloatingPanelShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 240, height: 70)

    @Test func withoutAnArrow_isTheContinuousRoundedRectangle() {
        // What `floatingPanelSurface(cornerRadius:)` draws, so a panel with
        // no arrow looks as it did on that surface.
        let shape = FloatingPanelShape(cornerRadius: 16, arrow: nil, arrowHeight: 10)
        #expect(shape.path(in: rect) == RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: rect))
        #expect(shape.path(in: rect).boundingRect == rect)
    }

    @Test func withAnArrow_standsOutOnTheEdgeItFaces() {
        let top = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .top, offset: 120), arrowHeight: 10)
        let bounds = top.path(in: rect).boundingRect
        #expect(bounds.minY == rect.minY - 10)
        #expect(bounds.maxY == rect.maxY)

        let bottom = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .bottom, offset: 120), arrowHeight: 10)
        let bottomBounds = bottom.path(in: rect).boundingRect
        #expect(bottomBounds.maxY == rect.maxY + 10)
        #expect(bottomBounds.minY == rect.minY)

        let leading = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .leading, offset: 35), arrowHeight: 10)
        let leadingBounds = leading.path(in: rect).boundingRect
        #expect(leadingBounds.minX == rect.minX - 10)
        #expect(leadingBounds.maxX == rect.maxX)
        #expect(leadingBounds.minY == rect.minY)
        #expect(leadingBounds.maxY == rect.maxY)
    }
}
