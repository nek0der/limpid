// QuickTerminalLayoutTests.swift
// Weir — the quick terminal panel geometry: where it sits on each edge, where it slides from, and which corners it rounds.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

@Suite("QuickTerminal layout")
@MainActor
struct QuickTerminalLayoutTests {

    // MARK: - Frame

    private static let visibleFrame = CGRect(x: 0, y: 40, width: 1000, height: 800)

    /// Each edge's panel spans that edge at the size asked; the centered
    /// one is 60% wide.
    struct FrameCase: Sendable {
        let position: QuickTerminalPosition
        let sizePercent: Int
        let expected: CGRect
    }

    private nonisolated static let targetFrames = [
        FrameCase(position: .top, sizePercent: 50, expected: CGRect(x: 0, y: 440, width: 1000, height: 400)),
        FrameCase(position: .bottom, sizePercent: 30, expected: CGRect(x: 0, y: 40, width: 1000, height: 240)),
        FrameCase(position: .left, sizePercent: 40, expected: CGRect(x: 0, y: 40, width: 400, height: 800)),
        FrameCase(position: .right, sizePercent: 90, expected: CGRect(x: 100, y: 40, width: 900, height: 800)),
        FrameCase(position: .center, sizePercent: 50, expected: CGRect(x: 200, y: 240, width: 600, height: 400))
    ]

    @Test(arguments: targetFrames)
    func targetFrame_liesAgainstItsEdge(_ frame: FrameCase) {
        let target = QuickTerminalLayout.targetFrame(
            position: frame.position,
            sizePercent: frame.sizePercent,
            visibleFrame: Self.visibleFrame
        )
        #expect(target == frame.expected, "\(frame.position)")
    }

    @Test(arguments: QuickTerminalPosition.allCases)
    func targetFrame_everySize_staysInsideVisibleFrame(position: QuickTerminalPosition) {
        for percent in QuickTerminalSettings.allowedSizePercents {
            let frame = QuickTerminalLayout.targetFrame(
                position: position,
                sizePercent: percent,
                visibleFrame: Self.visibleFrame
            )
            #expect(Self.visibleFrame.contains(frame), "\(position) \(percent)%")
        }
    }

    @Test func targetFrame_sizeFollowsPercent() {
        let sizes = QuickTerminalSettings.allowedSizePercents.map {
            QuickTerminalLayout.targetFrame(position: .top, sizePercent: $0, visibleFrame: Self.visibleFrame).height
        }
        #expect(sizes == [240, 320, 400, 480, 560, 640, 720])
    }

    @Test func hiddenFrame_edgesMoveFullyPastTheirEdge() {
        let vf = Self.visibleFrame
        func hidden(_ position: QuickTerminalPosition) -> (target: CGRect, hidden: CGRect) {
            let target = QuickTerminalLayout.targetFrame(position: position, sizePercent: 50, visibleFrame: vf)
            return (target, QuickTerminalLayout.hiddenFrame(position: position, target: target))
        }
        let top = hidden(.top)
        #expect(top.hidden.size == top.target.size)
        #expect(top.hidden.minY == vf.maxY)
        let bottom = hidden(.bottom)
        #expect(bottom.hidden.size == bottom.target.size)
        #expect(bottom.hidden.maxY == vf.minY)
        let left = hidden(.left)
        #expect(left.hidden.size == left.target.size)
        #expect(left.hidden.maxX == vf.minX)
        let right = hidden(.right)
        #expect(right.hidden.size == right.target.size)
        #expect(right.hidden.minX == vf.maxX)
    }

    /// Two displays stacked: the lower one at the origin, the upper one
    /// directly above it. Sliding from the lower display's top edge would
    /// be drawn on the upper display, so the panel fades in place instead.
    @Test func animationFrame_slideIntoDisplayAbove_fadesInPlace() {
        let lower = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let upper = CGRect(x: 0, y: 800, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .top, sizePercent: 50, visibleFrame: lower)
        let start = QuickTerminalLayout.animationFrame(position: .top, target: target, otherScreenFrames: [upper])
        #expect(start == target)
    }

    @Test func animationFrame_slideIntoDisplayBelow_fadesInPlace() {
        let upper = CGRect(x: 0, y: 800, width: 1000, height: 800)
        let lower = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .bottom, sizePercent: 50, visibleFrame: upper)
        let start = QuickTerminalLayout.animationFrame(position: .bottom, target: target, otherScreenFrames: [lower])
        #expect(start == target)
    }

    @Test func animationFrame_slideIntoDisplayBeside_fadesInPlace() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .left, sizePercent: 50, visibleFrame: right)
        let start = QuickTerminalLayout.animationFrame(position: .left, target: target, otherScreenFrames: [left])
        #expect(start == target)
    }

    /// A display beside the screen does not lie on the path of a slide
    /// from the top edge, so the slide stays.
    @Test func animationFrame_displayOffThePath_keepsTheSlide() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let beside = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .top, sizePercent: 50, visibleFrame: main)
        let start = QuickTerminalLayout.animationFrame(position: .top, target: target, otherScreenFrames: [beside])
        #expect(start == QuickTerminalLayout.hiddenFrame(position: .top, target: target))
        let alone = QuickTerminalLayout.animationFrame(position: .top, target: target, otherScreenFrames: [])
        #expect(alone == start)
    }

    @Test func hiddenFrame_center_isScaledAroundTheSameMiddle() {
        let target = CGRect(x: 200, y: 240, width: 600, height: 400)
        let hidden = QuickTerminalLayout.hiddenFrame(position: .center, target: target)
        #expect(hidden == CGRect(x: 212, y: 248, width: 576, height: 384))
    }

    /// Only the corners away from the attached screen edge are rounded.
    private nonisolated static let exposedCorners: [(QuickTerminalPosition, QuickTerminalCorners)] = [
        (.top, [.bottomLeading, .bottomTrailing]),
        (.bottom, [.topLeading, .topTrailing]),
        (.left, [.topTrailing, .bottomTrailing]),
        (.right, [.topLeading, .bottomLeading]),
        (.center, .all)
    ]

    @Test(arguments: exposedCorners)
    func roundedCorners_roundOnlyTheExposedCorners(
        position: QuickTerminalPosition,
        expected: QuickTerminalCorners
    ) {
        #expect(QuickTerminalLayout.roundedCorners(for: position) == expected)
    }
}
