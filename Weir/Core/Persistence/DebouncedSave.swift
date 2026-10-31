// DebouncedSave.swift
// Weir — one store's pending save: replaced by each new one, run once the changes stop.

import Foundation

/// This is the save a store has scheduled and not yet run. It coalesces a
/// burst of changes into one write `PersistenceTiming.coalescingMs` after the last.
/// Each store owns one, so canceling it at quit or before a write of its
/// own touches only that store's save.
///
/// We share only the timer here. What a save writes, when its snapshot is
/// taken, the serial queue it writes on, and the synchronous flush stay in
/// each store, because those differ: most stores take the snapshot when
/// they schedule, while the session store also reads its migration state
/// when the save runs.
@MainActor
final class DebouncedSave {
    /// This cancels the save the timer runs after the delay. It is optional
    /// because no save may have been scheduled yet, or the last one was canceled.
    private var pending: (@MainActor () -> Void)?
    private let delay: Duration
    private let timer: HoverDelayTimer

    init(delay: Duration = .milliseconds(PersistenceTiming.coalescingMs), timer: HoverDelayTimer = .live) {
        self.delay = delay
        self.timer = timer
    }

    /// Whether a save was scheduled and not canceled since. It stays true
    /// after that save has run, as the stores' own work items did, so a
    /// store's synchronous flush still writes its latest state once more
    /// through its queue rather than trust a write that may be in flight.
    var hasPending: Bool {
        pending != nil
    }

    /// Replaces any pending save with `run`, called on the main actor once
    /// `delay` passes without another call. `run` usually enqueues a write
    /// of a snapshot it captured on the store's serial queue.
    func schedule(_ run: @escaping @MainActor @Sendable () -> Void) {
        pending?()
        pending = timer.schedule(delay, run)
    }

    /// Drops the pending save, if any, before it runs. It is for a store
    /// writing now on its own, or one that has stopped saving.
    func cancel() {
        pending?()
        pending = nil
    }
}
