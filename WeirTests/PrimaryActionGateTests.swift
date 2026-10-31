// PrimaryActionGateTests.swift
// Weir — when ⌘⏎ performs the decision bar's primary button, is dropped, or reaches the terminal.

import Foundation
import Testing
@testable import Weir

struct PrimaryActionGateTests {
    private static let pane = UUID()
    private static let otherPane = UUID()
    private static let bar = UUID()
    private static let stop = AttentionItemID.stop(EpisodeKey(origin: .runtime("r1"), episodeToken: "1"))
    private static let otherStop = AttentionItemID.stop(EpisodeKey(origin: .runtime("r1"), episodeToken: "2"))
    private static let press = PrimaryKeyPress(isCommandOnly: true, isComposing: false)

    private static func gate(
        showing itemID: AttentionItemID? = stop,
        action: PrimaryAction? = .resume(stop),
        at start: SuspendingClock.Instant
    ) -> PrimaryActionGate {
        var gate = PrimaryActionGate()
        gate.noteShown(itemID, primaryAction: action, inPane: pane, by: bar, at: start)
        return gate
    }

    private static func decide(
        _ gate: inout PrimaryActionGate,
        _ press: PrimaryKeyPress = press,
        inPane paneID: UUID = pane,
        hasAgent: Bool = true,
        isApprovalCardFocused: Bool = false,
        at now: SuspendingClock.Instant
    ) -> PrimaryActionGate.Decision {
        gate.decide(press, inPane: paneID, hasAgent: hasAgent, isApprovalCardFocused: isApprovalCardFocused, at: now)
    }

