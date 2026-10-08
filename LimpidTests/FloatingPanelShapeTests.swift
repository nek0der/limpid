// FloatingPanelShapeTests.swift
// Limpid — a floating panel's outline, with and without its arrow.

import SwiftUI
import Testing
@testable import Limpid

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
        let top = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .top, x: 120), arrowHeight: 10)
        let bounds = top.path(in: rect).boundingRect
        #expect(bounds.minY == rect.minY - 10)
        #expect(bounds.maxY == rect.maxY)

        let bottom = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .bottom, x: 120), arrowHeight: 10)
        let bottomBounds = bottom.path(in: rect).boundingRect
        #expect(bottomBounds.maxY == rect.maxY + 10)
        #expect(bottomBounds.minY == rect.minY)
    }
}
