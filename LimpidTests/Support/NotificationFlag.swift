// NotificationFlag.swift
// Limpid — records whether an Observation change fired.

import Foundation

/// `withObservationTracking` hands its callback to an arbitrary context, so
/// the flag needs to be a reference the closure can mutate rather than a
/// captured local.
final class NotificationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
