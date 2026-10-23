// HostsWindows.swift
// Limpid — runs the tests that put real windows on screen one at a time, while every other test runs in parallel.

import Foundation
import Testing

/// Marks a suite or test that hosts real windows, so it never overlaps
/// another one that does.
///
/// Key status, the first responder and the field editor belong to the app,
/// not to one window. When two such tests ran at once, one's window took the
/// keyboard from the other's: a field never became first responder, or
/// scrolled before it was measured. `.serialized` would order a suite's own
/// tests only, and these suites are many, so every test marked with this
/// trait waits for one shared turn instead.
struct HostsWindows: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    /// One turn per test case. A suite or a parameterized test as a whole
    /// gets none, so its cases do not wait behind the turn it would hold.
    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await WindowTestTurn.shared.take()
        defer { WindowTestTurn.shared.pass() }
        try await function()
    }
}

extension Trait where Self == HostsWindows {
    /// Runs the test, or every test of the suite, in turn with the other
    /// tests that host windows.
    static var hostsWindows: Self {
        Self()
    }
}

/// The one turn the window tests share, handed on in the order they asked.
/// Behind a lock rather than an actor so `pass()` can run from a `defer`.
private final class WindowTestTurn: @unchecked Sendable {
    static let shared = WindowTestTurn()

    private let lock = NSLock()
    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        await withCheckedContinuation { continuation in
            let isFree: Bool = lock.withLock {
                if isTaken {
                    waiting.append(continuation)
                    return false
                }
                isTaken = true
                return true
            }
            if isFree {
                continuation.resume()
            }
        }
    }

    func pass() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiting.isEmpty {
                isTaken = false
                return nil
            }
            return waiting.removeFirst()
        }
        next?.resume()
    }
}
