// Recorded.swift
// Limpid — a value a callback writes and the test reads, held by reference.

import Foundation

/// A notification observer or an injected provider is a `@Sendable` or
/// main-actor closure, so a captured local it writes (or the test changes
/// after handing it over) is a data race to the compiler. Holding the value
/// in a reference behind a lock says what the test means: one value, read
/// and written from wherever the callback runs. `Recorded(false)` is also the
/// flag a `withObservationTracking` change handler sets, since that handler
/// runs in a context of its own choosing.
final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}
