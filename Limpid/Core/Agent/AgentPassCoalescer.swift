// AgentPassCoalescer.swift
// Limpid — folds a burst of file events into as few projection passes as it can.

import Foundation

/// One hook write lands as several file events: one per directory it touches,
/// and one per stage of the temporary-then-rename it uses to land atomically.
/// Each event used to run a full pass, so a single badge change cost several
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
    private let run: () -> Void
    private var lastRunAt: TimeInterval = -.infinity
    /// The pass that will close the current window, when one is owed.
    private var trailing: Task<Void, Never>?

    init(
        window: TimeInterval = AgentPassCoalescer.defaultWindow,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        run: @escaping () -> Void
    ) {
        self.window = window
        self.now = now
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
        trailing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            trailing = nil
            fire()
        }
    }

    /// A pass ran by another route, such as the sweep or a closed pane. The
    /// window restarts from it, and a trailing pass it was owed is no longer
    /// owed: that pass read the directories after every event that asked for
    /// it.
    func didRun() {
        lastRunAt = now()
        trailing?.cancel()
        trailing = nil
    }

    private func fire() {
        trailing?.cancel()
        trailing = nil
        lastRunAt = now()
        run()
    }
}
