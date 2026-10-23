// FullScreenEntryQueue.swift
// Limpid — takes the windows saved in full screen back into it one at a time.

import Foundation

/// Which window saved in full screen goes back into it next. AppKit
/// moves windows into full screen one at a time and can drop a request made
/// while another window is on its way, so we ask for one at a time: the
/// next goes once the one on its way has arrived, failed, been hidden, or
/// shown no sign of starting. Only that window lets the next go, so a
/// window the person takes into full screen meanwhile does not. A value, so
/// the order is tested without AppKit.
struct FullScreenEntryQueue: Equatable, Sendable {
    private(set) var waiting: [WindowID] = []
    /// The window asked to enter full screen and not yet settled.
    private(set) var entering: WindowID?
    /// Whether the window on its way has begun its transition.
    private(set) var hasStarted = false
    /// Counts the requests made, so a time limit set for one request is
    /// not taken for a later request of the same window.
    private(set) var attempt = 0
    /// The window to bring to the front once the last one has gone into
    /// full screen: entering full screen moves to that window's Space,
    /// which would leave another window in front than the one last used.
    private(set) var front: WindowID?

    /// Whether no window is waiting or on its way.
    var isIdle: Bool {
        entering == nil && waiting.isEmpty
    }

    /// Adds `window` to the line. Returns the window to take into full
    /// screen now, if one may go.
    mutating func add(_ window: WindowID) -> WindowID? {
        if entering != window, !waiting.contains(window) {
            waiting.append(window)
        }
        return advance()
    }

    /// `window` began its transition into full screen.
    mutating func started(_ window: WindowID) {
        if entering == window {
            hasStarted = true
        }
    }

    /// `window` arrived in full screen, or could not. Returns the next.
    mutating func settled(_ window: WindowID) -> WindowID? {
        guard entering == window else { return nil }
        entering = nil
        hasStarted = false
        return advance()
    }

    /// The time given request `attempt` of `window` to begin has passed.
    /// A window that has not begun had its request dropped; the next goes.
    /// Returns the next.
    mutating func timedOut(_ window: WindowID, attempt: Int) -> WindowID? {
        guard entering == window, self.attempt == attempt, !hasStarted else { return nil }
        return settled(window)
    }

    /// `window` was hidden: it waits no more, and lets the next go if it
    /// was on its way. `wasPending` says whether it was still to go into
    /// full screen, so it can when it is shown again.
    /// A hidden window is not brought back to the front either.
    mutating func withdraw(_ window: WindowID) -> (wasPending: Bool, next: WindowID?) {
        let wasWaiting = waiting.contains(window)
        waiting.removeAll { $0 == window }
        let wasEntering = entering == window
        if front == window {
            front = nil
        }
        return (wasWaiting || wasEntering, settled(window))
    }

    /// Asks for `window` to come to the front once the line is done.
    /// Nothing to do while it is already done.
    mutating func raiseWhenDone(_ window: WindowID) {
        if !isIdle {
            front = window
        }
    }

    /// `window` was shown. Another window shown after the line was asked
    /// to bring one to the front is the person's choice, and stays in
    /// front.
    mutating func shown(_ window: WindowID) {
        if front != nil, front != window {
            front = nil
        }
    }

    /// The window to bring to the front now that the line is done, once.
    mutating func takeFrontIfDone() -> WindowID? {
        guard isIdle, let front else { return nil }
        self.front = nil
        return front
    }

    private mutating func advance() -> WindowID? {
        guard entering == nil, !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        entering = next
        attempt += 1
        return next
    }
}
