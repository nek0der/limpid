// OneShotTests.swift
// Limpid — first-call-wins semantics for the Sparkle reply /
// acknowledgment wrapper. Sparkle's contract is that each callback
// fires exactly once — forgetting stalls the updater, doubling
// asserts — so the OneShot wrapper is load-bearing for the update
// pipeline.

import Foundation
import Testing
@testable import Limpid

@Suite("OneShot")
@MainActor
struct OneShotTests {
    @Test("first call fires the wrapped closure with the supplied argument")
    func firstCall_fires() {
        var received: String?
        let shot = OneShot<String> { received = $0 }
        #expect(!shot.hasFired)
        shot.call("hello")
        #expect(received == "hello")
        #expect(shot.hasFired)
    }

    @Test("second call is silently dropped")
    func secondCall_noOp() {
        var count = 0
        let shot = OneShot<Void> { count += 1 }
        shot.call()
        shot.call()
        shot.call()
        #expect(count == 1)
    }

    @Test("closure is released after firing so retained state can deallocate")
    func closure_releasedAfterFiring() {
        final class Sink {}
        weak var weakSink: Sink?
        /// Made in a function of its own, so the shot's closure is all that
        /// holds the sink once it returns.
        func makeShot() -> OneShot<Void> {
            let sink = Sink()
            weakSink = sink
            return OneShot<Void> { _ = sink }
        }
        let shot = makeShot()
        #expect(weakSink != nil)
        shot.call()
        // The shot is still held here, so only its dropping the callback
        // lets the sink go.
        #expect(weakSink == nil)
        withExtendedLifetime(shot) {}
    }
}
