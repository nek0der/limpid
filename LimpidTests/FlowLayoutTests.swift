// FlowLayoutTests.swift
// Limpid — the wrapping layout keeps its views inside the width it is given.

import CoreGraphics
import Testing
@testable import Limpid

struct FlowLayoutTests {
    private static func arrange(_ widths: [CGFloat], heights: [CGFloat]? = nil, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let sizes = widths.indices.map { CGSize(width: widths[$0], height: heights?[$0] ?? 18) }
        return FlowLayout.arrange(sizes, width: width, spacing: 6, lineSpacing: 4)
    }

    @Test func whatFits_staysOnOneLine() {
        let result = Self.arrange([100, 60, 50], width: 300)
        #expect(result.frames.map(\.minX) == [0, 106, 172])
        #expect(result.frames.allSatisfy { $0.minY == 0 })
        #expect(result.size == CGSize(width: 222, height: 18))
    }

    @Test func whatDoesNotFit_wrapsToTheNextLine() {
        // A card's place, three chips, and its window note at a narrow width.
        let result = Self.arrange([180, 60, 90, 70, 80], width: 200)
        #expect(result.frames.map(\.minY) == [0, 22, 22, 44, 44])
        #expect(result.frames.allSatisfy { $0.maxX <= 200 })
        #expect(result.size.height == 62)
    }

    @Test func aViewWiderThanALine_isGivenTheLine_notMore() {
        let result = Self.arrange([400, 60], width: 117)
        #expect(result.frames[0].width == 117)
        #expect(result.frames.allSatisfy { $0.maxX <= 117 })
    }

    @Test func aLinesViews_centerOnIt() {
        let result = Self.arrange([100, 60], heights: [13, 18], width: 300)
        #expect(result.frames[0].minY == 2.5)
        #expect(result.frames[1].minY == 0)
    }

    /// Placing again at the width sizing returned gives back the same lines:
    /// a parent lays the view out at the width it measured.
    @Test(arguments: [
        ([63.226891, 136.8832, 43.096], 292.13),
        ([180, 60, 90, 70, 80], 200),
        ([33.3, 77.7, 11.1, 99.9, 44.4], 150.05)
    ] as [([CGFloat], CGFloat)])
    func arrangingAgainAtTheMeasuredWidth_givesTheSameLines(widths: [CGFloat], width: CGFloat) {
        let first = Self.arrange(widths, width: width)
        let again = Self.arrange(widths, width: first.size.width)
        #expect(again.frames == first.frames)
        #expect(again.size == first.size)
    }

    @Test func withNoWidth_everythingIsOneLine() {
        let result = Self.arrange([100, 60, 50], width: .infinity)
        #expect(result.size == CGSize(width: 222, height: 18))
    }
}
