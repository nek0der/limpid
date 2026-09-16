// CellSizeTests.swift
// Limpid — validates the device-pixel to point conversion for libghostty cell reports.

import Testing
@testable import Limpid

@Suite("Cell size")
struct CellSizeTests {
    @Test("a Retina report lands on the same points as a non-Retina one")
    func points_areScaleIndependent() {
        let retina = CellSize.points(devicePixelWidth: 13, devicePixelHeight: 29, scale: 2)
        let standard = CellSize.points(devicePixelWidth: 7, devicePixelHeight: 15, scale: 1)

        #expect(retina == CellSize(width: 6.5, height: 14.5))
        #expect(standard == CellSize(width: 7, height: 15))
    }

    @Test("a degenerate report is rejected instead of producing a zero-sized grid")
    func points_rejectDegenerateInput() {
        #expect(CellSize.points(devicePixelWidth: 0, devicePixelHeight: 29, scale: 2) == nil)
        #expect(CellSize.points(devicePixelWidth: 13, devicePixelHeight: 0, scale: 2) == nil)
        #expect(CellSize.points(devicePixelWidth: 13, devicePixelHeight: 29, scale: 0) == nil)
        #expect(CellSize.points(devicePixelWidth: 13, devicePixelHeight: 29, scale: -1) == nil)
    }
}
