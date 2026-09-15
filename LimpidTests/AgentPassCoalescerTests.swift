// AgentPassCoalescerTests.swift
// Limpid — a burst of file events becomes one pass now and one pass later.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentPassCoalescer")
struct AgentPassCoalescerTests {
    /// A clock the test advances by hand, so the leading edge and the window
    /// are exact rather than a race against the scheduler.
    @MainActor
    final class Clock {
        var now: TimeInterval = 100
    }

    @Test("the first request of a burst runs at once")
    func firstRequest_runsImmediately() {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.05, now: { clock.now }, run: { passes += 1 })

        coalescer.request()

        // The badge a hook just wrote must not wait for the window to close.
        #expect(passes == 1)
    }

    @Test("requests inside the window fold into a single trailing pass")
    func burst_foldsIntoOneTrailingPass() async throws {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, run: { passes += 1 })

        coalescer.request()
        clock.now += 0.005
        coalescer.request()
        clock.now += 0.005
        coalescer.request()
        clock.now += 0.005
        coalescer.request()
        #expect(passes == 1, "the burst must not run a pass per event")

        // The trailing pass is what carries the last write of the burst; a
        // coalescer that only dropped events would leave the interface on
        // whatever the first pass saw.
        try await Task.sleep(for: .seconds(0.1))
        #expect(passes == 2)
    }

    @Test("a pass another route ran cancels the trailing pass it was owed")
    func passByAnotherRoute_cancelsTheTrailingPass() async throws {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, run: { passes += 1 })

        coalescer.request()
        clock.now += 0.005
        coalescer.request()
        #expect(passes == 1)

        // The sweep, say, ran a pass after the second event arrived: it read
        // everything that event was about, so nothing is owed any more.
        clock.now += 0.005
        coalescer.didRun()

        try await Task.sleep(for: .seconds(0.1))
        #expect(passes == 1)
    }

    @Test("a request after the window has closed runs at once again")
    func requestAfterTheWindow_runsImmediately() {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.05, now: { clock.now }, run: { passes += 1 })

        coalescer.request()
        clock.now += 1
        coalescer.request()

        #expect(passes == 2)
    }
}