    @Test func aPressSoonAfterTheItemChanged_isDropped_notPassedOn() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(599))) == .swallow)
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(600))) == .perform(.resume(Self.stop)))
    }

    @Test func theSettleTime_startsOverWhenTheItemOrItsButtonChanges_only() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        // Drawn again with the same item: the wait does not start over.
        gate.noteShown(Self.stop, primaryAction: .resume(Self.stop), inPane: Self.pane, by: Self.bar, at: start.advanced(by: .seconds(1)))
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(1100))) == .perform(.resume(Self.stop)))

        // Another item, or the same item gaining its button, waits again.
        gate.noteShown(
            Self.otherStop,
            primaryAction: .resume(Self.otherStop),
            inPane: Self.pane,
            by: Self.bar,
            at: start.advanced(by: .seconds(2))
        )
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(2300))) == .swallow)
        gate.noteShown(Self.otherStop, primaryAction: nil, inPane: Self.pane, by: Self.bar, at: start.advanced(by: .seconds(3)))
        gate.noteShown(
            Self.otherStop,
            primaryAction: .resume(Self.otherStop),
            inPane: Self.pane,
            by: Self.bar,
            at: start.advanced(by: .seconds(4))
        )
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(4300))) == .swallow)
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(5))) == .perform(.resume(Self.otherStop)))
    }

    @Test func inAPaneWithABar_theKeyNeverReachesTheTerminal() {
        // An approval, a question, the agent at rest: ⌘⏎ never answers one,
        // and the agent would read it as Return.
        let start = SuspendingClock().now
        var gate = Self.gate(showing: .approval(ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())), action: nil, at: start)
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(1))) == .swallow)
        gate.noteShown(nil, primaryAction: nil, inPane: Self.pane, by: Self.bar, at: start.advanced(by: .seconds(2)))
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(3))) == .swallow)
    }

    @Test func aPaneWithNoAgent_isTheTerminals() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        #expect(Self.decide(&gate, inPane: Self.otherPane, hasAgent: false, at: start) == .passThrough)
        gate.forget(pane: Self.pane, by: Self.bar)
        #expect(Self.decide(&gate, hasAgent: false, at: start.advanced(by: .seconds(1))) == .passThrough)
    }

    @Test func anAgentsPaneWhoseBarIsHidden_stillKeepsTheKey() {
        // Review hides the bar while the agent's terminal stays in sight.
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        gate.forget(pane: Self.pane, by: Self.bar)
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(1))) == .swallow)
        #expect(Self.decide(&gate, inPane: Self.otherPane, at: start) == .swallow)
    }

    @Test func aPanesNewBar_keepsItsEntry_whicheverGoesFirst() {
        // A split or a zoom draws the pane's bar anew; SwiftUI may show the
        // new one before the old one disappears.
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        let newBar = UUID()
        gate.noteShown(
            Self.stop,
            primaryAction: .resume(Self.stop),
            inPane: Self.pane,
            by: newBar,
            at: start.advanced(by: .milliseconds(500))
        )
        gate.forget(pane: Self.pane, by: Self.bar)
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(700))) == .perform(.resume(Self.stop)), "same item: no new wait")

        // The other order: the old bar goes first, and the new one starts
        // the wait over, since for a moment nothing was on screen.
        var other = Self.gate(at: start)
        other.forget(pane: Self.pane, by: Self.bar)
        other.noteShown(
            Self.stop,
            primaryAction: .resume(Self.stop),
            inPane: Self.pane,
            by: newBar,
            at: start.advanced(by: .milliseconds(500))
        )
        #expect(Self.decide(&other, at: start.advanced(by: .milliseconds(700))) == .swallow)
        #expect(Self.decide(&other, at: start.advanced(by: .milliseconds(1100))) == .perform(.resume(Self.stop)))
    }

    @Test func aBarDrawnForAMomentBesideAnother_doesNotTakeTheKeyWithIt() {
        // Closing review draws the pane's bar twice for a moment, and the
        // second goes while the first stays on screen.
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        let passing = UUID()
        gate.noteShown(
            Self.stop,
            primaryAction: .resume(Self.stop),
            inPane: Self.pane,
            by: passing,
            at: start.advanced(by: .milliseconds(10))
        )
        gate.forget(pane: Self.pane, by: passing)

        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(2))) == .perform(.resume(Self.stop)))
        gate.forget(pane: Self.pane, by: Self.bar)
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(3))) == .swallow, "no bar left")
    }

    @Test func comingBackToTheFront_waitsAgain() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        gate.restartSettling(at: start.advanced(by: .seconds(5)))
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(5300))) == .swallow)
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(5600))) == .perform(.resume(Self.stop)))
    }

    @Test func anotherChord_isDroppedInAnAgentsPane_andAComposition_isTheTerminals() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        let later = start.advanced(by: .seconds(1))
        let chord = PrimaryKeyPress(isCommandOnly: false, isComposing: false)
        #expect(Self.decide(&gate, chord, at: later) == .swallow, "the agent would read ⌥⌘⏎ as Return too")
        #expect(Self.decide(&gate, chord, inPane: Self.otherPane, hasAgent: false, at: later) == .passThrough)
        // The input method keeps the key; it sends no Return of its own.
        #expect(Self.decide(&gate, PrimaryKeyPress(isCommandOnly: true, isComposing: true), at: later) == .passThrough)
        // None used up the press.
        #expect(Self.decide(&gate, at: later) == .perform(.resume(Self.stop)))
    }

    @Test func whileTheApprovalCardHasTheKeyboard_theKeyIsDropped() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        #expect(Self.decide(&gate, isApprovalCardFocused: true, at: start.advanced(by: .seconds(1))) == .swallow)
        // Even in a pane with no bar: the card took the key.
        #expect(Self.decide(&gate, inPane: Self.otherPane, isApprovalCardFocused: true, at: start) == .swallow)
    }

    @Test func aPressPerformsOnce_andAHeldKeyNever() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        let held = PrimaryKeyPress(isCommandOnly: true, isComposing: false, isRepeat: true)
        #expect(Self.decide(&gate, held, at: start.advanced(by: .seconds(1))) == .swallow)
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(2))) == .perform(.resume(Self.stop)))
        #expect(Self.decide(&gate, held, at: start.advanced(by: .seconds(3))) == .swallow)
        // The button is used up until the bar shows something new; the key
        // still goes nowhere, even after the bar is drawn anew for it.
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(4))) == .swallow)
        gate.forget(pane: Self.pane, by: Self.bar)
        gate.noteShown(
            Self.stop,
            primaryAction: .resume(Self.stop),
            inPane: Self.pane,
            by: UUID(),
            at: start.advanced(by: .milliseconds(4100))
        )
        #expect(Self.decide(&gate, at: start.advanced(by: .milliseconds(4900))) == .swallow)
        gate.noteShown(
            Self.otherStop,
            primaryAction: .resume(Self.otherStop),
            inPane: Self.pane,
            by: Self.bar,
            at: start.advanced(by: .seconds(5))
        )
        #expect(Self.decide(&gate, at: start.advanced(by: .seconds(6))) == .perform(.resume(Self.otherStop)))
    }

    @Test func eachPane_isDecidedOnItsOwnBar() {
        let start = SuspendingClock().now
        var gate = Self.gate(at: start)
        gate.noteShown(
            Self.otherStop,
            primaryAction: .resume(Self.otherStop),
            inPane: Self.otherPane,
            by: UUID(),
            at: start.advanced(by: .seconds(1))
        )
        let now = start.advanced(by: .milliseconds(1200))
        #expect(Self.decide(&gate, inPane: Self.otherPane, at: now) == .swallow)
        #expect(Self.decide(&gate, at: now) == .perform(.resume(Self.stop)), "the item shown in this pane, not the other's")
    }
}
