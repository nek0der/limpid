// SplitSeamGeometryTests.swift
// Weir — split panes meet at a one-pixel seam, and the band that resizes them reaches over both.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// Two panes of a split meet at a seam one device pixel wide, with no gutter
/// between them, and the band that takes the pointer for a resize lies over
/// both panes' edges, terminal views included.
@Suite(.hostsWindows)
@MainActor
struct SplitSeamGeometryTests {
    private let size = CGSize(width: 400, height: 300)

    @Test(arguments: [1.0, 2.0, 3.0])
    func panes_meetAtOnePixel_withEveryEdgeOnThePixelGrid(scale: CGFloat) {
        for direction in [SplitDirection.horizontal, .vertical] {
            let extent = direction == .horizontal ? size.width : size.height
            for ratio in stride(from: 0.1, through: 0.9, by: 0.037) {
                let geometry = SplitSeamGeometry(size: size, ratio: ratio, direction: direction, displayScale: scale)
                let (firstEnd, secondStart, secondEnd) = direction == .horizontal
                    ? (geometry.first.maxX, geometry.second.minX, geometry.second.maxX)
                    : (geometry.first.maxY, geometry.second.minY, geometry.second.maxY)
                #expect(abs(secondStart - firstEnd - 1 / scale) < 0.0001, "ratio \(ratio): a gap of \(secondStart - firstEnd)")
                #expect(abs(secondEnd - extent) < 0.0001)
                let firstEndInPixels = firstEnd * scale
                #expect(abs(firstEndInPixels - firstEndInPixels.rounded()) < 0.0001, "ratio \(ratio): \(firstEnd) is off the grid")
                let (seamStart, seamWidth, hitStart, hitWidth) = direction == .horizontal
                    ? (geometry.seam.minX, geometry.seam.width, geometry.hitArea.minX, geometry.hitArea.width)
                    : (geometry.seam.minY, geometry.seam.height, geometry.hitArea.minY, geometry.hitArea.height)
                #expect(seamStart == firstEnd)
                #expect(seamWidth == 1 / scale)
                // The band reaches as far over each pane, centered on the seam.
                #expect(abs(hitStart - (seamStart - SplitSeamGeometry.hitOverhang)) < 0.0001)
                #expect(abs(hitWidth - (seamWidth + 2 * SplitSeamGeometry.hitOverhang)) < 0.0001)
            }
        }
    }

    @Test func aRetinaSplitAtHalf_drawsItsSeamAtTheCenter_andItsBandSixPointsAndAPixelWide() {
        let geometry = SplitSeamGeometry(size: size, ratio: 0.5, direction: .horizontal, displayScale: 2)
        #expect(geometry.first == CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(geometry.seam == CGRect(x: 200, y: 0, width: 0.5, height: 300))
        #expect(geometry.second == CGRect(x: 200.5, y: 0, width: 199.5, height: 300))
        #expect(geometry.hitArea == CGRect(x: 197, y: 0, width: 6.5, height: 300))
    }

    @Test func aStackedSplit_laysItsSeamAndBandAcross() {
        let geometry = SplitSeamGeometry(size: size, ratio: 0.5, direction: .vertical, displayScale: 2)
        #expect(geometry.seam == CGRect(x: 0, y: 150, width: 400, height: 0.5))
        #expect(geometry.hitArea == CGRect(x: 0, y: 147, width: 400, height: 6.5))
    }

    /// A divider pushed as far as it goes still leaves each pane its floor
    /// once the seam is rounded to the grid.
    /// A fractional extent on a 1x display is where the half point
    /// `resolvedRatio` keeps beside the seam falls short of a whole pixel.
    @Test(arguments: [1.0, 2.0, 3.0])
    func aClampedDivider_keepsBothPaneFloors(scale: CGFloat) {
        for extent: CGFloat in [401, 400.7, 400.3] {
            for proposed in [0.0, 1.0] {
                let ratio = PaneSplit.resolvedRatio(proposed, extent: extent, firstMinimum: 80, secondMinimum: 120)
                let geometry = SplitSeamGeometry(
                    size: CGSize(width: extent, height: 300),
                    ratio: ratio,
                    direction: .horizontal,
                    displayScale: scale,
                    firstMinimum: 80,
                    secondMinimum: 120
                )
                #expect(geometry.first.width >= 80, "extent \(extent), ratio \(ratio)")
                #expect(geometry.second.width >= 120, "extent \(extent), ratio \(ratio)")
                #expect(abs(geometry.second.minX - geometry.first.maxX - 1 / scale) < 0.0001)
            }
        }
    }

    /// The band over an AppKit view, as a split's lies over its terminals:
    /// 2pt off the seam on either side the window hands the pointer to the
    /// band, and past the band to the AppKit view.
    @Test func theBand_takesThePointerOverAnAppKitView_onBothSidesOfTheSeam() async throws {
        let (window, host) = hostedInWindow(BandOverAppKit(size: size), width: size.width, height: size.height)
        defer { window.close() }
        let frameView = try #require(window.contentView?.superview)
        let geometry = SplitSeamGeometry(
            size: size,
            ratio: 0.5,
            direction: .horizontal,
            displayScale: window.backingScaleFactor
        )
        let seam = geometry.seam.midX
        let offsets: [CGFloat] = [-8, -2, 2, 8]
        let takenByTerminal = await settledValue(in: host) { () -> [Bool]? in
            var results: [Bool] = []
            for offset in offsets {
                let point = host.convert(CGPoint(x: seam + offset, y: size.height / 2), to: frameView)
                guard let hit = frameView.hitTest(point) else { return nil }
                results.append(hit is StandInTerminal)
            }
            return results
        }
        #expect(takenByTerminal == [true, false, false, true])
    }
}

/// An AppKit view filling the split, as a pane's terminal does, under the
/// split's divider.
private struct BandOverAppKit: View {
    let size: CGSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            StandInTerminalRepresentable()
                .frame(width: size.width, height: size.height)
            SplitDividerView(
                direction: .horizontal,
                geometry: SplitSeamGeometry(size: size, ratio: 0.5, direction: .horizontal, displayScale: displayScale),
                onDrag: { _ in },
                onEqualize: {}
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

private final class StandInTerminal: NSView {}

private struct StandInTerminalRepresentable: NSViewRepresentable {
    func makeNSView(context _: Context) -> StandInTerminal {
        StandInTerminal()
    }

    func updateNSView(_: StandInTerminal, context _: Context) {}
}
