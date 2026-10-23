// ProjectWindowMinimumSizeTests.swift
// Limpid — a main window keeps the supervision layout's minimum once shown, and a narrower saved frame is widened to it.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

/// The window is shown for real (transparent): the hosting view writes the
/// window's minimum in its constraints pass once the window is on screen,
/// which is where a minimum set only on the window was lost.
@MainActor
@Suite("Project window minimum size")
struct ProjectWindowMinimumSizeTests {
    /// The title bar the root is laid out under, which the window's content
    /// minimum adds to the root's.
    private static let titleBarHeight: CGFloat = 32

    private static func makeController(_ root: some View = Color.clear) -> ProjectWindowController {
        ProjectWindowController(
            windowID: WindowID(),
            rootView: AnyView(root),
            events: .init(
                close: { _ in },
                becameKey: { _ in },
                resignedKey: { _ in },
                willEnterFullScreen: { _ in },
                fullScreenSettled: { _ in }
            )
        )
    }

    /// Puts the window on screen without drawing it in front of anything,
    /// and runs the constraints pass in which the hosting view writes the
    /// window's minimum, so what it writes is read in a fixed order rather
    /// than after waiting on the run loop.
    private static func show(_ window: NSWindow) {
        window.alphaValue = 0
        window.orderBack(nil)
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
    }

    @Test func newWindow_hasTheMinimumBeforeItIsShown() throws {
        let window = try #require(Self.makeController().window)
        #expect(window.contentMinSize == NSSize(width: 730, height: LimpidLayout.mainWindowMinHeight + Self.titleBarHeight))
    }

    /// The hosting view owns no minimum of its own, so once shown it must
    /// not write zero over the window's, which would let a drag take the
    /// window down to a few hundred points. Shown, the window keeps the
    /// floor it had before, height included, so a restore widens to the
    /// same floor the window is held to afterwards.
    @Test func shownWindow_keepsTheMinimumItHadBefore() throws {
        let window = try #require(Self.makeController().window)
        let before = window.contentMinSize
        defer { window.close() }
        Self.show(window)
        #expect(window.contentMinSize == before)
        #expect(window.contentMinSize.width == 730)
        #expect(window.minSize.width >= 730)
    }

    /// Content wider than the floor (a sidebar at its saved width) does
    /// not raise the window's minimum.
    @Test func shownWindow_rigidWideContent_doesNotRaiseTheMinimum() throws {
        let window = try #require(Self.makeController(Color.clear.frame(width: 1200, height: 900)).window)
        defer { window.close() }
        Self.show(window)
        #expect(window.contentMinSize == NSSize(width: 730, height: LimpidLayout.mainWindowMinHeight + Self.titleBarHeight))
    }

    private static func restored(width: CGFloat, contentHeight: CGFloat) throws -> CGRect {
        let window = try #require(makeController().window)
        defer { window.close() }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = window.frameRect(forContentRect: CGRect(x: screen.minX + 20, y: screen.minY + 20, width: width, height: contentHeight))
        let selection = WindowSelection()
        selection.frame = saved
        let sync = WindowFrameSync(selection: selection, window: window)
        defer { withExtendedLifetime(sync) {} }
        return window.contentRect(forFrameRect: window.frame)
    }

    /// A frame saved narrower than the minimum (an older build's 600pt
    /// floor, or a snapshot written by hand) opens at the minimum.
    @Test func restoredNarrowFrame_isWidenedToTheMinimum() throws {
        let content = try Self.restored(width: 396, contentHeight: 300)
        #expect(content.width >= 730)
        #expect(content.height >= LimpidLayout.mainWindowMinHeight + Self.titleBarHeight)
    }

    /// Saved at the root's 400pt, the window opens with room for the title
    /// bar over it too, so the root does not run past the window's edges.
    @Test func restoredFrameAtTheRootsHeight_isWidenedByTheTitleBar() throws {
        let content = try Self.restored(width: 1000, contentHeight: 400)
        #expect(content.height >= 432)
        #expect(content.width == 1000)
    }
}
