// SurfaceCompositionTests.swift
// Limpid — regression coverage for keys delivered after Dictation commits.

import Foundation
import Testing
@testable import Limpid

@Suite("Surface composition")
@MainActor
struct SurfaceCompositionTests {
    @Test("An Enter pressed during composition is consumed once", arguments: [UInt16(36), UInt16(76)])
    func asynchronousCommit_consumesTerminatingEnter(keyCode: UInt16) {
        var interval: ClosedRange<TimeInterval>? = 100...102
        #expect(SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: keyCode, timestamp: 101.999, interval: &interval
        ))
        #expect(interval == nil)
        #expect(!SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: keyCode, timestamp: 102.1, interval: &interval
        ))
    }

    /// The window is closed at both ends: a key delivered exactly at the
    /// commit is still the one that caused it.
    @Test("The commit instant itself is inside the window")
    func asynchronousCommit_consumesEnterAtUpperBound() {
        var interval: ClosedRange<TimeInterval>? = 100...102
        #expect(SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: 36, timestamp: 102, interval: &interval
        ))
    }

    @Test("An Enter pressed after microphone termination is forwarded even immediately after commit")
    func microphoneTermination_preservesNextEnter() {
        var interval: ClosedRange<TimeInterval>? = 100...102
        #expect(!SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: 36, timestamp: 102.000001, interval: &interval
        ))
        #expect(interval == nil)
    }

    @Test("A stale Enter from before composition is forwarded")
    func asynchronousCommit_preservesEarlierEnter() {
        var interval: ClosedRange<TimeInterval>? = 100...102
        #expect(!SurfaceView.consumeAsynchronousCompositionEnter(
            keyCode: 36, timestamp: 99.999, interval: &interval
        ))
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
