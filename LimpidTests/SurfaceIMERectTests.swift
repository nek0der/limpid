// SurfaceIMERectTests.swift
// Limpid — coverage for the IME point → AppKit rect conversion that
// `NSTextInputClient.firstRect(forCharacterRange:)` hands to the input
// system. The surface handle can't be created headlessly, so the
// conversion is exercised as a pure function over libghostty's output.

import AppKit
import Testing
@testable import Limpid

@Suite("Surface IME rect")
@MainActor
struct SurfaceIMERectTests {

    @Test("libghostty's top-left y becomes an AppKit bottom-left y")
    func imeViewRect_flipsVerticalOrigin() {
        let rect = SurfaceView.imeViewRect(
            from: NSRect(x: 40, y: 100, width: 0, height: 20),
            range: NSRange(location: 0, length: 0),
            viewHeight: 400
        )
        #expect(rect.origin.x == 40)
        #expect(rect.origin.y == 300)
        #expect(rect.height == 20)
    }

    @Test("An empty range collapses the preedit width")
    func imeViewRect_emptyRange_collapsesWidth() {
        let rect = SurfaceView.imeViewRect(
            from: NSRect(x: 40, y: 100, width: 32, height: 20),
            range: NSRange(location: 0, length: 0),
            viewHeight: 400
        )
        #expect(rect.width == 0)
    }

    @Test("A composed range keeps the preedit width")
    func imeViewRect_composedRange_keepsWidth() {
        let rect = SurfaceView.imeViewRect(
            from: NSRect(x: 40, y: 100, width: 32, height: 20),
            range: NSRange(location: 0, length: 3),
            viewHeight: 400
        )
        #expect(rect.width == 32)
    }

    /// Dictation reads this rect to place its insertion point, so the
    /// caret on the first row must still carry the cell height rather
    /// than collapsing onto the view's top edge.
    @Test("A caret on the first row keeps the cell height")
    func imeViewRect_caretOnFirstRow_keepsHeight() {
        let rect = SurfaceView.imeViewRect(
            from: NSRect(x: 0, y: 20, width: 0, height: 20),
            range: NSRange(location: 0, length: 0),
            viewHeight: 400
        )
        #expect(rect.height == 20)
        #expect(rect.origin.y == 380)
    }
}
