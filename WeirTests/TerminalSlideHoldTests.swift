// TerminalSlideHoldTests.swift
// Weir — the terminal is resized once, not on every frame, while its pane's frame slides.

import AppKit
import Testing
@testable import Weir

@MainActor
struct TerminalSlideHoldTests {
    private static let height: CGFloat = 400

    /// The frames AppKit is given from `start` to `end`, a step per display
    /// frame, as SwiftUI moves a pane's view through a slide.
    private func steps(from start: CGFloat, to end: CGFloat, count: Int = 15) -> [CGFloat] {
        (1...count).map { start + (end - start) * CGFloat($0) / CGFloat(count) }
    }

    /// The widths the terminal is laid at through a slide, by the rule.
    private func ruleWidths(from start: CGFloat, to end: CGFloat) -> [CGFloat] {
        var laid = CGSize(width: start, height: Self.height)
        let layout = CGSize(width: end, height: Self.height)
        return steps(from: start, to: end).map { width in
            laid = TerminalSlideHold.size(frame: CGSize(width: width, height: Self.height), layout: layout, laid: laid)
            return laid.width
        }
    }

    @Test func aGrowingPane_takesItsEndWidthAtOnce() {
        let widths = ruleWidths(from: 600, to: 900)
        #expect(widths.allSatisfy { $0 == 900 })
    }

    /// Shrinking, it keeps its width until the frame gets there, so no
    /// empty ground shows beside it during the slide.
    @Test func aShrinkingPane_keepsItsWidthUntilTheSlideEnds() {
        let widths = ruleWidths(from: 900, to: 600)
        #expect(widths.dropLast().allSatisfy { $0 == 900 })
        #expect(widths.last == 600)
    }

    @Test func atRest_theTerminalTakesTheLayoutsSize() {
        let size = CGSize(width: 700, height: Self.height)
        #expect(TerminalSlideHold.size(frame: size, layout: size, laid: CGSize(width: 500, height: 300)) == size)
        #expect(TerminalSlideHold.size(frame: size, layout: nil, laid: nil) == size)
    }

    // MARK: - The scroll host

    /// The sizes the surface view is given while `host` goes through a
    /// slide as SwiftUI drives it: the layout's end size first, through
    /// `applyExpectedSize`, then the frame a step at a time.
    private func surfaceWidths(in host: TerminalScrollView, surface: SurfaceView, from start: CGFloat, to end: CGFloat) -> [CGFloat] {
        var widths: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: surface,
            queue: nil
        ) { note in
            // The view the notification names, as an `NSView`, which is the
            // main actor's: `SurfaceView` itself is not Sendable, and AppKit
            // posts this on the main thread.
            let view = note.object as? NSView
            MainActor.assumeIsolated {
                guard let width = view?.frame.width else { return }
                if widths.last != width {
                    widths.append(width)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        host.applyExpectedSize(CGSize(width: end, height: Self.height))
        for width in steps(from: start, to: end) {
            host.setFrameSize(CGSize(width: width, height: Self.height))
            host.layoutSubtreeIfNeeded()
        }
        return widths
    }

    private func makeHost(width: CGFloat) throws -> (TerminalScrollView, SurfaceView) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let surface = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])
        let host = TerminalScrollView(surfaceView: surface)
        let start = CGSize(width: width, height: Self.height)
        host.setFrameSize(start)
        host.applyExpectedSize(start)
        host.layoutSubtreeIfNeeded()
        return (host, surface)
    }

    /// The panel opening: the pane shrinks, and its surface (whose size is
    /// what reaches the pty) changes once, at the end.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func theScrollHost_resizesAShrinkingSurfaceOnce_atTheEnd() throws {
        let (host, surface) = try makeHost(width: 900)
        let widths = surfaceWidths(in: host, surface: surface, from: 900, to: 600)
        #expect(widths == [600])
        #expect(surface.frame.width == 600)
    }

    /// The sidebar hiding: the pane grows, and its surface takes the end
    /// width once, as the slide starts.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func theScrollHost_resizesAGrowingSurfaceOnce_atTheStart() throws {
        let (host, surface) = try makeHost(width: 600)
        let widths = surfaceWidths(in: host, surface: surface, from: 600, to: 900)
        #expect(widths == [900])
        #expect(surface.frame.width == 900)
    }
}
