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
    func burst_foldsIntoOneTrailingPass() async {
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
        await pollUntil(interval: .milliseconds(5)) { passes == 2 }
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

        // Nothing says a canceled pass will never run, so this outwaits the
        // window the pass was owed at.
        try await Task.sleep(for: .seconds(0.1))
        #expect(passes == 1)
    }

    @Test("a pass the rules asked for later runs then, and a newer answer replaces it")
    func requestIn_runsLater_andTheLatestAnswerWins() async throws {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, run: { passes += 1 })

        coalescer.request(in: .milliseconds(20))
        // A pass by another route reads what changed, but not the moment a
        // held notice is due, so it leaves the asked-for pass in place.
        coalescer.didRun()
        #expect(passes == 0)
        await pollUntil(interval: .milliseconds(5)) { passes == 1 }
        #expect(passes == 1)

        // The next answer holds nothing, so nothing is owed. Nothing says a
        // canceled pass will never run, so this outwaits its 20 ms.
        coalescer.request(in: .milliseconds(20))
        coalescer.request(in: nil)
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
