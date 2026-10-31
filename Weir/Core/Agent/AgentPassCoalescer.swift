// AgentPassCoalescer.swift
// Weir — folds a burst of file events into as few projection passes as it can,
// and runs the one the rules ask for later.

import Foundation

/// One hook write lands as several file events: one per directory it touches,
/// and one per stage of the temporary-then-rename it uses to land atomically.
/// A full pass for each event would make a single badge change cost several
/// directory reads, encodes, and round trips through the rules.
///
/// The first event of a burst still runs its pass at once, because that is
/// what puts a badge on screen. Everything that arrives inside the window
/// after it is folded into one trailing pass, which is what makes sure the
/// last write of the burst is projected too. A trailing pass, rather than
/// dropping the events, is the difference between coalescing and losing the
/// final state; a trailing pass rather than a debounce is what keeps the
/// interface from freezing on a stale badge while an agent writes faster
/// than the window.
@MainActor
final class AgentPassCoalescer {
    /// Long enough to cover the events one write fans out into, short enough
    /// that a genuine second write is not held back noticeably.
    static let defaultWindow: TimeInterval = 0.05

    private let window: TimeInterval
    private let now: () -> TimeInterval
    private let timer: HoverDelayTimer
    private let run: () -> Void
    private var lastRunAt: TimeInterval = -.infinity
    /// What cancels the pass that will close the current window, when one
    /// is owed.
    private var trailing: (@MainActor () -> Void)?
    /// What cancels the pass the rules asked for at a later moment, when a finished
    /// turn's notice is held (`AgentProjection.nextPassInMs`): nothing
    /// watched changes when the hold ends, and the sweep may be seconds
    /// away or not running.
    private var due: (@MainActor () -> Void)?

    init(
        window: TimeInterval = AgentPassCoalescer.defaultWindow,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timer: HoverDelayTimer = .live,
        run: @escaping () -> Void
    ) {
        self.window = window
        self.now = now
        self.timer = timer
        self.run = run
    }

    /// Something asked for a pass. Runs it now if the window since the last
    /// one has closed, otherwise makes sure one pass is owed when it does.
    func request() {
        let elapsed = now() - lastRunAt
        if elapsed >= window {
            fire()
            return
        }
        guard trailing == nil else { return }
        let delay = window - elapsed
        trailing = timer.schedule(.seconds(delay)) { [weak self] in
            self?.fire()
        }
    }

    /// A pass ran by another route, such as the sweep or a closed pane. The
    /// window restarts from it, and a trailing pass it was owed is no longer
    /// owed: that pass read the directories after every event that asked for
    /// it.
    func didRun() {
        lastRunAt = now()
        trailing?()
        trailing = nil
    }

    /// The rules asked for a pass in `delay`, or for none (`nil`). Each
    /// answer says all that is held, so it replaces what an earlier one
    /// asked for. Unlike the trailing pass, a pass by another route does not
    /// settle it: that pass came before the moment it is for.
    func request(in delay: Duration?) {
        due?()
        due = nil
        guard let delay else { return }
        due = timer.schedule(delay) { [weak self] in
            self?.due = nil
            self?.fire()
        }
    }

    private func fire() {
        trailing?()
        trailing = nil
        lastRunAt = now()
        run()
    }
}
