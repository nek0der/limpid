// SurfaceCompositionTests.swift
// Weir — which keys delivered after Dictation or an input method commits reach the shell.

import Foundation
import Testing
@testable import Weir

@Suite("Surface composition")
@MainActor
struct SurfaceCompositionTests {
    /// Return or the keypad's Enter inside the commit's window, closed at
    /// both ends, is the key that caused the commit and is consumed; one
    /// before it, or after the microphone ended it even by a moment, is
    /// forwarded. The window closes on the first key either way, so the
    /// next Enter is forwarded.
    @Test("An Enter is consumed only inside the commit's window, once", arguments: [
        (UInt16(36), TimeInterval(101.999), true),
        (76, 101.999, true),
        (36, 102, true),
        (36, 102.000001, false),
        (36, 99.999, false)
    ])
    func asynchronousCommit_consumesOnlyTheEnterInsideItsWindow(keyCode: UInt16, timestamp: TimeInterval, isConsumed: Bool) {
        var interval: ClosedRange<TimeInterval>? = 100...102
        #expect(SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: keyCode, timestamp: timestamp, interval: &interval
        ) == isConsumed)
        #expect(interval == nil)
    }

    @Test("Editing keys retain their normal handling", arguments: [UInt16(53), UInt16(51), UInt16(0)])
    func asynchronousCommit_preservesOtherKeys(keyCode: UInt16) {
        var interval: ClosedRange<TimeInterval>? = 100...102
        #expect(!SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: keyCode, timestamp: 101, interval: &interval
        ))
        #expect(interval == nil)
    }

    @Test("Without an asynchronous commit Enter retains its normal handling")
    func noAsynchronousCommit_preservesEnter() {
        var interval: ClosedRange<TimeInterval>?
        #expect(!SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: 36, timestamp: 101, interval: &interval
        ))
    }

    /// `commitText` writes its argument to the pty verbatim, so a lone
    /// control character an input method emits has to be screened out
    /// before it reaches the shell.
    @Test(
        "A lone control character from an input method is dropped",
        arguments: ["\r", "\n", "\t", "\u{1B}", "\u{00}"]
    )
    func suppressibleControlInput_dropsLoneControlCharacter(text: String) {
        #expect(SurfaceView.isSuppressibleControlInput(text))
    }

    /// Everything an input method legitimately commits survives,
    /// including DEL, which sits above the control range we screen.
    @Test(
        "Committed text is forwarded",
        arguments: ["\u{5C71}\u{7530}", "a", "\r\n", "", "\u{7F}", "\u{1F600}"]
    )
    func suppressibleControlInput_preservesCommittedText(text: String) {
        #expect(!SurfaceView.isSuppressibleControlInput(text))
    }
}
