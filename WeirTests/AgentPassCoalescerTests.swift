// AgentPassCoalescerTests.swift
// Weir — a burst of file events becomes one pass now and one pass later.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("AgentPassCoalescer")
struct AgentPassCoalescerTests {
    /// A clock the test advances by hand, so the leading edge and the window
    /// are exact rather than a race against the scheduler. `ManualTimer`
    /// steps the delayed passes the same way.
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
    func burst_foldsIntoOneTrailingPass() {
        let clock = Clock()
        let timer = ManualTimer()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, timer: timer.timer, run: { passes += 1 })

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
        timer.advance(by: .milliseconds(20))
        #expect(passes == 2)
    }

    @Test("a pass another route ran cancels the trailing pass it was owed")
    func passByAnotherRoute_cancelsTheTrailingPass() {
        let clock = Clock()
        let timer = ManualTimer()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, timer: timer.timer, run: { passes += 1 })

        coalescer.request()
        clock.now += 0.005
        coalescer.request()
        #expect(passes == 1)

        // The sweep, say, ran a pass after the second event arrived: it read
        // everything that event was about, so nothing is owed any more.
        clock.now += 0.005
        coalescer.didRun()

        timer.advance(by: .milliseconds(20))
        #expect(passes == 1)
    }

    @Test("a pass the rules asked for later runs then, and a newer answer replaces it")
    func requestIn_runsLater_andTheLatestAnswerWins() {
        let clock = Clock()
        let timer = ManualTimer()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, timer: timer.timer, run: { passes += 1 })

        coalescer.request(in: .milliseconds(20))
        // A pass by another route reads what changed, but not the moment a
        // held notice is due, so it leaves the asked-for pass in place.
        coalescer.didRun()
        #expect(passes == 0)
        timer.advance(by: .milliseconds(19))
        #expect(passes == 0)
        timer.advance(by: .milliseconds(1))
        #expect(passes == 1)

        // The next answer holds nothing, so nothing is owed.
        coalescer.request(in: .milliseconds(20))
        coalescer.request(in: nil)
        timer.advance(by: .milliseconds(20))
        #expect(passes == 1)
    }

    /// The one case on the timer the app uses: the passes above run by hand.
    @Test("the app's timer runs a pass that is owed")
    func theLiveTimer_runsTheTrailingPass() async {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, run: { passes += 1 })

        coalescer.request()
        coalescer.request()
        #expect(passes == 1)

        await pollUntil(interval: .milliseconds(5)) { passes == 2 }
        #expect(passes == 2)
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
