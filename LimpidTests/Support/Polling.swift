// Polling.swift
// Limpid — waits for a condition a test cannot await directly.

import Foundation

/// Checks `condition` until it holds or `timeout` passes, for work a test
/// starts but cannot await: a task the code under test spawns, a hop back to
/// the main actor, an actor's state. The deadline makes a broken path fail
/// the expectations that follow instead of hanging the suite. Between checks
/// it yields, or sleeps for `interval` when given, which also lets the main
/// run loop deliver what AppKit or libghostty dispatched to it. It runs on
/// the caller's actor, so `condition` may read that actor's state.
///
/// The deadline is on `SuspendingClock`, which stands still while the Mac
/// sleeps, as the `DispatchTime` timers the code under test schedules do.
/// On `ContinuousClock` a sleep in the middle of a run passed the deadline
/// at wake while those timers still had their whole delay to go.
func pollUntil(
    timeout: Duration = .seconds(2),
    interval: Duration? = nil,
    isolation _: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    // A canceled test stops at once rather than spinning to the deadline.
    while !condition(), clock.now < deadline, !Task.isCancelled {
        if let interval {
            try? await Task.sleep(for: interval)
        } else {
            await Task.yield()
        }
    }
}

extension Process {
    /// Waits for the process to exit, at most `seconds`, and stops it when
    /// it has not: a script that hangs (a shim waiting on input) then fails
    /// its test rather than stopping the run, as `waitUntilExit` would.
    /// Stopped with SIGTERM, then SIGKILL after two seconds more: `.timeLimit`
    /// cannot end a test blocked here, so one that ignores SIGTERM would hold
    /// the run until it chose to exit. Whether it exited in time.
    @discardableResult
    func waitUntilExit(within seconds: TimeInterval) -> Bool {
        guard !waitWhileRunning(seconds) else { return true }
        terminate()
        if !waitWhileRunning(2) {
            kill(processIdentifier, SIGKILL)
        }
        waitUntilExit()
        return false
    }

    /// Whether the process exited within `seconds`, on `SuspendingClock` as
    /// `pollUntil` is: a Mac asleep meanwhile gives the process no time.
    private func waitWhileRunning(_ seconds: TimeInterval) -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(seconds)
        while isRunning, clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isRunning
    }
}
