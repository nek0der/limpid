// DecisionRecorder.swift
// Weir — counts the decisions a store hands its sender, across the sender's isolation boundary.

import Foundation
@testable import Weir

/// What a store's injected `decisionSender` was called with, so a test can
/// observe what would have crossed the XPC boundary. `next()` counts a call
/// whose contents the test does not need; `append` keeps them.
actor DecisionRecorder {
    private(set) var entries: [(id: String, resolution: ApprovalResolution)] = []
    private(set) var count = 0

    /// Counts one call and returns how many there have been.
    @discardableResult
    func next() -> Int {
        count += 1
        return count
    }

    /// Counts one call to send `resolution` for the request `id`.
    func append(_ id: String, _ resolution: ApprovalResolution) {
        entries.append((id, resolution))
        count += 1
    }

    /// Waits until the sender was called `expected` times. The deadline makes
    /// a store that never calls its sender fail the expectations that follow
    /// instead of hanging the suite.
    func waitForCount(_ expected: Int) async {
        await pollUntil { count >= expected }
    }
}
