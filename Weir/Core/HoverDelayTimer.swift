// HoverDelayTimer.swift
// Weir — runs a delayed step unless it is canceled first, so what waits on a pointer or a burst shares one timer a test can step.

import Foundation

/// Runs a hover's delayed steps (the PR card's open delay and dismiss
/// grace, the conversation highlight's rest on a tab) and hands back what
/// cancels a step that has not run. `AgentPassCoalescer` and `DebouncedSave`
/// wait on it too. Tests pass a timer they step by hand, so they check the
/// order of the transitions without sleeping for them.
struct HoverDelayTimer: Sendable {
    /// Runs the action once the delay has passed, unless the returned
    /// cancel runs first.
    let schedule: @MainActor @Sendable (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// Sleeps on a task for the delay.
    static let live = HoverDelayTimer { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            // `try? await Task.sleep` swallows the cancellation error
            // and falls through, so a canceled step would otherwise run
            // at once: a show with no delay, or a dismissal with no grace.
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}
