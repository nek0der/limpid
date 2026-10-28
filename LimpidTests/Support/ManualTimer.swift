// ManualTimer.swift
// Limpid — a hover timer the test steps by hand, so delayed hover steps run without sleeping.

import Foundation
@testable import Limpid

/// A timer the test steps by hand: a step runs when `advance` moves past
/// its deadline, in deadline order, unless it was canceled first. Shared by
/// the PR card's and the conversation highlight's hover suites, which both
/// take a `HoverDelayTimer`.
@MainActor
final class ManualTimer {
    private struct Step {
        let id: Int
        let deadline: Duration
        let action: @MainActor () -> Void
    }

    private var now = Duration.zero
    private var steps: [Step] = []
    private var nextID = 0

    var timer: HoverDelayTimer {
        HoverDelayTimer { [unowned self] delay, action in
            let id = nextID
            nextID += 1
            steps.append(Step(id: id, deadline: now + delay, action: action))
            return { [weak self] in self?.steps.removeAll { $0.id == id } }
        }
    }

    /// Moves time on by `interval`, running every step that falls due.
    func advance(by interval: Duration) {
        now += interval
        while let due = steps.filter({ $0.deadline <= now }).min(by: { $0.deadline < $1.deadline }) {
            steps.removeAll { $0.id == due.id }
            due.action()
        }
    }
}
