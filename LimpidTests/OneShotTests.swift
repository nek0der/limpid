// OneShotTests.swift
// Limpid — first-call-wins semantics for the Sparkle reply /
// acknowledgement wrapper. Sparkle's contract is that each callback
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

    @Test("hasFired reflects post-call state, not pre-call")
    func hasFired_transitionsOnFirstCall() {
        let shot = OneShot<Int> { _ in }
        #expect(!shot.hasFired)
        shot.call(42)
        #expect(shot.hasFired)
    }

    @Test("Void specialization can be invoked without arguments")
    func voidSpecialization_callsWithoutArgument() {
        var fired = false
        let shot = OneShot<Void> { fired = true }
        shot.call() // parameterless overload — would fail to compile if missing
        #expect(fired)
    }

    @Test("closure is released after firing so retained state can deallocate")
    func closure_releasedAfterFiring() {
        final class Sink {}
        weak var weakSink: Sink?
        autoreleasepool {
            let sink = Sink()
            weakSink = sink
            let shot = OneShot<Void> { _ = sink }
            #expect(weakSink != nil)
            shot.call()
        }
        // After firing + autoreleasepool drain, the captured Sink
        // should be deallocated because OneShot nils out its
        // callback reference.
        #expect(weakSink == nil)
    }
}
