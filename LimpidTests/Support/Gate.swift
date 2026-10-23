// Gate.swift
// Limpid — a response the test holds until it says what the answer is.

import Foundation

/// Holds every caller of `wait()` until the test calls `open(with:)`, then
/// hands each of them, and every later caller, that value.
///
/// A test that has to act while a read, a send, or a listing is in flight
/// needs the call to stop where it is rather than after a wall-clock delay,
/// which is either too long or, on a busy machine, too short. The state sits
/// behind a lock rather than in an actor so that a stub on any actor, and a
/// synchronous `pollUntil` condition, can read it without a hop. Opening
/// before anyone waits is allowed: the value is kept, so the order of the
/// test's two steps cannot hang it.
final class Gate<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case closed
        case open(Value)
    }

    private let lock = NSLock()
    private var state = State.closed
    private var waiting: [CheckedContinuation<Value, Never>] = []
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var requestCount = 0

    /// How many callers have reached `wait()`, held or not.
    var requests: Int {
        lock.withLock { requestCount }
    }

    /// Returns the value the test opens with, at once if it already has.
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let (ready, reached): (Value?, [CheckedContinuation<Void, Never>]) = lock.withLock {
                requestCount += 1
                let reached = takeObservers(reaching: requestCount)
                if case let .open(value) = state {
                    return (value, reached)
                }
                waiting.append(continuation)
                return (nil, reached)
            }
            reached.forEach { $0.resume() }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// Returns once `count` callers have reached `wait()`.
    func waitUntilRequested(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let isReached = lock.withLock {
                guard requestCount < count else { return true }
                observers.append((count, continuation))
                return false
            }
            if isReached {
                continuation.resume()
            }
        }
    }

    /// Lets every held caller go with `value`, and every later one too.
    func open(with value: Value) {
        let held: [CheckedContinuation<Value, Never>] = lock.withLock {
            state = .open(value)
            defer { waiting = [] }
            return waiting
        }
        held.forEach { $0.resume(returning: value) }
    }

    /// Called under the lock.
    private func takeObservers(reaching count: Int) -> [CheckedContinuation<Void, Never>] {
        let reached = observers.filter { $0.count <= count }.map(\.continuation)
        observers.removeAll { $0.count <= count }
        return reached
    }
}

extension Gate where Value == Void {
    func open() {
        open(with: ())
    }

    /// Writes `start` and `end` around the wait, so a test can read in which
    /// order calls reached the gate and left it.
    func pass(_ name: String, loggingTo log: Recorded<[String]>) async {
        log.update { $0.append("start \(name)") }
        await wait()
        log.update { $0.append("end \(name)") }
    }
}
